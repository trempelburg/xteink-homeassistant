-- Home Assistant pieces shared by the app (src/main.lua) and the lock screen (lockscreen.lua,
-- which carries its own copy: lock entries load alone): settings and the tile list, the REST
-- requests, the states cache and how a state is shown.
--
-- ha.txt (settings; can be written over USB): url, token, title, lock (true|false), each "key=value".
-- tiles.txt: one entity a line, "entity_id" or "entity_id = Label"; a leading "*" puts it on the
--   lock screen; "#" starts a comment. Edited in the app or over USB.
-- states.txt (the cache, written by whoever fetched last): "updated=<epoch>", then
--   "entity|state|unit|name|class|extra" lines.
--
-- All tiles come in one request: POST /api/template renders a few lines of text for exactly the
-- entities on the panel (each HTTPS request costs ~1.4 s on the device and the heap is ~1 MB, so
-- /api/states, every entity of the house as JSON, is out). The template API needs an admin's
-- token; for any other token the app falls back to GET /api/states/<entity> one by one.

local H = {}

function H.kv(s)
  local t = {}
  for k, v in (s or ''):gmatch('([%w_]+)=([^\n]*)') do t[k] = (v:gsub('%s+$', '')) end
  return t
end

------------------------------------------------------------------ settings and tiles

