-- Lock-screen entry for Home Assistant (API 2.9; bundle.py puts src/ha.lua in front as `H` and
-- src/draw.lua as `D`). Shows the time and date, the pinned tiles (or the first eight) from
-- states.txt, and a box listing every open door or window, water, smoke or unlocked lock among the
-- tiles. Redrawn every minute for the clock; when the states are over ten minutes old it asks Home
-- Assistant again. A locked reader usually has Wi-Fi off, so when no answer came it says so under
-- the tiles and waits longer each time (10, 20, 40, 80, then every 160 minutes): every try wakes
-- Wi-Fi for several seconds. lockstate.txt keeps the last try, as the entry may be loaded afresh
-- for each draw.

local W, HH = 480, 800
local STALE_S = 10 * 60
local ANSWER_S = 50              -- a try with no new states after this long failed

local function read(name)
  local ok, s = pcall(function() return ctx.storage:read(name) end)
  return (ok and type(s) == 'string') and s or nil
end
local function now()
  local ok, t = pcall(function() return ctx.clock:now() end)
  return (ok and type(t) == 'table') and t or {}
end
local function now_sec() local t = now(); return tonumber(t.epoch_sec) and math.floor(tonumber(t.epoch_sec)) or 0 end

-- lockstate.txt: asked=<epoch of the last try>, fails=<tries before it that got nothing>, err=<HTTP status of an error answer>
local function read_state()
  local t = H.kv(read('lockstate.txt'))
  return { asked = tonumber(t.asked), fails = tonumber(t.fails) or 0, err = t.err or '' }
end
local function write_state(st)
  pcall(function()
    ctx.storage:write('lockstate.txt', 'asked=' .. (st.asked or 0) .. '\nfails=' .. st.fails .. '\nerr=' .. (st.err or ''))
  end)
end

local function try_refresh(cfg, tiles, cache, st)
  if cfg.url == '' or cfg.token == '' or #tiles == 0 then return end
  local failed = st.asked and (cache.updated or 0) < st.asked
  if st.asked and now_sec() - st.asked < STALE_S * 2 ^ math.min(st.fails, 4) then return end
  st.fails = failed and st.fails + 1 or 0
  st.asked, st.err = now_sec(), ''
  write_state(st)
  local ids = {}
  for k, t in ipairs(tiles) do ids[k] = t.id end
  pcall(function()
    local req = H.states_request(cfg, ids)
    req.timeout_ms = 15000
    ctx.net:request(req, function(c, resp)
      pcall(function() ctx.net:keep_wifi(1) end)       -- let Wi-Fi go again at once
      pcall(function()
        if type(resp) ~= 'table' then return end
        local code = tonumber(resp.status) or tonumber(resp.code)
        if code and code >= 400 then st.err = tostring(code); write_state(st); return end
        if type(resp.body) ~= 'string' then return end
        local rows, order = H.parse_rows(resp.body)
        if #order == 0 then return end
        ctx.storage:write('states.txt', H.cache_text(rows, ids, now_sec()))
      end)
      pcall(function() ctx.invalidate() end)
    end)
  end)
end

