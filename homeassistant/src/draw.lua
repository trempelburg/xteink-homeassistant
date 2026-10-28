-- Drawing pieces shared by the app (src/main.lua) and the lock screen (lockscreen.lua carries its
-- own copy): rounded frames, icons for the kinds of entity, a switch, segmented bars, round and
-- rounded buttons, media glyphs.
--
-- Only g:polyline, g:line, g:circle, g:rect and g:text are used: g:round_rect exists on the
-- device but its arguments were never probed, so a rounded frame is one polyline (17 points;
-- the host takes about 60 a command). Nothing large is filled black (it ghosts on e-ink and the
-- host draws text black on it); "filled" round things are a few circles inside each other.
-- Icons are drawn on a 28-unit grid and scaled to their box.

local D = {}

local function r(v) return math.floor(v + 0.5) end

function D.font(name) return ctx.fonts and ctx.fonts[name] end
function D.width(name, s)
  local ok, w = pcall(function() return D.font(name):measure(s) end)
  return (ok and type(w) == 'number') and w or #s * 11
end
function D.line_h(name)
  local ok, h = pcall(function() return D.font(name).line_height end)
  return (ok and tonumber(h)) or (name == 'large' and 30 or name == 'small' and 20 or 24)
end
-- s cut to fit w pixels (a whole UTF-8 character at a time)
function D.fit(s, name, w)
  s = tostring(s or '')
  if D.width(name, s) <= w then return s end
  while #s > 1 and D.width(name, s .. '~') > w do s = s:gsub('[%z\1-\127\192-\255][\128-\191]*$', '') end
  return s .. '~'
end
function D.text(gg, x, y, s, name) gg:text(r(x), r(y), s, { font = D.font(name or 'medium') }) end
function D.text_c(gg, cx, y, s, name) D.text(gg, cx - D.width(name or 'medium', s) / 2, y, s, name) end
function D.text_r(gg, rx, y, s, name) D.text(gg, rx - D.width(name or 'medium', s), y, s, name) end

function D.circle(gg, x, y, rad) pcall(function() gg:circle(r(x), r(y), r(rad)) end) end
-- a solid-looking small disc
function D.disc(gg, x, y, rad)
  local k = rad
  while k >= 1 do D.circle(gg, x, y, k); k = k - 1 end
end

