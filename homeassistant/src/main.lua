-- Home Assistant for XTOS Licorice, API 2.9 (uses tools/gamekit, src/ha.lua and src/draw.lua).
-- Needs Wi-Fi.
--
-- A panel of tiles, one per entity, read through Home Assistant's REST API with a long-lived
-- access token. Each tile has an icon for its kind; tiles that are on, open or unlocked get a
-- heavy frame. Lights and switches have a switch at the top right; a speaker a play / pause
-- button there. A tap elsewhere on a light, a speaker, a thermostat or a cover opens its sheet:
-- brightness, warmth and colour; tracks, volume, mute and source; target temperature and mode;
-- open, stop, close and position. Scenes and scripts run on a tap, locks ask first, sensors show
-- their details. A long press moves, renames, pins or removes a tile; Add searches the entities.
-- The states are kept in states.txt, so the panel opens at once and the lock screen
-- (lockscreen.lua, built by bundle.py from src/lock/lock.lua, ha.lua and draw.lua) can show them.

local H = require('ha')
local D = require('draw')
local W, H_ = kit.W, kit.H
local BTN_Y, BTN_H = 706, 62
local TOP, TW, TH, GAP, VGAP, PER = 100, 222, 100, 12, 10, 10
local QW, QH = 84, 56                  -- the quick-action corner of a tile (its switch or play button)
local PICK_Y, PICK_H, PICK_ROWS = 100, 80, 7
local STALE_S = 60
local IDLE_S = 10 * 60             -- untouched this long: no more asking on its own, Wi-Fi may go
local WIFI_MS = 2 * 60 * 1000       -- Wi-Fi kept up this long after a request (asks come every minute)
local SHEET = { light = true, media_player = true, climate = true, cover = true }