-- "192.168.1.5:8123/" -> "http://192.168.1.5:8123"
function H.base(url)
  url = tostring(url or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('/+$', '')
  if url ~= '' and not url:match('^https?://') then url = 'http://' .. url end
  return url
end

function H.parse_cfg(s)
  local t = H.kv(s)
  return { url = H.base(t.url), token = t.token or '', title = (t.title and t.title ~= '') and t.title or 'Home',
           lock = t.lock == 'true' }
end
function H.cfg_text(c)
  return 'url=' .. (c.url or '') .. '\ntoken=' .. (c.token or '') .. '\ntitle=' .. (c.title or 'Home') ..
    '\nlock=' .. tostring(c.lock == true)
end

function H.valid_id(id) return type(id) == 'string' and id:match('^[%l%d_]+%.[%l%d_]+$') ~= nil end
function H.domain(id) return (tostring(id):match('^([^.]+)%.')) or '' end

function H.parse_tiles(s)
  local out = {}
  for raw in ((s or '') .. '\n'):gmatch('([^\n]*)\n') do
    local line = raw:gsub('\r', ''):gsub('#.*$', ''):gsub('^%s+', ''):gsub('%s+$', '')
    local pin = line:sub(1, 1) == '*'
    if pin then line = line:sub(2):gsub('^%s+', '') end
    local id, label = line:match('^([^=]-)%s*=%s*(.-)$')
    id = (id or line):lower()
    if H.valid_id(id) then out[#out + 1] = { id = id, label = (label and label ~= '') and label or nil, pin = pin } end
  end
  return out
end
function H.tiles_text(list)
  local out = { '# one entity a line: "entity_id" or "entity_id = Label"; "*" in front puts it on the lock screen' }
  for _k, t in ipairs(list) do out[#out + 1] = (t.pin and '*' or '') .. t.id .. (t.label and (' = ' .. t.label) or '') end
  return table.concat(out, '\n') .. '\n'
end

-- the tiles of the lock screen: the pinned ones, or the first eight when none is pinned
function H.lock_tiles(list)
  local out = {}
  for _k, t in ipairs(list) do if t.pin then out[#out + 1] = t end end
  if #out == 0 then for k = 1, math.min(8, #list) do out[k] = list[k] end end
  while #out > 8 do table.remove(out) end
  return out
end

------------------------------------------------------------------ requests

-- a JSON string (the device's ctx.json:encode is not probed; this is all a request body needs)
function H.json_str(s)
  return '"' .. tostring(s):gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == '\\' then return '\\\\' elseif c == '\n' then return '\\n'
    elseif c == '\t' then return '\\t' end
    return string.format('\\u%04x', c:byte())
  end) .. '"'
end

local function headers(token)
  return { ['Authorization'] = 'Bearer ' .. tostring(token or ''), ['Content-Type'] = 'application/json',
           ['Accept'] = 'application/json, text/plain' }
end

-- one line per entity: id|state|unit|name|device class|extra (by domain: a thermostat's
-- "current;target;action", the target "21" or a range "18~24"; a light's brightness %; a cover's
-- position; the media title; a lock's supported features)
local ROW = "{{ e }}|{{ states(e)|replace('|','/')|replace('\\n',' ') }}|{{ state_attr(e,'unit_of_measurement') or '' }}|" ..
  "{{ (state_attr(e,'friendly_name') or e)|replace('|','/')|replace('\\n',' ') }}|{{ state_attr(e,'device_class') or '' }}|" ..
  "{% set d = e.split('.')[0] %}{% if d == 'climate' %}{{ state_attr(e,'current_temperature') if state_attr(e,'current_temperature') is not none else '' }};" ..
  "{% if state_attr(e,'temperature') is not none %}{{ state_attr(e,'temperature') }}" ..
  "{% elif state_attr(e,'target_temp_low') is not none %}{{ state_attr(e,'target_temp_low') }}~{{ state_attr(e,'target_temp_high') }}{% endif %};" ..
  "{{ state_attr(e,'hvac_action') or '' }}" ..
  "{% elif d == 'light' and state_attr(e,'brightness') %}{{ (state_attr(e,'brightness') / 2.55)|round|int }}" ..
  "{% elif d == 'cover' and state_attr(e,'current_position') is not none %}{{ state_attr(e,'current_position') }}" ..
  "{% elif d == 'lock' %}{{ state_attr(e,'supported_features') or 0 }}" ..
  "{% elif d == 'media_player' %}{{ (state_attr(e,'media_title') or '')|replace('|','/')|replace('\\n',' ') }}{% endif %}\n"

function H.template(ids)
  local q = {}
  for _k, id in ipairs(ids) do if H.valid_id(id) then q[#q + 1] = "'" .. id .. "'" end end
  return '{% for e in [' .. table.concat(q, ',') .. '] %}' .. ROW .. '{% endfor %}'
end

function H.states_request(cfg, ids)
  return { url = cfg.url .. '/api/template', method = 'POST', headers = headers(cfg.token),
           body = '{"template":' .. H.json_str(H.template(ids)) .. '}', timeout_ms = 30000 }
end

function H.state_request(cfg, id)
  return { url = cfg.url .. '/api/states/' .. id, method = 'GET', headers = headers(cfg.token), timeout_ms = 20000 }
end

function H.ping_request(cfg)
  return { url = cfg.url .. '/api/', method = 'GET', headers = headers(cfg.token), timeout_ms = 20000 }
end

-- entities whose id or name holds q, at most 40
function H.search_request(cfg, q)
  q = tostring(q or ''):lower():gsub("[\\'{}%%]", ''):gsub('^%s+', ''):gsub('%s+$', '')
  local t = "{% set q = '" .. q .. "' %}{% set ns = namespace(n=0) %}{% for s in states|sort(attribute='entity_id') %}" ..
    "{% if ns.n < 40 and (q in s.entity_id or q in (s.name|lower)) %}{% set ns.n = ns.n + 1 %}" ..
    "{{ s.entity_id }}|{{ s.state|replace('|','/')|replace('\\n',' ') }}|{{ s.attributes.unit_of_measurement or '' }}|" ..
    "{{ s.name|replace('|','/')|replace('\\n',' ') }}|{{ s.attributes.device_class or '' }}|\n{% endif %}{% endfor %}"
  return { url = cfg.url .. '/api/template', method = 'POST', headers = headers(cfg.token),
           body = '{"template":' .. H.json_str(t) .. '}', timeout_ms = 30000 }
end

-- a small JSON encoder for service data: strings, numbers, booleans, arrays and string-keyed tables
-- (keys sorted, so the body is the same every time)
function H.json(v)
  local t = type(v)
  if t == 'string' then return H.json_str(v) end
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then
    if v == math.floor(v) and math.abs(v) < 2 ^ 31 then return string.format('%d', math.floor(v)) end
    return (string.format('%.3f', v):gsub('0+$', ''):gsub('%.$', ''))
  end
  if t == 'table' then
    if #v > 0 then
      local o = {}
      for i, x in ipairs(v) do o[i] = H.json(x) end
      return '[' .. table.concat(o, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local o = {}
    for _k, k in ipairs(keys) do o[#o + 1] = H.json_str(k) .. ':' .. H.json(v[k]) end
    return '{' .. table.concat(o, ',') .. '}'
  end
  return 'null'
end

-- data: further service fields, as { brightness_pct = 40 }
function H.service_request(cfg, id, domain, service, data)
  local body = { entity_id = id }
  for k, v in pairs(data or {}) do body[k] = v end
  return { url = cfg.url .. '/api/services/' .. domain .. '/' .. service, method = 'POST', headers = headers(cfg.token),
           body = H.json(body), timeout_ms = 20000 }
end

------------------------------------------------------------------ what an entity can do

-- the value of a JSON attribute only when it is a number / a string (JSON null decodes to a sentinel)
function H.num(v) return type(v) == 'number' and v or nil end
function H.str(v) return type(v) == 'string' and v or nil end
function H.has(features, bit) return ((math.floor(H.num(features) or 0) // bit) % 2) == 1 end

-- a light's supported_color_modes -> { brightness, temp, color }
function H.light_modes(a)
  local m = { brightness = false, temp = false, color = false }
  local modes = type(a.supported_color_modes) == 'table' and a.supported_color_modes or {}
  for _k, s in ipairs(modes) do
    if s ~= 'onoff' then m.brightness = true end
    if s == 'color_temp' then m.temp = true end
    if s == 'hs' or s == 'xy' or s == 'rgb' or s == 'rgbw' or s == 'rgbww' then m.color = true; m.temp = true end
  end
  if H.num(a.brightness) then m.brightness = true end
  if m.color and not (H.num(a.min_color_temp_kelvin) or H.num(a.min_mireds)) then m.temp = false end
  return m
end

H.WARMTH = { { 'Warm', 2700 }, { 'Soft', 3500 }, { 'Neutral', 4500 }, { 'Daylight', 6000 } }
H.COLOURS = { { 'White', 0, 0 }, { 'Red', 0, 100 }, { 'Orange', 30, 100 }, { 'Yellow', 55, 100 },
              { 'Green', 120, 100 }, { 'Cyan', 180, 100 }, { 'Blue', 230, 100 }, { 'Purple', 280, 100 } }

-- a warmth preset clamped to the light's range
function H.kelvin(a, k)
  local lo, hi = H.num(a.min_color_temp_kelvin) or 2000, H.num(a.max_color_temp_kelvin) or 6500
  return math.floor(math.max(lo, math.min(hi, k)))
end

-- media player features (HA's MediaPlayerEntityFeature)
H.MP = { PAUSE = 1, VOLUME_SET = 4, VOLUME_MUTE = 8, PREVIOUS = 16, NEXT = 32, TURN_ON = 128, TURN_OFF = 256,
         VOLUME_STEP = 1024, SELECT_SOURCE = 2048, STOP = 4096, PLAY = 16384 }
-- cover features (CoverEntityFeature)
H.CV = { OPEN = 1, CLOSE = 2, SET_POSITION = 4, STOP = 8 }
-- lock features (LockEntityFeature): OPEN is unlatching (lock.open), as a Nuki does
H.LK = { OPEN = 1 }

-- whether a lock row can unlatch the door (a cache from before 0.5 does not say: no)
function H.can_open(row)
  return row ~= nil and H.domain(row.id) == 'lock' and row.state ~= 'unavailable' and H.has(tonumber(row.extra), H.LK.OPEN)
end

-- the template's lines -> { [id] = row } and the ids in order
function H.parse_rows(body)
  local rows, order = {}, {}
  for line in (tostring(body or '') .. '\n'):gmatch('([^\n]*)\n') do
    local id, state, unit, name, class, extra = line:match('^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$')
    if id and H.valid_id(id) then
      rows[id] = { id = id, state = state, unit = unit, name = name, class = class, extra = extra }
      order[#order + 1] = id
    end
  end
  return rows, order
end

-- GET /api/states/<id> (decoded JSON) -> a row like the template's
function H.row_from_state(d)
  if type(d) ~= 'table' or not H.valid_id(d.entity_id) then return nil end
  local a = type(d.attributes) == 'table' and d.attributes or {}
  local dom, extra = H.domain(d.entity_id), ''
  if dom == 'climate' then
    local t = H.num(a.temperature) and tostring(a.temperature)
      or (H.num(a.target_temp_low) and (tostring(a.target_temp_low) .. '~' .. tostring(a.target_temp_high))) or ''
    extra = (H.num(a.current_temperature) and tostring(a.current_temperature) or '') .. ';' .. t .. ';' .. (H.str(a.hvac_action) or '')
  elseif dom == 'light' and tonumber(a.brightness) then extra = tostring(math.floor(tonumber(a.brightness) / 2.55 + 0.5))
  elseif dom == 'cover' and tonumber(a.current_position) then extra = tostring(a.current_position)
  elseif dom == 'media_player' and a.media_title then extra = tostring(a.media_title)
  elseif dom == 'lock' then extra = tostring(math.floor(H.num(a.supported_features) or 0)) end
  local function clean(v) return (tostring(v or ''):gsub('[|\n]', ' ')) end
  return { id = d.entity_id, state = clean(d.state), unit = clean(a.unit_of_measurement), name = clean(a.friendly_name or d.entity_id),
           class = clean(a.device_class), extra = clean(extra) }
end

function H.http_error(code)
  if code == 401 or code == 403 then return 'token rejected (' .. code .. ')' end
  if code == 404 then return 'not found (404): is the address right?' end
  return 'HTTP ' .. tostring(code)
end

------------------------------------------------------------------ the cache

function H.cache_text(rows, order, now)
  local out = { 'updated=' .. tostring(now or 0) }
  for _k, id in ipairs(order) do
    local r = rows[id]
    if r then out[#out + 1] = table.concat({ r.id, r.state, r.unit, r.name, r.class, r.extra }, '|') end
  end
  return table.concat(out, '\n')
end
function H.parse_cache(text)
  if not text then return nil end
  local rows, order = H.parse_rows(text)
  return { updated = tonumber(text:match('updated=(%d+)')), rows = rows, order = order }
end

------------------------------------------------------------------ showing a state

local TOGGLE = { light = true, switch = true, input_boolean = true, fan = true, automation = true, siren = true,
                 humidifier = true }

local function cap(s) s = tostring(s or ''):gsub('_', ' '); return (s:gsub('^%l', string.upper)) end

function H.number(s, unit)
  local v = tonumber(s)
  if not v then return nil end
  local t
  if math.abs(v) >= 100 or v == math.floor(v) then t = tostring(math.floor(v + 0.5))
  else t = string.format('%.1f', v):gsub('%.0$', '') end
  if unit and unit ~= '' then t = t .. (unit:sub(1, #'°') == '°' and unit or (' ' .. unit)) end
  return t
end

local BINARY = {
  door = { 'Open', 'Closed' }, window = { 'Open', 'Closed' }, opening = { 'Open', 'Closed' }, garage_door = { 'Open', 'Closed' },
  motion = { 'Motion', 'Clear' }, occupancy = { 'Occupied', 'Clear' }, presence = { 'Home', 'Away' },
  moisture = { 'Wet', 'Dry' }, smoke = { 'Smoke!', 'Clear' }, gas = { 'Gas!', 'Clear' }, problem = { 'Problem', 'OK' },
  safety = { 'Unsafe', 'Safe' }, lock = { 'Unlocked', 'Locked' }, battery = { 'Low', 'OK' }, plug = { 'Plugged in', 'Unplugged' },
  connectivity = { 'Connected', 'Offline' }, running = { 'Running', 'Idle' },
}
local ALERT = { door = true, window = true, opening = true, garage_door = true, moisture = true, smoke = true, gas = true,
                problem = true, safety = true, lock = true }

-- a row -> the value (large), a second line (small, may be ''), and whether the tile is "on"
-- (framed twice: switched on, open, unlocked, home)
function H.shown(row)
  if not row then return '...', '', false end
  local st, dom = row.state or '', H.domain(row.id)
  if st == 'unavailable' or st == 'unknown' or st == '' then return '-', st, false end
  if TOGGLE[dom] then
    local v = st == 'on' and 'On' or st == 'off' and 'Off' or cap(st)
    if dom == 'light' and st == 'on' and row.extra ~= '' then v = v .. ' ' .. row.extra .. '%' end
    return v, '', st == 'on'
  end
  if dom == 'binary_sensor' then
    local b = BINARY[row.class] or { 'On', 'Off' }
    return st == 'on' and b[1] or b[2], '', st == 'on'
  end
  if dom == 'lock' then return cap(st), '', st ~= 'locked' end
  if dom == 'cover' or dom == 'valve' then
    local v = cap(st)
    if st == 'open' and row.extra ~= '' and row.extra ~= '100' then v = v .. ' ' .. row.extra .. '%' end
    return v, '', st ~= 'closed'
  end
  if dom == 'climate' then
    local cur, target, action = H.climate_extra(row.extra)
    local v = H.number(cur, '°') or cap(st)
    if st == 'off' then return v, 'Off', false end
    local busy = action ~= '' and action ~= 'idle' and action ~= 'off'
    if busy then return v, cap(action) .. (target and (' to ' .. target) or ''), true end
    return v, cap(st) .. (target and (' · ' .. target) or ''), action == ''
  end
  if dom == 'media_player' then return cap(st), row.extra or '', st == 'playing' end
  if dom == 'scene' or dom == 'script' then return st == 'on' and 'Running' or 'Run', '', st == 'on' end
  if dom == 'button' or dom == 'input_button' then return 'Press', '', false end
  if dom == 'person' or dom == 'device_tracker' then return cap(st == 'not_home' and 'away' or st), '', st == 'home' end
  if dom == 'sun' then return st == 'above_horizon' and 'Up' or 'Down', '', st == 'above_horizon' end
  local n = H.number(st, row.unit)
  if n then return n, '', false end
  return cap(st), '', false
end

-- a thermostat row's extra "current;target;action" -> current, the target as text ("21°", "18-24°"), action;
-- a cache from version 0.1 or 0.2 holds the current temperature alone
function H.climate_extra(extra)
  local cur, t, action = tostring(extra or ''):match('^([^;]*);([^;]*);(.*)$')
  if not cur then return extra, nil, '' end
  local lo, hi = t:match('^([^~]+)~(.+)$')
  local target
  if lo then target = (H.number(lo, '') or lo) .. '-' .. (H.number(hi, '°') or hi)
  elseif t ~= '' then target = H.number(t, '°') or t end
  return cur, target, action
end

-- what a tap does: domain, service, and a question to ask first (or nil); nil when nothing
function H.action(row)
  if not row then return nil end
  local st, dom = row.state or '', H.domain(row.id)
  if st == 'unavailable' then return nil end
  if TOGGLE[dom] then return dom, 'toggle' end
  if dom == 'scene' or dom == 'script' then return dom, 'turn_on' end
  if dom == 'button' or dom == 'input_button' then return dom, 'press' end
  if dom == 'media_player' then return dom, 'media_play_pause' end
  if dom == 'cover' then return dom, (st == 'closed' or st == 'closing') and 'open_cover' or 'close_cover', true end
  if dom == 'lock' then return dom, st == 'locked' and 'unlock' or 'lock', true end
  return nil
end

-- after a toggle the tile turns at once; the next fetch has the last word
function H.flipped(row)
  local dom = H.domain(row.id)
  if TOGGLE[dom] and (row.state == 'on' or row.state == 'off') then
    local r = {}
    for k, v in pairs(row) do r[k] = v end
    r.state = row.state == 'on' and 'off' or 'on'
    return r
  end
  return nil
end

-- worth a line on the lock screen: open doors and windows, water, smoke, an unlocked lock
function H.alert(row)
  if not row then return false end
  local dom = H.domain(row.id)
  if dom == 'binary_sensor' then return row.state == 'on' and ALERT[row.class] == true end
  if dom == 'lock' then return row.state == 'unlocked' or row.state == 'jammed' or row.state == 'open' end
  if dom == 'cover' then return row.class == 'garage' and row.state == 'open' end
  return false
end

-- how old the states are: "updated just now", "updated 12 min ago", "updated 3 h ago"
function H.ago(age)
  local mins = math.max(0, age or 0) // 60
  if mins < 1 then return 'updated just now' end
  return mins < 90 and ('updated ' .. mins .. ' min ago') or ('updated ' .. (mins // 60) .. ' h ago')
end

function H.label(tile, row)
  return tile.label or (row and row.name ~= '' and row.name) or tile.id
end

return H