-- a rounded frame; thick draws it again inside itself
function D.rrect(gg, x, y, w, h, rad, thick)
  for k = 0, (thick or 1) - 1 do
    local xx, yy, ww, hh = x + k, y + k, w - 2 * k, h - 2 * k
    local rr = math.max(2, math.min(rad - k, ww // 2, hh // 2))
    local pts = {}
    local C = { { xx + ww - rr, yy + rr, -90 }, { xx + ww - rr, yy + hh - rr, 0 }, { xx + rr, yy + hh - rr, 90 }, { xx + rr, yy + rr, 180 } }
    for _c, c in ipairs(C) do
      for s = 0, 3 do
        local a = math.rad(c[3] + s * 30)
        pts[#pts + 1] = r(c[1] + rr * math.cos(a)); pts[#pts + 1] = r(c[2] + rr * math.sin(a))
      end
    end
    pts[#pts + 1] = pts[1]; pts[#pts + 1] = pts[2]
    gg:polyline(pts)
  end
end

------------------------------------------------------------------ icons

-- which icon a row gets
function D.kind(row)
  if not row then return 'dot' end
  local dom = (tostring(row.id):match('^([^.]+)%.')) or ''
  local c = row.class or ''
  if dom == 'light' then return 'bulb' end
  if dom == 'switch' or dom == 'input_boolean' or dom == 'automation' or dom == 'siren' then return 'power' end
  if dom == 'fan' then return 'fan' end
  if dom == 'climate' or dom == 'water_heater' then return 'thermo' end
  if dom == 'media_player' then return 'speaker' end
  if dom == 'scene' then return 'star' end
  if dom == 'script' then return 'play' end
  if dom == 'button' or dom == 'input_button' then return 'button' end
  if dom == 'person' or dom == 'device_tracker' then return 'person' end
  if dom == 'sun' or dom == 'weather' then return 'sun' end
  if dom == 'lock' then return row.state == 'locked' and 'lock' or 'unlock' end
  if dom == 'cover' then return (c == 'garage' or c == 'gate') and 'garage' or 'blind' end
  if dom == 'binary_sensor' then
    if c == 'door' or c == 'garage_door' or c == 'opening' then return row.state == 'on' and 'door_open' or 'door' end
    if c == 'window' then return 'window' end
    if c == 'motion' or c == 'occupancy' or c == 'presence' then return 'motion' end
    if c == 'moisture' then return 'drop' end
    if c == 'smoke' or c == 'gas' or c == 'problem' or c == 'safety' then return 'alert' end
    if c == 'lock' then return row.state == 'on' and 'unlock' or 'lock' end
    return 'dot'
  end
  if dom == 'sensor' or dom == 'number' or dom == 'input_number' then
    if c == 'temperature' then return 'thermo' end
    if c == 'humidity' or c == 'moisture' then return 'drop' end
    if c == 'power' or c == 'energy' or c == 'current' or c == 'voltage' then return 'bolt' end
    if c == 'battery' then return 'battery' end
    if c == 'illuminance' then return 'sun' end
    return 'gauge'
  end
  return 'dot'
end

-- points on a circle of the 28-grid: centre (cx, cy), radius rad, from a0 to a1 degrees by step
local function arc(cx, cy, rad, a0, a1, step)
  local t, a = {}, a0
  while (step > 0 and a <= a1) or (step < 0 and a >= a1) do
    t[#t + 1] = cx + rad * math.cos(math.rad(a)); t[#t + 1] = cy + rad * math.sin(math.rad(a))
    a = a + step
  end
  return t
end

local SHAPES = {
  bulb = function(P, C, on)
    C(14, 11, 8); P({ 10, 18, 11, 22, 17, 22, 18, 18 }); P({ 11, 25, 17, 25 })
    if on then P({ 1, 11, 3, 11 }); P({ 25, 11, 27, 11 }); P({ 4, 1, 6, 3 }); P({ 24, 1, 22, 3 }) end
  end,
  power = function(P) P(arc(14, 15, 10, -60, 240, 30)); P({ 14, 1, 14, 13 }) end,
  fan = function(P, C)
    C(14, 14, 3)
    P({ 14, 11, 9, 3, 16, 1, 16, 11 }); P({ 17, 15, 26, 16, 24, 22, 16, 17 }); P({ 12, 16, 7, 25, 2, 20, 11, 14 })
  end,
  thermo = function(P, C, _on, Dk)
    P({ 11, 19, 11, 4, 12, 2, 16, 2, 17, 4, 17, 19 }); C(14, 22, 5); Dk(14, 22, 3); P({ 14, 8, 14, 20 })
  end,
  drop = function(P) P({ 14, 2, 7, 14, 7, 18, 10, 23, 14, 25, 18, 23, 21, 18, 21, 14, 14, 2 }) end,
  bolt = function(P) P({ 17, 1, 6, 16, 13, 16, 11, 27, 22, 11, 15, 11, 17, 1 }) end,
  battery = function(P, _C, _on, _Dk, F) P({ 2, 8, 23, 8, 23, 20, 2, 20, 2, 8 }); P({ 24, 11, 26, 11, 26, 17, 24, 17 }); F(5, 11, 10, 7) end,
  gauge = function(P) P(arc(14, 19, 12, 180, 360, 30)); P({ 2, 19, 26, 19 }); P({ 14, 19, 20, 10 }) end,
  door = function(P, C) P({ 6, 26, 6, 2, 22, 2, 22, 26 }); P({ 2, 26, 26, 26 }); C(18, 15, 1) end,
  door_open = function(P) P({ 6, 26, 6, 2, 22, 2, 22, 26 }); P({ 2, 26, 26, 26 }); P({ 6, 2, 15, 6, 15, 24, 6, 26 }) end,
  window = function(P) P({ 4, 3, 24, 3, 24, 25, 4, 25, 4, 3 }); P({ 14, 3, 14, 25 }); P({ 4, 14, 24, 14 }) end,
  motion = function(P, C)
    C(17, 4, 3); P({ 16, 8, 13, 16, 17, 19, 17, 27 }); P({ 14, 11, 8, 14 }); P({ 15, 10, 21, 13 }); P({ 13, 16, 8, 26 })
  end,
  lock = function(P, C) P({ 5, 13, 23, 13, 23, 26, 5, 26, 5, 13 }); P({ 9, 13, 9, 7, 11, 3, 17, 3, 19, 7, 19, 13 }); C(14, 19, 2) end,
  unlock = function(P, C) P({ 5, 13, 23, 13, 23, 26, 5, 26, 5, 13 }); P({ 9, 13, 9, 5, 11, 1, 17, 1, 19, 5, 19, 8 }); C(14, 19, 2) end,
  speaker = function(P) P({ 3, 10, 8, 10, 15, 4, 15, 24, 8, 18, 3, 18, 3, 10 }); P({ 19, 10, 21, 14, 19, 18 }); P({ 22, 6, 26, 14, 22, 22 }) end,
  star = function(P)
    local t = {}
    for k = 0, 10 do
      local rad = (k % 2 == 0) and 13 or 5.5
      local a = math.rad(-90 + k * 36)
      t[#t + 1] = 14 + rad * math.cos(a); t[#t + 1] = 15 + rad * math.sin(a)
    end
    P(t)
  end,
  play = function(P) P({ 7, 3, 24, 14, 7, 25, 7, 3 }) end,
  button = function(_P, C, _on, Dk) C(14, 14, 12); Dk(14, 14, 5) end,
  person = function(P, C) C(14, 8, 6); P({ 3, 27, 4, 22, 8, 17, 20, 17, 24, 22, 25, 27 }) end,
  sun = function(P, C)
    C(14, 14, 6)
    for k = 0, 7 do
      local a = math.rad(k * 45)
      P({ 14 + 9 * math.cos(a), 14 + 9 * math.sin(a), 14 + 13 * math.cos(a), 14 + 13 * math.sin(a) })
    end
  end,
  garage = function(P) P({ 1, 12, 14, 3, 27, 12 }); P({ 4, 10, 4, 26, 24, 26, 24, 10 }); P({ 8, 26, 8, 14, 20, 14, 20, 26 }); P({ 8, 18, 20, 18 }); P({ 8, 22, 20, 22 }) end,
  blind = function(P, C) P({ 3, 3, 25, 3 }); P({ 5, 8, 23, 8 }); P({ 5, 13, 23, 13 }); P({ 5, 18, 23, 18 }); P({ 14, 18, 14, 24 }); C(14, 25, 2) end,
  alert = function(P, C) P({ 14, 2, 27, 25, 1, 25, 14, 2 }); P({ 14, 9, 14, 17 }); C(14, 21, 1) end,
  dot = function(_P, C) C(14, 14, 7); C(14, 14, 2) end,
}

-- an icon of kind in a box of size s at (x, y)
function D.icon(gg, kind, x, y, s, on)
  local f = s / 28
  local function P(t)
    local o = {}
    for i, v in ipairs(t) do o[i] = r((i % 2 == 1) and (x + v * f) or (y + v * f)) end
    gg:polyline(o)
  end
  local function C(cx, cy, rad) D.circle(gg, x + cx * f, y + cy * f, math.max(1, rad * f)) end
  local function Dk(cx, cy, rad) D.disc(gg, x + cx * f, y + cy * f, math.max(1, rad * f)) end
  local function F(fx, fy, fw, fh) gg:rect(r(x + fx * f), r(y + fy * f), math.max(1, r(fw * f)), math.max(1, r(fh * f)), { fill = true }) end
  local sh = SHAPES[kind] or SHAPES.dot
  sh(P, C, on, Dk, F)
end

------------------------------------------------------------------ controls

-- an on/off switch: a pill with its knob right (on, filled) or left (off, hollow)
function D.switch(gg, x, y, w, h, on)
  D.rrect(gg, x, y, w, h, h // 2, on and 2 or 1)
  local kr = h // 2 - 5
  if on then D.disc(gg, x + w - h // 2, y + h // 2, kr) else D.circle(gg, x + h // 2, y + h // 2, kr) end
end

-- a thin bar filled to frac (0..1)
function D.bar(gg, x, y, w, h, frac)
  D.rrect(gg, x, y, w, h, h // 2, 1)
  local fw = math.floor((w - 4) * math.max(0, math.min(1, frac or 0)))
  if fw > 0 then gg:rect(x + 2, y + 2, fw, h - 4, { fill = true }) end
end

-- n rounded segments across w, the first filled ones solid; returns each segment's x and width
function D.segments(gg, x, y, w, h, n, filled, gap)
  gap = gap or 6
  local sw = (w - (n - 1) * gap) // n
  local xs = {}
  for k = 1, n do
    local sx = x + (k - 1) * (sw + gap)
    xs[k] = sx
    D.rrect(gg, sx, y, sw, h, 7, 1)
    if k <= (filled or 0) then gg:rect(sx + 6, y + 6, sw - 12, h - 12, { fill = true }) end
  end
  return xs, sw
end

-- a rounded button with a centred label; opts: font, sel (drawn thick), off (thin, label in brackets)
function D.button(gg, x, y, w, h, label, opts)
  opts = opts or {}
  local fname = opts.font or 'medium'
  D.rrect(gg, x, y, w, h, opts.radius or 12, opts.sel and 3 or (opts.off and 1 or 2))
  if label and label ~= '' then
    local s = D.fit(opts.off and ('(' .. label .. ')') or label, fname, w - 12)
    D.text(gg, x + (w - D.width(fname, s)) / 2, y + (h - D.line_h(fname)) / 2, s, fname)
  end
end

-- media and step glyphs centred on (cx, cy), about s tall
function D.glyph(gg, kind, cx, cy, s)
  local h = s / 2
  local function P(t) local o = {} for i, v in ipairs(t) do o[i] = r(v) end gg:polyline(o) end
  local function F(x, y, w, hh) gg:rect(r(x), r(y), math.max(1, r(w)), math.max(1, r(hh)), { fill = true }) end
  if kind == 'play' then
    P({ cx - h * 0.6, cy - h, cx + h, cy, cx - h * 0.6, cy + h, cx - h * 0.6, cy - h })
    P({ cx - h * 0.4, cy - h * 0.6, cx + h * 0.6, cy, cx - h * 0.4, cy + h * 0.6, cx - h * 0.4, cy - h * 0.6 })
  elseif kind == 'pause' then
    F(cx - h * 0.7, cy - h, h * 0.45, 2 * h); F(cx + h * 0.25, cy - h, h * 0.45, 2 * h)
  elseif kind == 'next' or kind == 'prev' then
    local d = kind == 'next' and 1 or -1
    for k = 0, 1 do
      local o = (k == 0 and -h * 0.9 or 0) * d
      P({ cx + o, cy - h * 0.8, cx + o + h * 0.9 * d, cy, cx + o, cy + h * 0.8, cx + o, cy - h * 0.8 })
    end
    F(kind == 'next' and (cx + h * 0.9) or (cx - h * 0.9 - 3), cy - h * 0.8, 3, h * 1.6)
  elseif kind == 'plus' or kind == 'minus' then
    F(cx - h * 0.7, cy - 2, h * 1.4, 4)
    if kind == 'plus' then F(cx - 2, cy - h * 0.7, 4, h * 1.4) end
  elseif kind == 'back' then
    for k = 0, 2 do P({ cx + h * 0.4 + k, cy - h * 0.8, cx - h * 0.4 + k, cy, cx + h * 0.4 + k, cy + h * 0.8 }) end
  elseif kind == 'chevron' then
    P({ cx - h * 0.3, cy - h * 0.6, cx + h * 0.3, cy, cx - h * 0.3, cy + h * 0.6 })
  elseif kind == 'up' or kind == 'down' then
    local d = kind == 'up' and -1 or 1
    P({ cx - h * 0.8, cy - d * h * 0.3, cx, cy + d * h * 0.5, cx + h * 0.8, cy - d * h * 0.3 })
  elseif kind == 'stop' then
    P({ cx - h * 0.6, cy - h * 0.6, cx + h * 0.6, cy - h * 0.6, cx + h * 0.6, cy + h * 0.6, cx - h * 0.6, cy + h * 0.6, cx - h * 0.6, cy - h * 0.6 })
  end
end

-- a round button with a glyph (or the glyph in brackets of a thin ring when off)
function D.round(gg, cx, cy, rad, glyph, opts)
  opts = opts or {}
  D.circle(gg, cx, cy, rad)
  if not opts.off then D.circle(gg, cx, cy, rad - 1); if opts.sel then D.circle(gg, cx, cy, rad - 2) end end
  if not opts.off then D.glyph(gg, glyph, cx, cy, rad * 0.8) end
end

------------------------------------------------------------------ the date

local MONTHS = { 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
                 'November', 'December' }
local WEEKDAYS = { 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday' }

-- ctx.clock:now() -> "Tuesday, 28 October", from the local time of day and the epoch
function D.date(t)
  if type(t) ~= 'table' or not tonumber(t.epoch_sec) or not tonumber(t.hour) then return '' end
  local ep = math.floor(tonumber(t.epoch_sec))
  local local_sod = tonumber(t.hour) * 3600 + (tonumber(t.minute) or 0) * 60 + (tonumber(t.second) or 0)
  local off = local_sod - ep % 86400
  if off > 14 * 3600 then off = off - 86400 elseif off < -12 * 3600 then off = off + 86400 end
  local days = (ep + off) // 86400
  -- civil date from days since 1970-01-01 (H. Hinnant's algorithm)
  local z = days + 719468
  local era = z // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return WEEKDAYS[(days + 4) % 7 + 1] .. ', ' .. d .. ' ' .. MONTHS[m]
end
function D.clock(t)
  if type(t) ~= 'table' or not tonumber(t.hour) then return '' end
  return string.format('%02d:%02d', tonumber(t.hour), tonumber(t.minute) or 0)
end

return D