local function ago(age)
  local mins = age // 60
  return mins < 90 and ('updated ' .. mins .. ' min ago') or ('updated ' .. (mins // 60) .. ' h ago')
end

function on_draw(c, gg)
  if not gg then return end
  local ok, err = pcall(function()
    gg:clear(0)
    local cfg = H.parse_cfg(read('ha.txt'))
    local tiles = H.parse_tiles(read('tiles.txt'))
    local cache = H.parse_cache(read('states.txt'))
    if #tiles == 0 or not cache then
      D.icon(gg, 'bulb', W / 2 - 40, 300, 80, false)
      D.text_c(gg, W / 2, 410, 'Home Assistant: open the app to add tiles.', 'medium')
      return
    end
    local st = read_state()
    local age = now_sec() - (cache.updated or 0)
    if age > STALE_S then try_refresh(cfg, tiles, cache, st) end

    local t = now()
    D.text(gg, 24, 20, D.fit(cfg.title, 'large', W - 160), 'large')
    D.text(gg, 24, 58, D.date(t), 'small')
    D.text_r(gg, W - 24, 20, D.clock(t), 'large')
    gg:line(24, 92, W - 24, 92)

    -- two tiles a row; a row is as tall as its taller tile: a third line (the state's detail or a
    -- light's brightness) needs 118, the name and the value alone 96. A tile whose entity is in the
    -- box below (an unlocked lock, an open door) is left out: the box says it already.
    local tw = 210
    local shown = {}
    for _k, tl in ipairs(H.lock_tiles(tiles)) do
      local row = cache.rows[tl.id]
      if not H.alert(row) then
        local v, sub, on = H.shown(row)
        local bar = H.domain(tl.id) == 'light' and on and tonumber(row.extra)
        shown[#shown + 1] = { tile = tl, row = row, v = v, sub = sub, on = on, bar = bar, h = (bar or sub ~= '') and 118 or 96 }
      end
    end
    local y = 108
    for k = 1, #shown, 2 do
      local th = math.max(shown[k].h, shown[k + 1] and shown[k + 1].h or 0)
      for j = k, math.min(k + 1, #shown) do
        local s = shown[j]
        local x = 24 + (j - k) * (tw + 12)
        D.rrect(gg, x, y, tw, th, 18, s.on and 3 or 1)
        D.icon(gg, D.kind(s.row), x + 14, y + 14, 30, s.on)
        D.text(gg, x + 54, y + 20, D.fit(H.label(s.tile, s.row), 'small', tw - 66), 'small')
        D.text(gg, x + 14, y + 52, D.fit(s.v, 'large', tw - 28), 'large')
        if s.bar then
          D.bar(gg, x + 14, y + th - 18, tw - 28, 8, s.bar / 100)
        elseif s.sub ~= '' then
          D.text(gg, x + 14, y + th - 28, D.fit(s.sub, 'small', tw - 28), 'small')
        end
      end
      y = y + th + 12
    end

    local open = {}
    for _k, tl in ipairs(tiles) do
      local row = cache.rows[tl.id]
      if H.alert(row) then open[#open + 1] = H.label(tl, row) .. ' (' .. (H.shown(row)) .. ')' end
    end
    y = y + 18
    if #open > 0 then
      local lines, line = {}, ''
      for _k, s in ipairs(open) do
        local cand = line == '' and s or (line .. ', ' .. s)
        if line ~= '' and D.width('medium', cand) > W - 150 then lines[#lines + 1] = line; line = s else line = cand end
      end
      lines[#lines + 1] = line
      local n = math.min(3, #lines)
      D.rrect(gg, 24, y - 14, W - 48, n * 30 + 26, 18, 2)
      D.icon(gg, 'alert', 40, y - 2 + (n - 1) * 15, 30)
      for k = 1, n do D.text(gg, 86, y + (k - 1) * 30, D.fit(lines[k], 'medium', W - 130), 'medium') end
    else
      D.icon(gg, 'door', 24, y, 26, false)
      D.text(gg, 62, y + 2, 'All doors and windows closed.', 'small')
    end

    -- how old the states are, and why when the last try got nothing
    local missed = age > STALE_S and st.asked and (cache.updated or 0) < st.asked and now_sec() - st.asked >= ANSWER_S
    if missed and st.err ~= '' then
      D.icon(gg, 'alert', 24, HH - 44, 24)
      D.text(gg, 58, HH - 40, D.fit(ago(age) .. ' · HA error ' .. st.err, 'small', W - 82), 'small')
    elseif missed then
      D.icon(gg, 'wifi_off', 24, HH - 44, 24)
      D.text(gg, 58, HH - 40, ago(age), 'small')
    else
      D.text(gg, 24, HH - 40, ago(age), 'small')
    end
  end)
  if not ok then pcall(function() gg:text(10, 760, 'lock error: ' .. tostring(err):sub(1, 40)) end) end
end

function on_load() end
function on_tick() end
function on_input() return false end