local cfg = H.parse_cfg(nil)
local tiles = {}
local cache = { rows = {}, order = {} }
local screen = 'main'           -- main | setup | pick | sheet
local page = 1
local picks, pick_top = {}, 1
local sheet = nil               -- { id, d = the entity's state (GET /api/states/<id>), or nil while loading }
local hits = {}                 -- the sheet's tap areas, made while drawing it
local per_entity = false        -- the token may not use /api/template: one request per entity
local status, busy_label, ERR = nil, nil, nil
local touched = 0                -- when the app was last used (epoch seconds)

local function now() local ok, t = pcall(function() return ctx.clock:now() end); return (ok and type(t) == 'table') and t or {} end
local function now_sec() local t = now(); return tonumber(t.epoch_sec) and math.floor(tonumber(t.epoch_sec)) or 0 end
local function hhmm(epoch)
  local t = now()
  if not epoch or not tonumber(t.hour) then return '' end
  local wall = (tonumber(t.hour) * 3600 + (tonumber(t.minute) or 0) * 60 - (now_sec() - epoch)) % 86400
  return string.format('%02d:%02d', wall // 3600, (wall % 3600) // 60)
end
local function configured() return cfg.url ~= '' and cfg.token ~= '' end
local function pages() return math.max(1, (#tiles + PER - 1) // PER) end
local function cap(s) s = tostring(s or ''):gsub('_', ' '); return (s:gsub('^%l', string.upper)) end

------------------------------------------------------------------ storage

local function save_cfg() kit.write('ha.txt', H.cfg_text(cfg)) end
local function save_tiles() kit.write('tiles.txt', H.tiles_text(tiles)) end
local function load_all()
  cfg = H.parse_cfg(kit.read('ha.txt'))
  tiles = H.parse_tiles(kit.read('tiles.txt'))
  cache = H.parse_cache(kit.read('states.txt')) or { rows = {}, order = {} }
end
local function store_rows(rows)
  for id, r in pairs(rows) do cache.rows[id] = r end
  cache.updated = now_sec()
  local ids = {}
  for k, t in ipairs(tiles) do ids[k] = t.id end
  kit.write('states.txt', H.cache_text(cache.rows, ids, cache.updated))
end

------------------------------------------------------------------ network

-- one request at a time; one more waits (the latest wins: a third volume tap replaces the second)
local pending, queued = nil, nil
-- on_done(body, code, err): body is nil on failure
local function send(opts, label, on_done)
  if pending then queued = { opts, label, on_done }; return true end
  pcall(function() ctx.net:keep_wifi(WIFI_MS) end)
  local job = {}
  pending, busy_label = job, label
  local ok, err = pcall(function()
    local r, e = ctx.net:request(opts, function(c, resp)
      if pending ~= job then return end
      pending, busy_label = nil, nil
      local okh, e2 = pcall(function()
        if type(resp) ~= 'table' then on_done(nil, nil, 'no answer'); return end
        local code = tonumber(resp.status) or tonumber(resp.code)
        local body = type(resp.body) == 'string' and resp.body or ''
        if code and code >= 400 then on_done(nil, code, H.http_error(code)); return end
        if not code and body == '' then on_done(nil, nil, resp.error and tostring(resp.error) or 'no answer'); return end
        on_done(body, code)
      end)
      if not okh then status = 'Error: ' .. kit.short(tostring(e2), 40) end
      if queued and not pending then
        local q = queued
        queued = nil
        send(q[1], q[2], q[3])
      end
      kit.refresh()
    end)
    if r == nil and e then error(e, 0) end
  end)
  if not ok then
    pending, busy_label = nil, nil
    status = 'Could not ask: ' .. kit.short(tostring(err), 30)
    return false
  end
  return true
end

local function tile_ids()
  local t = {}
  for k, tl in ipairs(tiles) do t[k] = tl.id end
  return t
end

local function fetch_each(label)
  local list, rows, k = tile_ids(), {}, 0
  local function step()
    k = k + 1
    if k > #list then store_rows(rows); status = nil; return end
    local id = list[k]
    send(H.state_request(cfg, id), (label or 'Updating') .. ' ' .. k .. '/' .. #list .. '...', function(body, code, err)
      if code == 404 then
        rows[id] = { id = id, state = 'unavailable', unit = '', name = id, class = '', extra = '' }
      elseif not body then
        per_entity = false
        status = 'Update failed: ' .. err
        return
      else
        local okj, d = pcall(function() return ctx.json:decode(body) end)
        local r = okj and H.row_from_state(d) or nil
        if r then rows[r.id] = r end
      end
      step()
    end)
  end
  step()
end

local function refresh(label)
  if not configured() then screen = 'setup'; return end
  if #tiles == 0 then status = 'No tiles yet: tap Add.'; return end
  if per_entity then fetch_each(label); return end
  send(H.states_request(cfg, tile_ids()), label or 'Updating...', function(body, code, err)
    if not body then
      -- 401 here is also what a token that is not an admin's gets: try one entity at a time
      if code == 401 or code == 403 then per_entity = true; fetch_each(label); return end
      status = 'Update failed: ' .. err
      return
    end
    local rows, order = H.parse_rows(body)
    if #order == 0 then status = 'Unexpected answer: ' .. kit.short(body:gsub('%s+', ' '), 30); return end
    store_rows(rows)
    status = nil
  end)
end

-- the sheet's entity, whole (attributes and all)
local function load_sheet(label)
  if not sheet then return end
  local id = sheet.id
  send(H.state_request(cfg, id), label or 'Loading...', function(body, code, err)
    if not sheet or sheet.id ~= id then return end
    if not body then status = 'Could not load: ' .. err; return end
    local okj, d = pcall(function() return ctx.json:decode(body) end)
    if okj and type(d) == 'table' and d.entity_id == id then
      sheet.d, sheet.at = d, now_sec()
      local r = H.row_from_state(d)
      if r then store_rows({ [id] = r }) end
    end
  end)
end

-- a service call answers with the states it changed: those tiles (and the sheet) take them at once
local function apply_changed(body)
  local okj, list = pcall(function() return ctx.json:decode(body) end)
  local rows, n = {}, 0
  if okj and type(list) == 'table' then
    for _k, d in ipairs(list) do
      local r = H.row_from_state(d)
      if r and (cache.rows[r.id] or (sheet and sheet.id == r.id)) then rows[r.id] = r; n = n + 1 end
      if r and sheet and sheet.id == r.id then sheet.d, sheet.at = d, now_sec() end
    end
  end
  if n > 0 then store_rows(rows) end
  return n
end

-- id's service; the state changes on the screen at once (guess), the answer has the last word
local function call(id, svc, data, label, guess)
  local dom = H.domain(id)
  local old_row = cache.rows[id]
  if guess then guess() end
  send(H.service_request(cfg, id, dom, svc, data), label or (cap(svc) .. '...'), function(body, code, err)
    if not body then
      if old_row then cache.rows[id] = old_row end
      status = 'Failed: ' .. err
      if sheet and sheet.id == id then load_sheet() end
      return
    end
    if apply_changed(body) == 0 then
      if sheet and sheet.id == id then load_sheet('') else refresh('') end
    end
  end)
end

local function test_connection()
  if not configured() then status = 'Enter the address and the token first.'; return end
  send(H.ping_request(cfg), 'Connecting...', function(body, code, err)
    if not body then status = 'Connection failed: ' .. err; return end
    if body:find('API running', 1, true) then
      status, screen = 'Connected.', 'main'
      if #tiles > 0 then refresh() end
    else status = 'Unexpected answer: ' .. kit.short(body:gsub('%s+', ' '), 30) end
  end)
end

------------------------------------------------------------------ tiles: tap, info, edit

local SVC_WORD = { open_cover = 'Open', close_cover = 'Close', unlock = 'Unlock', lock = 'Lock', open = 'Open' }

local edit_tile

-- the tile's own action (a toggle, a scene, a lock after asking)
local function run(i)
  local t = tiles[i]
  local row = cache.rows[t.id]
  local dom, svc, ask = H.action(row)
  local function go()
    kit.close()
    local f = H.flipped(row)
    call(t.id, svc, nil, kit.short(H.label(t, row), 24) .. '...', f and function() cache.rows[t.id] = f end)
  end
  -- a lock that can unlatch (a Nuki): Open door, then asked once more, as it opens the door itself
  local function open_door()
    kit.show({ title = 'Open the door?', lines = { H.label(t, row) .. ' unlatches: the door', 'can be pushed open.' }, cancel = kit.close,
               rows = { { { 'Open', function() kit.close(); call(t.id, 'open', nil, 'Opening ' .. kit.short(H.label(t, row), 20) .. '...') end },
                          { 'Cancel', kit.close } } } })
  end
  if ask then
    local word = SVC_WORD[svc] or svc
    local rows = { { { word, go }, { 'Cancel', kit.close } } }
    local title = word .. ' ' .. H.label(t, row) .. '?'
    if H.can_open(row) then table.insert(rows, 1, { { 'Open door', open_door } }); title = H.label(t, row) end
    kit.show({ title = title, rows = rows, cancel = kit.close })
  else go() end
end

local function open_sheet(i)
  sheet = { id = tiles[i].id, label = tiles[i].label, d = nil }
  screen = 'sheet'
  load_sheet()
end

local function info(i)
  local t = tiles[i]
  local row = cache.rows[t.id]
  local v, sub = H.shown(row)
  local lines = { v .. (sub ~= '' and ('  ' .. sub) or ''), t.id }
  if cache.updated then lines[#lines + 1] = 'updated ' .. hhmm(cache.updated) end
  kit.show({ title = H.label(t, row), lines = lines,
             rows = { { { 'Edit tile', function() edit_tile(i) end }, { 'Close', kit.close } } }, cancel = kit.close })
end

local function move(i, d)
  local j = i + d
  if j < 1 or j > #tiles then return end
  tiles[i], tiles[j] = tiles[j], tiles[i]
  save_tiles()
  page = (j - 1) // PER + 1
end

function edit_tile(i)
  local t = tiles[i]
  local row = cache.rows[t.id]
  kit.show({ title = H.label(t, row), lines = { t.id .. (t.pin and '  (on the lock screen)' or '') }, cancel = kit.close, rows = {
    { { 'Move back', function() move(i, -1); kit.close() end, i > 1 },
      { 'Move on', function() move(i, 1); kit.close() end, i < #tiles } },
    { { t.pin and 'Unpin' or 'Pin to lock', function() t.pin = not t.pin; save_tiles(); kit.close() end },
      { 'Rename', function()
          kit.close()
          ctx.input:text({ title = 'Tile name (empty: the entity\'s own)', value = t.label or '' }, function(c, s)
            s = s and s:gsub('[\n#=]', ' '):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '') or ''
            t.label = s ~= '' and s or nil
            save_tiles()
            kit.refresh()
          end)
        end } },
    { { 'Remove', function()
          kit.show({ title = 'Remove ' .. H.label(t, row) .. '?', cancel = kit.close, rows = { {
            { 'Remove', function() table.remove(tiles, i); save_tiles(); page = math.min(page, pages()); kit.close() end },
            { 'Cancel', kit.close } } } })
        end },
      { 'Close', kit.close } } } })
end

------------------------------------------------------------------ add: search the entities

local function on_panel(id)
  for k, t in ipairs(tiles) do if t.id == id then return k end end
  return nil
end

local function search(q)
  send(H.search_request(cfg, q), 'Looking for ' .. kit.short(q, 20) .. '...', function(body, code, err)
    if not body then
      status = (code == 401 or code == 403) and 'Search needs an admin\'s token; add tiles in tiles.txt over USB.'
        or ('Search failed: ' .. err)
      return
    end
    local rows, order = H.parse_rows(body)
    picks, pick_top = {}, 1
    for k, id in ipairs(order) do picks[k] = rows[id] end
    screen = 'pick'
    status = #picks == 0 and 'Nothing by that name.' or nil
  end)
end

local function ask_search()
  ctx.input:text({ title = 'Find entities (part of a name or id)', value = '' }, function(c, s)
    if s and s:match('%S') then search(s) end
    kit.refresh()
  end)
end

local function pick(k)
  local r = picks[k]
  if not r then return end
  local at = on_panel(r.id)
  if at then table.remove(tiles, at)
  else
    tiles[#tiles + 1] = { id = r.id }
    cache.rows[r.id] = r
  end
  save_tiles()
end

------------------------------------------------------------------ setup

local SETUP = { { 'url', 'Address', 'Home Assistant address, e.g. http://192.168.1.20:8123' },
                { 'token', 'Token', 'Long-lived access token (your profile, Security tab)' },
                { 'title', 'Title', 'Title of the panel' } }

local function edit_setting(k)
  local s = SETUP[k]
  ctx.input:text({ title = s[3], value = cfg[s[1]] or '', max_chars = 400 }, function(c, v)
    if v then
      v = v:gsub('^%s+', ''):gsub('%s+$', '')
      if s[1] == 'url' then v = H.base(v) end
      if s[1] == 'title' and v == '' then v = 'Home' end
      cfg[s[1]] = v
      save_cfg()
    end
    kit.refresh()
  end)
end

------------------------------------------------------------------ lock screen

local function toggle_lock()
  local L = ctx.lockscreen
  cfg.lock = not cfg.lock
  save_cfg()
  if not L then status = 'This firmware has no app lock screen.'; return end
  local okd, isdef = pcall(function() return L:is_default() end)
  if cfg.lock then
    if not (okd and isdef == true) then pcall(function() L:set_default() end) end
    status = 'Lock screen: the pinned tiles.'
  else
    if okd and isdef == true then pcall(function() L:clear_default() end) end
    status = 'Lock screen: off.'
  end
end

------------------------------------------------------------------ the panel

local function tile_rect(k)
  local j = k - (page - 1) * PER - 1
  return 12 + (j % 2) * (TW + GAP), TOP + (j // 2) * (TH + VGAP)
end

-- what the top-right corner of a tile does: 'switch', 'play' or nil
local function quick(row)
  if not row or row.state == 'unavailable' then return nil end
  local dom = H.domain(row.id)
  if dom == 'media_player' then return (row.state == 'playing' or row.state == 'paused' or row.state == 'idle' or row.state == 'on') and 'play' or nil end
  local _d, svc = H.action(row)
  if svc == 'toggle' and SHEET[dom] then return 'switch' end
  return nil
end

local function draw_tile(gg, k)
  local t = tiles[k]
  local row = cache.rows[t.id]
  local v, sub, on = H.shown(row)
  local dom = row and H.domain(row.id) or ''
  local x, y = tile_rect(k)
  local q = quick(row)
  local _d, svc = H.action(row)
  local sw = (svc == 'toggle')
  D.rrect(gg, x, y, TW, TH, 16, on and 3 or 1)
  D.icon(gg, D.kind(row), x + 14, y + 14, 28, on)
  D.text(gg, x + 52, y + 18, D.fit(H.label(t, row), 'small', TW - 52 - ((q or sw) and 72 or 14)), 'small')
  local has_sheet = SHEET[dom] and row and row.state ~= 'unavailable'
  D.text(gg, x + 14, y + 42, D.fit(v, 'large', TW - 28 - (has_sheet and 18 or 0)), 'large')
  if has_sheet then D.glyph(gg, 'chevron', x + TW - 18, y + 58, 22) end
  if dom == 'light' and on and tonumber(row.extra) then
    D.bar(gg, x + 14, y + TH - 16, TW - 28, 8, tonumber(row.extra) / 100)
  elseif sub ~= '' then
    D.text(gg, x + 14, y + TH - 25, D.fit(sub, 'small', TW - 28), 'small')
  end
  if q == 'play' then D.round(gg, x + TW - 32, y + 30, 19, row.state == 'playing' and 'pause' or 'play')
  elseif sw then D.switch(gg, x + TW - 62, y + 14, 48, 28, on) end
end

local function draw_header(gg, title)
  D.text(gg, 20, 14, D.fit(title, 'large', W - 150), 'large')
  local t = now()
  D.text(gg, 20, 54, D.date(t) .. (tonumber(t.hour) and ('  ·  ' .. D.clock(t)) or ''), 'small')
  gg:line(20, 88, W - 20, 88)
end

local function draw_main(gg)
  draw_header(gg, cfg.title)
  local np = pages()
  if np > 1 then
    for k = 1, np do
      local cx = W - 24 - (np - k) * 22
      if k == page then D.disc(gg, cx, 34, 6) else D.circle(gg, cx, 34, 6) end
    end
  end
  if #tiles == 0 then
    D.icon(gg, 'bulb', W / 2 - 40, 170, 80, true)
    local y = 290
    for _k, l in ipairs(kit.wrap('No tiles yet. Tap Add and search for a light, a sensor or a scene, or copy a ' ..
        'tiles.txt (one entity id a line) into XTApps/homeassistant/files/ over USB.', 'medium', W - 60)) do
      D.text_c(gg, W / 2, y, l, 'medium'); y = y + 32
    end
    return
  end
  for k = (page - 1) * PER + 1, math.min(#tiles, page * PER) do draw_tile(gg, k) end
end

local function draw_pick(gg)
  D.text(gg, 20, 14, 'Add tiles', 'large')
  D.text(gg, 20, 54, 'tap to add or take away; swipe for more', 'small')
  gg:line(20, 88, W - 20, 88)
  for k = pick_top, math.min(#picks, pick_top + PICK_ROWS - 1) do
    local r = picks[k]
    local y = PICK_Y + (k - pick_top) * PICK_H
    local v = H.shown(r)
    local added = on_panel(r.id) ~= nil
    D.rrect(gg, 16, y + 4, W - 32, PICK_H - 10, 14, added and 3 or 1)
    D.icon(gg, D.kind(r), 30, y + 20, 30, added)
    D.text(gg, 76, y + 12, (added and '[x] ' or '[ ] ') .. D.fit(r.name, 'medium', W - 260), 'medium')
    D.text_r(gg, W - 32, y + 14, D.fit(v, 'small', 120), 'small')
    D.text(gg, 76, y + 42, D.fit(r.id, 'small', W - 120), 'small')
  end
end

local function draw_setup(gg)
  D.text(gg, 20, 14, 'Setup', 'large')
  D.text(gg, 20, 54, 'Home Assistant connection', 'small')
  gg:line(20, 88, W - 20, 88)
  for k, s in ipairs(SETUP) do
    local y = 100 + (k - 1) * 84
    local v = cfg[s[1]] or ''
    if s[1] == 'token' and #v > 12 then v = v:sub(1, 4) .. '...' .. v:sub(-4) end
    D.rrect(gg, 16, y, W - 32, 74, 14, 1)
    D.text(gg, 32, y + 8, s[2], 'small')
    D.text(gg, 32, y + 34, v ~= '' and D.fit(v, 'medium', W - 80) or '(tap to enter)', 'medium')
    D.glyph(gg, 'chevron', W - 40, y + 37, 22)
  end
  local y = 370
  for _k, l in ipairs(kit.wrap('Or copy a ha.txt with the lines url=... and token=... into XTApps/homeassistant/files/ ' ..
      'on the SD card over USB. Use the IP address: names ending in .local may not be found from the reader. ' ..
      'Tiles need an admin\'s token for one quick request; others work one entity at a time.', 'small', W - 40)) do
    D.text(gg, 20, y, l, 'small'); y = y + 26
  end
end

------------------------------------------------------------------ sheets

local function hit(x, y, w, h, id, fn, enabled)
  if enabled == false then return end
  hits[#hits + 1] = { x = x, y = y, w = w, h = h, id = id, fn = fn }
end

local function attrs() return (sheet.d and type(sheet.d.attributes) == 'table') and sheet.d.attributes or {} end
local function sheet_state() return sheet.d and H.str(sheet.d.state) or ((cache.rows[sheet.id] or {}).state or '') end
local function name() return sheet.label or H.str(attrs().friendly_name) or (cache.rows[sheet.id] or {}).name or sheet.id end

-- change the sheet's state before the answer comes
local function guess(fn) return function() if sheet.d then fn(sheet.d, attrs()) end end end

local function section(gg, y, label, value)
  D.text(gg, 20, y, label, 'medium')
  if value then D.text_r(gg, W - 20, y, value, 'medium') end
end

local function draw_light(gg)
  local a, st = attrs(), sheet_state()
  local on = st == 'on'
  local m = H.light_modes(a)
  local pct = on and H.num(a.brightness) and math.floor(H.num(a.brightness) / 2.55 + 0.5) or 0
  local id = sheet.id
  D.icon(gg, 'bulb', 20, 106, 52, on)
  D.text(gg, 90, 108, D.fit(name(), 'large', W - 230), 'large')
  D.text(gg, 90, 144, on and m.brightness and ('On, ' .. pct .. '% brightness') or (on and 'On' or cap(st)), 'small')
  D.switch(gg, W - 112, 112, 92, 48, on)
  hit(W - 130, 96, 130, 80, 'power', function()
    call(id, 'toggle', nil, on and 'Turning off...' or 'Turning on...', guess(function(d) d.state = on and 'off' or 'on' end))
  end)
  local y = 196
  if m.brightness then
    section(gg, y, 'Brightness', on and (pct .. '%') or 'off')
    local xs, sw = D.segments(gg, 20, y + 36, W - 40, 58, 10, (pct + 5) // 10)
    for k = 1, 10 do
      hit(xs[k], y + 36, sw, 58, 'b' .. (k * 10), function()
        call(id, 'turn_on', { brightness_pct = k * 10 }, 'Brightness ' .. (k * 10) .. '%...',
             guess(function(d, aa) d.state = 'on'; aa.brightness = k * 25.5 end))
      end)
    end
    local bw = (W - 40 - 3 * 8) // 4
    local steps = { { 'minus', math.max(1, pct - 10) }, { 'Night', 5 }, { 'Max', 100 }, { 'plus', math.min(100, pct + 10) } }
    for k, s in ipairs(steps) do
      local bx = 20 + (k - 1) * (bw + 8)
      local glyph = s[1] == 'minus' or s[1] == 'plus'
      D.button(gg, bx, y + 106, bw, 54, glyph and '' or s[1])
      if glyph then D.glyph(gg, s[1], bx + bw / 2, y + 133, 26) end
      hit(bx, y + 106, bw, 54, s[1], function()
        call(id, 'turn_on', { brightness_pct = s[2] }, 'Brightness ' .. s[2] .. '%...',
             guess(function(d, aa) d.state = 'on'; aa.brightness = s[2] * 2.55 end))
      end)
    end
    y = y + 186
  end
  if m.temp then
    local cur = H.num(a.color_temp_kelvin)
    local in_temp = H.str(a.color_mode) == 'color_temp' and cur
    section(gg, y, 'Warmth', in_temp and (math.floor(cur) .. ' K') or nil)
    local best, bd = nil, nil
    if in_temp then
      for k, p in ipairs(H.WARMTH) do
        local dd = math.abs(H.kelvin(a, p[2]) - cur)
        if not bd or dd < bd then best, bd = k, dd end
      end
    end
    local bw = (W - 40 - 3 * 8) // 4
    for k, p in ipairs(H.WARMTH) do
      local bx = 20 + (k - 1) * (bw + 8)
      D.button(gg, bx, y + 36, bw, 54, p[1], { sel = k == best, font = 'small' })
      hit(bx, y + 36, bw, 54, p[1], function()
        local kv = H.kelvin(a, p[2])
        call(id, 'turn_on', { color_temp_kelvin = kv }, p[1] .. '...',
             guess(function(d, aa) d.state = 'on'; aa.color_mode = 'color_temp'; aa.color_temp_kelvin = kv end))
      end)
    end
    y = y + 112
  end
  if m.color then
    section(gg, y, 'Colour')
    local bw = (W - 40 - 3 * 8) // 4
    for k, c in ipairs(H.COLOURS) do
      local bx, by = 20 + ((k - 1) % 4) * (bw + 8), y + 36 + ((k - 1) // 4) * 60
      D.button(gg, bx, by, bw, 52, c[1], { font = 'small' })
      hit(bx, by, bw, 52, c[1], function()
        call(id, 'turn_on', { hs_color = { c[2], c[3] } }, c[1] .. '...', guess(function(d, aa) d.state = 'on'; aa.color_mode = 'hs' end))
      end)
    end
  end
  if not m.brightness and not m.temp and not m.color and sheet.d then
    D.text(gg, 20, y, 'This light only switches on and off.', 'medium')
  end
end

local function draw_media(gg)
  local a, st = attrs(), sheet_state()
  local f = H.num(a.supported_features) or 0
  local id = sheet.id
  local off = st == 'off' or st == 'standby' or st == 'unavailable'
  D.icon(gg, 'speaker', 20, 106, 48, st == 'playing')
  D.text(gg, 84, 106, D.fit(name(), 'large', W - 250), 'large')
  local src = H.str(a.app_name) or H.str(a.source)
  D.text(gg, 84, 142, D.fit(cap(st) .. (src and ('  ·  ' .. src) or ''), 'small', W - 250), 'small')
  if H.has(f, H.MP.TURN_OFF) or H.has(f, H.MP.TURN_ON) then
    D.button(gg, W - 148, 104, 128, 52, off and 'Turn on' or 'Turn off', { font = 'small' })
    hit(W - 148, 104, 128, 52, 'onoff', function()
      call(id, off and 'turn_on' or 'turn_off', nil, off and 'Turning on...' or 'Turning off...',
           guess(function(d) d.state = off and 'on' or 'off' end))
    end)
  end
  -- what is playing
  local title = H.str(a.media_title)
  local y = 186
  if title then
    for k, l in ipairs(kit.wrap(title, 'large', W - 40)) do
      if k > 2 then break end
      D.text(gg, 20, y, k == 2 and D.fit(l, 'large', W - 40) or l, 'large'); y = y + 34
    end
    local who = H.str(a.media_artist) or H.str(a.media_album_artist)
    if who then D.text(gg, 20, y + 2, D.fit(who, 'medium', W - 40), 'medium') end
    local album = H.str(a.media_album_name)
    if album then D.text(gg, 20, y + 32, D.fit(album, 'small', W - 40), 'small') end
  else
    D.text(gg, 20, y, off and 'Switched off' or 'Nothing playing', 'large')
  end
  -- prev / play-pause / next
  local cy = 386
  local can_prev, can_next = H.has(f, H.MP.PREVIOUS), H.has(f, H.MP.NEXT)
  local can_pp = H.has(f, H.MP.PAUSE) or H.has(f, H.MP.PLAY) or f == 0
  D.round(gg, 110, cy, 40, 'prev', { off = not can_prev })
  D.round(gg, 240, cy, 54, st == 'playing' and 'pause' or 'play', { off = not can_pp, sel = true })
  D.round(gg, 370, cy, 40, 'next', { off = not can_next })
  hit(60, cy - 50, 100, 100, 'prev', function() call(id, 'media_previous_track', nil, 'Previous track...') end, can_prev)
  hit(180, cy - 60, 120, 120, 'playpause', function()
    call(id, 'media_play_pause', nil, st == 'playing' and 'Pausing...' or 'Playing...',
         guess(function(d) d.state = st == 'playing' and 'paused' or 'playing' end))
  end, can_pp)
  hit(320, cy - 50, 100, 100, 'next', function() call(id, 'media_next_track', nil, 'Next track...') end, can_next)
  -- volume
  local vol = H.num(a.volume_level)
  local muted = a.is_volume_muted == true
  local can_set = H.has(f, H.MP.VOLUME_SET)
  y = 462
  section(gg, y, 'Volume', vol and (muted and 'muted' or (math.floor(vol * 100 + 0.5) .. '%')) or nil)
  if H.has(f, H.MP.VOLUME_MUTE) then
    D.button(gg, W - 260, y - 8, 110, 42, muted and 'Unmute' or 'Mute', { font = 'small', sel = muted })
    hit(W - 260, y - 10, 110, 46, 'mute', function()
      call(id, 'volume_mute', { is_volume_muted = not muted }, muted and 'Unmuting...' or 'Muting...',
           guess(function(_d, aa) aa.is_volume_muted = not muted end))
    end)
  end
  if can_set then
    local xs, sw = D.segments(gg, 20, y + 40, W - 40, 56, 10, vol and math.floor(vol * 10 + 0.5) or 0)
    for k = 1, 10 do
      hit(xs[k], y + 40, sw, 56, 'v' .. (k * 10), function()
        call(id, 'volume_set', { volume_level = k / 10 }, 'Volume ' .. (k * 10) .. '%...',
             guess(function(_d, aa) aa.volume_level = k / 10; aa.is_volume_muted = false end))
      end)
    end
  end
  local can_step = can_set or H.has(f, H.MP.VOLUME_STEP)
  local by = y + 108
  local function step(dir)
    if can_set and vol then
      local v = math.max(0, math.min(1, math.floor(vol * 20 + 0.5 + dir) / 20))
      call(id, 'volume_set', { volume_level = v }, 'Volume ' .. math.floor(v * 100 + 0.5) .. '%...',
           guess(function(_d, aa) aa.volume_level = v end))
    else
      call(id, dir > 0 and 'volume_up' or 'volume_down', nil, dir > 0 and 'Louder...' or 'Quieter...')
    end
  end
  D.button(gg, 20, by, 96, 56, '', { off = not can_step }); D.glyph(gg, 'minus', 68, by + 28, 26)
  D.button(gg, W - 116, by, 96, 56, '', { off = not can_step }); D.glyph(gg, 'plus', W - 68, by + 28, 26)
  hit(20, by, 96, 56, 'vol-', function() step(-1) end, can_step)
  hit(W - 116, by, 96, 56, 'vol+', function() step(1) end, can_step)
  -- source
  local sources = type(a.source_list) == 'table' and a.source_list or nil
  if sources and #sources > 0 and H.has(f, H.MP.SELECT_SOURCE) then
    D.button(gg, 128, by, W - 256, 56, 'Source: ' .. (H.str(a.source) or '-'), { font = 'small' })
    hit(128, by, W - 256, 56, 'source', function()
      local rows = {}
      for k, s in ipairs(sources) do
        if k > 7 then break end
        local src = tostring(s)
        rows[#rows + 1] = { { src, function()
          kit.close()
          call(id, 'select_source', { source = src }, src .. '...', guess(function(_d, aa) aa.source = src end))
        end } }
      end
      rows[#rows + 1] = { { 'Cancel', kit.close } }
      kit.show({ title = 'Play from', rows = rows, cancel = kit.close })
    end)
  end
end

-- a grid of choice buttons, four a row, the current one heavy; returns the y below it
local function choices(gg, y, list, cur, prefix, pick)
  local bw = (W - 40 - 3 * 8) // 4
  local n = math.min(8, #list)
  for k = 1, n do
    local v = tostring(list[k])
    local bx, by = 20 + ((k - 1) % 4) * (bw + 8), y + ((k - 1) // 4) * 58
    D.button(gg, bx, by, bw, 50, cap(v), { sel = v == cur, font = 'small' })
    hit(bx, by, bw, 50, prefix .. v, function() pick(v) end)
  end
  return y + ((n + 3) // 4) * 58
end

local function draw_climate(gg)
  local a, st = attrs(), sheet_state()
  local id = sheet.id
  local cur, target = H.num(a.current_temperature), H.num(a.temperature)
  local lo, hi = H.num(a.target_temp_low), H.num(a.target_temp_high)
  local stepv = H.num(a.target_temp_step) or 0.5
  local tmin, tmax = H.num(a.min_temp) or 5, H.num(a.max_temp) or 35
  local function clamp(v) return math.max(tmin, math.min(tmax, v)) end
  local fans = type(a.fan_modes) == 'table' and a.fan_modes or {}
  local action = H.str(a.hvac_action)
  D.icon(gg, 'thermo', 20, 106, 52, st ~= 'off')
  D.text(gg, 90, 108, D.fit(name(), 'large', W - 110), 'large')
  local facts = {}
  if cur then facts[#facts + 1] = H.number(cur, '°') .. ' now' end
  facts[#facts + 1] = cap(action or st)
  if H.num(a.current_humidity) then facts[#facts + 1] = H.number(a.current_humidity, '') .. '% humidity' end
  D.text(gg, 90, 144, D.fit(table.concat(facts, ' · '), 'small', W - 110), 'small')
  local y = 190
  if target then
    -- one target temperature
    local cy = y + 76
    section(gg, y, 'Target')
    D.round(gg, 90, cy, 40, 'minus')
    D.text_c(gg, W / 2, cy - 18, H.number(target, '°'), 'large')
    D.round(gg, W - 90, cy, 40, 'plus')
    local function set(v)
      v = clamp(v)
      call(id, 'set_temperature', { temperature = v }, 'Target ' .. H.number(v, '°') .. '...', guess(function(_d, aa) aa.temperature = v end))
    end
    hit(36, cy - 46, 110, 92, 'temp-', function() set(target - stepv) end)
    hit(W - 146, cy - 46, 110, 92, 'temp+', function() set(target + stepv) end)
    y = cy + 60
  elseif lo and hi then
    -- a range (heat_cool / auto): heat below the low one, cool above the high one; both go together
    section(gg, y, 'Target range')
    local function set(l, h)
      l, h = clamp(l), clamp(h)
      if h - l < stepv then return end
      call(id, 'set_temperature', { target_temp_low = l, target_temp_high = h },
           'Range ' .. H.number(l, '') .. '-' .. H.number(h, '°') .. '...',
           guess(function(_d, aa) aa.target_temp_low = l; aa.target_temp_high = h end))
    end
    local rows = { { 'Heat to', lo, 'low', function(d) set(lo + d, hi) end },
                   { 'Cool to', hi, 'high', function(d) set(lo, hi + d) end } }
    for k, r in ipairs(rows) do
      local cy = y + 66 + (k - 1) * 76
      D.text(gg, 20, cy - 12, r[1], 'medium')
      D.round(gg, W - 210, cy, 30, 'minus')
      D.text_c(gg, W - 130, cy - 15, H.number(r[2], '°'), 'large')
      D.round(gg, W - 50, cy, 30, 'plus')
      hit(W - 250, cy - 36, 80, 72, r[3] .. '-', function() r[4](-stepv) end)
      hit(W - 90, cy - 36, 80, 72, r[3] .. '+', function() r[4](stepv) end)
    end
    y = y + 66 + 76 + 40
  end
  local modes = type(a.hvac_modes) == 'table' and a.hvac_modes or {}
  if #modes > 0 then
    section(gg, y, 'Mode')
    y = choices(gg, y + 34, modes, st, '', function(mode)
      call(id, 'set_hvac_mode', { hvac_mode = mode }, cap(mode) .. '...', guess(function(d) d.state = mode end))
    end) + 14
  end
  local presets = type(a.preset_modes) == 'table' and a.preset_modes or {}
  if #presets > 0 then
    section(gg, y, 'Preset')
    y = choices(gg, y + 34, presets, H.str(a.preset_mode), 'preset:', function(p)
      call(id, 'set_preset_mode', { preset_mode = p }, cap(p) .. '...', guess(function(_d, aa) aa.preset_mode = p end))
    end) + 14
  end
  if #fans > 0 then
    section(gg, y, 'Fan')
    choices(gg, y + 34, fans, H.str(a.fan_mode), 'fan:', function(fm)
      call(id, 'set_fan_mode', { fan_mode = fm }, 'Fan ' .. fm .. '...', guess(function(_d, aa) aa.fan_mode = fm end))
    end)
  end
end

local function draw_cover(gg)
  local a, st = attrs(), sheet_state()
  local id = sheet.id
  local f = H.num(a.supported_features)
  local function can(bit) return f == nil or H.has(f, bit) end
  local pos = H.num(a.current_position)
  local row = cache.rows[id]
  D.icon(gg, D.kind(row or { id = id, class = H.str(a.device_class) }), 20, 106, 52, st ~= 'closed')
  D.text(gg, 90, 108, D.fit(name(), 'large', W - 110), 'large')
  D.text(gg, 90, 144, cap(st) .. (pos and ('  ·  ' .. pos .. '% open') or ''), 'small')
  local bw = (W - 40 - 2 * 8) // 3
  local acts = { { 'Open', 'open_cover', H.CV.OPEN, 'up', 'opening' }, { 'Stop', 'stop_cover', H.CV.STOP, 'stop' },
                 { 'Close', 'close_cover', H.CV.CLOSE, 'down', 'closing' } }
  for k, ac in ipairs(acts) do
    local bx = 20 + (k - 1) * (bw + 8)
    local ok = can(ac[3])
    D.button(gg, bx, 200, bw, 64, ac[1], { off = not ok })
    hit(bx, 200, bw, 64, ac[1], function()
      call(id, ac[2], nil, ac[1] .. '...', ac[5] and guess(function(d) d.state = ac[5] end))
    end, ok)
  end
  if f and H.has(f, H.CV.SET_POSITION) then
    section(gg, 296, 'Position', pos and (pos .. '%') or nil)
    local xs, sw = D.segments(gg, 20, 332, W - 40, 58, 10, pos and (pos + 5) // 10 or 0)
    for k = 1, 10 do
      hit(xs[k], 332, sw, 58, 'p' .. (k * 10), function()
        call(id, 'set_cover_position', { position = k * 10 }, 'Position ' .. (k * 10) .. '%...',
             guess(function(_d, aa) aa.current_position = k * 10 end))
      end)
    end
  end
end

local function draw_sheet(gg)
  hits = {}
  D.glyph(gg, 'back', 30, 40, 30)
  D.text(gg, 50, 26, 'Back', 'medium')
  hit(0, 0, 170, 80, 'back', function() screen, sheet = 'main', nil end)
  D.text_r(gg, W - 20, 26, D.clock(now()), 'medium')
  gg:line(20, 88, W - 20, 88)
  local dom = H.domain(sheet.id)
  if dom == 'light' then draw_light(gg)
  elseif dom == 'media_player' then draw_media(gg)
  elseif dom == 'climate' then draw_climate(gg)
  elseif dom == 'cover' then draw_cover(gg) end
  if not sheet.d then D.text(gg, 20, H_ - 120, 'Loading the details...', 'small') end
end

------------------------------------------------------------------ the frame

local function buttons()
  if screen == 'sheet' then return {} end
  if screen == 'setup' then return configured() and { 'Back', 'Test' } or { 'Test' } end
  if screen == 'pick' then return { 'Done', 'Search again' } end
  return { 'Refresh', 'Add', 'Setup', cfg.lock and 'Lock off' or 'Lock' }
end
local function button_rect(k, n)
  local bw = math.floor((W - 24 - (n - 1) * 8) / n)
  return 12 + (k - 1) * (bw + 8), BTN_Y, bw, BTN_H
end

function on_draw(c, gg)
  if not gg then return end
  local ok, e = pcall(function()
    gg:clear(0)
    if kit.modal() then kit.draw_modal(gg); return end
    if screen == 'setup' then draw_setup(gg)
    elseif screen == 'pick' then draw_pick(gg)
    elseif screen == 'sheet' then draw_sheet(gg)
    else draw_main(gg) end
    local line = busy_label or status or ERR
    if line and line ~= '' then
      D.text(gg, 20, screen == 'sheet' and (H_ - 60) or (BTN_Y - 34), kit.short(line, 48), 'small')
    elseif screen == 'main' and cache.updated then
      D.text(gg, 20, BTN_Y - 34, 'updated ' .. hhmm(cache.updated) .. (now_sec() - cache.updated > 10 * 60 and ' (old)' or ''), 'small')
    end
    local bs = buttons()
    for k, b in ipairs(bs) do
      local x, y, bw, bh = button_rect(k, #bs)
      D.button(gg, x, y, bw, bh, b)
    end
  end)
  if not ok then pcall(function() gg:text(8, H_ - 60, kit.short('draw ERR ' .. tostring(e), 46)) end) end
end

------------------------------------------------------------------ input

local function tile_at(x, y)
  for k = (page - 1) * PER + 1, math.min(#tiles, page * PER) do
    local tx, ty = tile_rect(k)
    if x >= tx and x < tx + TW and y >= ty and y < ty + TH then return k, x - tx, y - ty end
  end
  return nil
end

local function turn(d)
  if screen == 'pick' then
    local top = pick_top + d * PICK_ROWS
    if top >= 1 and top <= #picks then pick_top = top end
  elseif screen == 'main' then
    page = math.max(1, math.min(pages(), page + d))
  end
end

local function tap_tile(k, dx, dy, long)
  if long then edit_tile(k); return end
  local t = tiles[k]
  local row = cache.rows[t.id]
  local dom = H.domain(t.id)
  local q = quick(row)
  local in_corner = dx >= TW - QW and dy < QH
  if q == 'play' and in_corner then
    call(t.id, 'media_play_pause', nil, row.state == 'playing' and 'Pausing...' or 'Playing...',
         function() cache.rows[t.id] = H.flipped(row) or row end)
    return
  end
  if SHEET[dom] and row and row.state ~= 'unavailable' and not (q == 'switch' and in_corner) then open_sheet(k); return end
  if H.action(row) then run(k) else info(k) end
end

local function tap(x, y, long)
  if kit.tap_modal(x, y) then return end
  if screen == 'sheet' then
    for k = #hits, 1, -1 do
      local h = hits[k]
      if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then status = nil; h.fn(); return end
    end
    return
  end
  local bs = buttons()
  for k, b in ipairs(bs) do
    local bx, by, bw, bh = button_rect(k, #bs)
    if x >= bx and x < bx + bw and y >= by and y < by + bh then
      status = nil
      if b == 'Refresh' then refresh()
      elseif b == 'Add' or b == 'Search again' then
        if configured() then ask_search() else screen = 'setup' end
      elseif b == 'Setup' then screen = 'setup'
      elseif b == 'Lock' or b == 'Lock off' then toggle_lock()
      elseif b == 'Test' then test_connection()
      elseif b == 'Back' or b == 'Done' then screen = 'main'; page = math.min(page, pages()); refresh() end
      return
    end
  end
  if screen == 'setup' then
    local k = (y - 100) // 84 + 1
    if y >= 100 and SETUP[k] then edit_setting(k) end
  elseif screen == 'pick' then
    if y >= PICK_Y then pick(pick_top + (y - PICK_Y) // PICK_H) end
  else
    local k, dx, dy = tile_at(x, y)
    if k then tap_tile(k, dx, dy, long) end
  end
end

local long_done, suppress_up = false, false
function on_input(c, ev)
  ERR = nil
  touched = now_sec()
  local ok, e = pcall(function()
    if type(ev) ~= 'table' then return end
    if ev.type == 'pointer' then
      local x, y = ev.x or 0, ev.y or 0
      if ev.phase == 'down' then long_done = false; return false end
      if ev.phase == 'move' then return false end
      if (ev.gesture == 'long' or ev.phase == 'hold') and not kit.modal() then
        if not long_done then tap(x, y, true) end
        long_done = true
        suppress_up = ev.phase ~= 'up'
        if ev.phase == 'up' then long_done = false end
        return
      end
      if ev.phase ~= 'up' then return end
      long_done = false
      if suppress_up then suppress_up = false; return end
      if not kit.modal() then
        if ev.gesture == 'swipe_left' or ev.gesture == 'swipe_up' then turn(1); return end
        if ev.gesture == 'swipe_right' or ev.gesture == 'swipe_down' then
          if screen == 'sheet' and ev.gesture == 'swipe_right' then screen, sheet = 'main', nil; return end
          turn(-1); return
        end
      end
      tap(x, y, false)
    elseif ev.type == 'key' then
      if not kit.key_accepted(ev) then return false end
      if kit.modal() then
        if ev.key == 'back' and kit.modal().cancel then kit.modal().cancel() end
      elseif ev.key == 'down' or ev.key == 'right' then turn(1)
      elseif ev.key == 'up' or ev.key == 'left' then turn(-1)
      elseif ev.key == 'back' and screen ~= 'main' and configured() then screen, sheet = 'main', nil end
    end
  end)
  if not ok then ERR = tostring(e) end
  if e == false then return true end     -- a finger going down or moving, a key let go: nothing to redraw
  -- back from a while away: the states first
  if ok and screen == 'main' and not pending and configured() and #tiles > 0 and now_sec() - (cache.updated or 0) >= STALE_S then
    refresh('')
  end
  kit.refresh()
  return true
end

-- while the app is in use it asks again every minute (an open sheet: its entity); the answer
-- redraws, so the minute's redraw for the clock is that one. Left alone for IDLE_S (or under the
-- lock screen) it only keeps the clock and lets Wi-Fi go; the next touch asks again.
local idle = false
function on_tick(c)
  pcall(function() ctx:set_tick(60000) end)
  local ok, e = pcall(function()
    if now_sec() - touched >= IDLE_S then
      if not idle then idle = true; pcall(function() ctx.net:keep_wifi(1) end) end
      if screen == 'main' then kit.refresh() end
      return
    end
    idle = false
    if pending or kit.modal() or not configured() then return end
    if screen == 'main' and #tiles > 0 and now_sec() - (cache.updated or 0) >= STALE_S then refresh('')
    elseif screen == 'sheet' and sheet and now_sec() - (sheet.at or 0) >= STALE_S then load_sheet('') end
    if not pending and screen == 'main' then kit.refresh() end   -- no question went out: the clock
  end)
  if not ok then ERR = tostring(e) end
end

function on_load(c)
  local ok, e = pcall(function()
    load_all()
    touched = now_sec()
    if not configured() then screen = 'setup'
    elseif now_sec() - (cache.updated or 0) >= STALE_S then refresh() end
  end)
  if not ok then ERR = tostring(e) end
  pcall(function() ctx:set_tick(60000) end)
end
function on_leave() pcall(function() ctx.net:keep_wifi(1) end) end

if rawget(_G, '__TEST') then
  __TEST.api = { H = H, D = D, cfg = function() return cfg end, tiles = function() return tiles end, cache = function() return cache end,
                 screen = function() return screen end, page = function() return page end, picks = function() return picks end,
                 status = function() return status end, per_entity = function() return per_entity end,
                 sheet = function() return sheet end, hits = function() return hits end,
                 geo = { TOP = TOP, TW = TW, TH = TH, GAP = GAP, VGAP = VGAP, PICK_Y = PICK_Y, PICK_H = PICK_H } }
end
