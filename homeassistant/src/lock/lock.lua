-- Lock-screen entry for Home Assistant (API 2.9; bundle.py puts src/ha.lua in front as `H` and
-- src/draw.lua as `D`). Shows the time and date, the pinned tiles (or the first eight) from
-- states.txt, and a box listing every open door or window, water, smoke or unlocked lock among the
-- tiles. Redrawn every minute for the clock; when the states are over ten minutes old it asks Home
-- Assistant again, if the reader lets a locked app use the network (if not, it says how old they are).

local W, HH = 480, 800
local STALE_S = 10 * 60
local asked_at = nil

local function read(name)
  local ok, s = pcall(function() return ctx.storage:read(name) end)
  return (ok and type(s) == 'string') and s or nil
end
local function now()
  local ok, t = pcall(function() return ctx.clock:now() end)
  return (ok and type(t) == 'table') and t or {}
end
local function now_sec() local t = now(); return tonumber(t.epoch_sec) and math.floor(tonumber(t.epoch_sec)) or 0 end

local function try_refresh(cfg, tiles)
  if cfg.url == '' or cfg.token == '' or #tiles == 0 or (asked_at and now_sec() - asked_at < STALE_S) then return end
  asked_at = now_sec()
  local ids = {}
  for k, t in ipairs(tiles) do ids[k] = t.id end
  pcall(function()
    ctx.net:request(H.states_request(cfg, ids), function(c, resp)
      pcall(function()
        if type(resp) ~= 'table' or type(resp.body) ~= 'string' or (tonumber(resp.status) or 200) >= 400 then return end
        local rows, order = H.parse_rows(resp.body)
        if #order == 0 then return end
        ctx.storage:write('states.txt', H.cache_text(rows, ids, now_sec()))
        pcall(function() ctx.invalidate() end)
      end)
    end)
  end)
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
    local age = now_sec() - (cache.updated or 0)
    if age > STALE_S then try_refresh(cfg, tiles) end

    local t = now()
    D.text(gg, 24, 20, D.fit(cfg.title, 'large', W - 160), 'large')
    D.text(gg, 24, 58, D.date(t), 'small')
    D.text_r(gg, W - 24, 20, D.clock(t), 'large')
    gg:line(24, 92, W - 24, 92)

    local tw, th = 210, 118
    for k, tl in ipairs(H.lock_tiles(tiles)) do
      local row = cache.rows[tl.id]
      local v, sub, on = H.shown(row)
      local x, y = 24 + ((k - 1) % 2) * (tw + 12), 108 + ((k - 1) // 2) * (th + 12)
      D.rrect(gg, x, y, tw, th, 18, on and 3 or 1)
      D.icon(gg, D.kind(row), x + 14, y + 14, 30, on)
      D.text(gg, x + 54, y + 20, D.fit(H.label(tl, row), 'small', tw - 66), 'small')
      D.text(gg, x + 14, y + 52, D.fit(v, 'large', tw - 28), 'large')
      if H.domain(tl.id) == 'light' and on and tonumber(row.extra) then
        D.bar(gg, x + 14, y + th - 18, tw - 28, 8, tonumber(row.extra) / 100)
      elseif sub ~= '' then
        D.text(gg, x + 14, y + th - 28, D.fit(sub, 'small', tw - 28), 'small')
      end
    end

    local open = {}
    for _k, tl in ipairs(tiles) do
      local row = cache.rows[tl.id]
      if H.alert(row) then open[#open + 1] = H.label(tl, row) .. ' (' .. (H.shown(row)) .. ')' end
    end
    local y = 640
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
    local mins = age // 60
    D.text(gg, 24, HH - 40, mins < 90 and ('updated ' .. mins .. ' min ago') or ('updated ' .. (mins // 60) .. ' h ago'), 'small')
  end)
  if not ok then pcall(function() gg:text(10, 760, 'lock error: ' .. tostring(err):sub(1, 40)) end) end
end

function on_load() end
function on_tick() end
function on_input() return false end
