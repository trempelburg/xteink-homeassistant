"""Offline test of Home Assistant (gamekit harness with a stand-in Home Assistant: its REST API
renders the app's templates with Jinja2, the engine Home Assistant uses, over a small house of
entities): setup and the connection test, searching and adding tiles, one request for every
tile, tiles shown by domain, a toggle that turns at once, a lock that asks first, info and edit
boxes, pages, the fallback for a token that may not use templates, errors, and the lock screen.

  pip install lupa jinja2
  python -I homeassistant/test_homeassistant.py
"""
import json, os, sys, urllib.parse
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'tools', 'gamekit'))
from harness import Game, STUBS  # noqa: E402
from lupa import lua54  # noqa: E402
from jinja2.sandbox import ImmutableSandboxedEnvironment  # noqa: E402

NOW = 1761566400          # 2025-10-27 12:00 UTC
TOKEN = 'eyJhbGciOiJIUzI1NiJ9.' + 'x' * 150 + '.sig'

DB = {
    'light.kitchen': ['on', {'friendly_name': 'Kitchen light', 'brightness': 153, 'color_mode': 'color_temp', 'color_temp_kelvin': 3000,
                             'min_color_temp_kelvin': 2200, 'max_color_temp_kelvin': 6500, 'supported_color_modes': ['color_temp', 'hs']}],
    'switch.kitchen_kettle': ['off', {'friendly_name': 'Kettle'}],
    'sensor.kitchen_temperature': ['21.46', {'friendly_name': 'Kitchen temperature', 'unit_of_measurement': '°C', 'device_class': 'temperature'}],
    'binary_sensor.front_door': ['on', {'friendly_name': 'Front door', 'device_class': 'door'}],
    'lock.front_door': ['locked', {'friendly_name': 'Front door lock', 'supported_features': 1}],
    'climate.living_room': ['heat', {'friendly_name': 'Living room', 'current_temperature': 20.5, 'temperature': 21,
                                     'hvac_modes': ['off', 'heat', 'heat_cool', 'auto'], 'target_temp_step': 0.5,
                                     'hvac_action': 'heating', 'current_humidity': 45, 'min_temp': 7, 'max_temp': 30,
                                     'preset_modes': ['none', 'eco', 'comfort', 'away', 'boost'], 'preset_mode': 'comfort',
                                     'fan_modes': ['auto', 'low', 'high'], 'fan_mode': 'auto'}],
    'scene.movie_night': ['2025-10-26T20:00:00+00:00', {'friendly_name': 'Movie night'}],
    'cover.garage': ['closed', {'friendly_name': 'Garage', 'device_class': 'garage', 'current_position': 0, 'supported_features': 15}],
    'media_player.kitchen_speaker': ['playing', {'friendly_name': 'Kitchen | speaker', 'media_title': 'Song\nTwo', 'media_artist': 'Band',
                                                 'volume_level': 0.5, 'is_volume_muted': False, 'source': 'Spotify',
                                                 'source_list': ['Spotify', 'TV'], 'supported_features': 1 | 4 | 8 | 16 | 32 | 2048 | 16384}],
    'sensor.power': ['1234.56', {'friendly_name': 'Power', 'unit_of_measurement': 'W'}],
    'person.alex': ['not_home', {'friendly_name': 'Alex'}],
    'sensor.broken': ['unavailable', {'friendly_name': 'Broken'}],
}
for k in range(9):
    DB[f'sensor.room_{k}'] = [str(18 + k), {'friendly_name': f'Room {k}', 'unit_of_measurement': '°C'}]

requests = []
mode = {'admin': True, 'fail': False, 'echo': True, 'lag': False}


class St:
    def __init__(self, eid, v):
        self.entity_id, self.state, self.attributes = eid, v[0], v[1]
        self.name = v[1].get('friendly_name', eid)


class States:
    def __call__(self, e): return DB[e][0] if e in DB else 'unknown'
    def __iter__(self): return iter([St(k, v) for k, v in DB.items()])


JENV = ImmutableSandboxedEnvironment()
JENV.globals.update(states=States(), state_attr=lambda e, a: DB.get(e, [None, {}])[1].get(a))


def state_json(eid):
    v = DB[eid]
    return {'entity_id': eid, 'state': v[0], 'attributes': v[1]}


def answer(o):
    url, method = o['url'], o['method']
    assert o['headers']['Authorization'] == 'Bearer ' + TOKEN, o['headers']
    u = urllib.parse.urlsplit(url)
    assert u.netloc == '192.168.1.20:8123' and u.scheme == 'http', url
    if mode['fail']:
        return {'status': 502, 'body': 'Bad gateway'}
    if u.path == '/api/':
        return {'status': 200, 'body': '{"message":"API running."}'}
    if u.path == '/api/template' and method == 'POST':
        if not mode['admin']:
            return {'status': 401, 'body': '401: Unauthorized'}
        tpl = json.loads(o['body'])['template']
        return {'status': 200, 'body': JENV.from_string(tpl).render()}
    if u.path.startswith('/api/states/') and method == 'GET':
        eid = u.path[len('/api/states/'):]
        if eid not in DB:
            return {'status': 404, 'body': '{"message":"Entity not found."}'}
        return {'status': 200, 'body': json.dumps(state_json(eid))}
    if u.path.startswith('/api/services/') and method == 'POST':
        dom, svc = u.path.split('/')[3:5]
        data = json.loads(o['body'])
        eid = data['entity_id']
        assert eid.startswith(dom + '.'), (eid, dom)
        a = DB[eid][1]
        before = json.loads(json.dumps(state_json(eid)))  # 'lag': the answer still has the old state
        if svc == 'turn_on' and dom == 'light':
            DB[eid][0] = 'on'
            if 'brightness_pct' in data: a['brightness'] = round(data['brightness_pct'] * 2.55)
            if 'color_temp_kelvin' in data: a['color_temp_kelvin'], a['color_mode'] = data['color_temp_kelvin'], 'color_temp'
            if 'hs_color' in data: a['hs_color'], a['color_mode'] = data['hs_color'], 'hs'
        elif svc == 'volume_set': a['volume_level'] = data['volume_level']
        elif svc == 'volume_mute': a['is_volume_muted'] = data['is_volume_muted']
        elif svc == 'select_source': a['source'] = data['source']
        elif svc in ('media_next_track', 'media_previous_track'): a['media_title'] = svc
        elif svc == 'media_play_pause': DB[eid][0] = 'paused' if DB[eid][0] == 'playing' else 'playing'
        elif svc == 'set_temperature':
            for k in ('temperature', 'target_temp_low', 'target_temp_high'):
                if k in data: a[k] = data[k]
        elif svc == 'set_hvac_mode':
            DB[eid][0] = data['hvac_mode']
            if data['hvac_mode'] == 'heat_cool':            # as Home Assistant does: a range instead of one target
                a.update(temperature=None, target_temp_low=19, target_temp_high=24, hvac_action='idle')
            elif data['hvac_mode'] == 'off':
                a.update(hvac_action='off')
        elif svc == 'set_preset_mode': a['preset_mode'] = data['preset_mode']
        elif svc == 'set_fan_mode': a['fan_mode'] = data['fan_mode']
        elif svc == 'set_cover_position': a['current_position'] = data['position']; DB[eid][0] = 'open' if data['position'] else 'closed'
        if svc not in ('toggle', 'unlock', 'lock', 'open', 'open_cover', 'close_cover'):
            return {'status': 200, 'body': json.dumps([before if mode['lag'] else state_json(eid)] if mode['echo'] else [])}
        new = {'toggle': {'on': 'off', 'off': 'on'}.get(DB[eid][0]), 'unlock': 'unlocked', 'lock': 'locked', 'open': 'open',
               'open_cover': 'open', 'close_cover': 'closed'}.get(svc)
        if new:
            DB[eid][0] = new
        if 'current_position' in DB[eid][1]:
            DB[eid][1]['current_position'] = 100 if new == 'open' else 0
        return {'status': 200, 'body': json.dumps([state_json(eid)] if new and mode['echo'] else [])}
    return {'status': 404, 'body': 'nope'}


def setup(L):
    def to_lua(v):
        if isinstance(v, dict):
            return L.table_from({k: to_lua(x) for k, x in v.items()})
        if isinstance(v, list):
            return L.table_from([to_lua(x) for x in v])
        return v

    def request(self, opts, fn):
        o = {'url': opts['url'], 'method': opts['method'], 'body': opts['body'],
             'headers': dict(opts['headers'].items()) if opts['headers'] else {}}
        requests.append(o)
        L.globals().pending_resp = to_lua(answer(o))
        L.globals().pending_fn = fn
        return L.table_from({'cancel': lambda self: None})

    L.globals().ctx.net = L.table_from({'request': request, 'keep_wifi': lambda self, ms: None})
    L.globals().ctx.json = L.table_from({'decode': lambda self, s: to_lua(json.loads(s))})
    L.execute(f"now_sec = {NOW}; ctx.clock.now = function(self) return {{ epoch_sec = now_sec, hour = 12 + (now_sec - {NOW}) // 3600, minute = (now_sec - {NOW}) // 60 % 60, second = 0 }} end")
    L.execute("lock_calls = {}; ctx.lockscreen = { is_default = function(self) return lock_is end, "
              "set_default = function(self) lock_calls[#lock_calls + 1] = 'set'; lock_is = true end, "
              "clear_default = function(self) lock_calls[#lock_calls + 1] = 'clear'; lock_is = false end }")
    return L.eval('function() local f, r = pending_fn, pending_resp; pending_fn = nil; if f then f(ctx, r) end return f ~= nil end')


g = Game(HERE)
answer_now = setup(g.L)
ctx = g.L.globals().ctx
A = lambda: g.api
def typed(s): g.L.eval('inputs[#inputs]')(ctx, s)
def later(s): g.L.execute(f'now_sec = now_sec + {s}')
def drain():
    while answer_now():
        pass
long_press = g.L.eval("function(x, y) on_input(ctx, {type='pointer', phase='down', x=x, y=y}); "
                      "on_input(ctx, {type='pointer', phase='hold', x=x, y=y}); "
                      "on_input(ctx, {type='pointer', phase='up', gesture='long', x=x, y=y}) end")
swipe = g.L.eval("function(d) on_input(ctx, {type='pointer', phase='up', gesture='swipe_' .. d, x=240, y=400}) end")
GEO = g.L.eval('__TEST.api.geo')
def tile_origin(k):        # k counted from 1 on the page
    j = k - 1
    return 12 + (j % 2) * (GEO.TW + GEO.GAP), GEO.TOP + (j // 2) * (GEO.TH + GEO.VGAP)
def tile_xy(k):            # the middle of the tile's lower half: never its corner switch
    x0, y0 = tile_origin(k)
    return x0 + 60, y0 + 70
def tile_corner(k):
    x0, y0 = tile_origin(k)
    return x0 + GEO.TW - 30, y0 + 25
def tile_texts(k):
    x0, y0 = tile_origin(k)
    return [str(d.s) for d in g.draw() if x0 <= d.x < x0 + GEO.TW and y0 <= d.y < y0 + GEO.TH]
def pick_y(k): return GEO.PICK_Y + k * GEO.PICK_H + 20
def hit(hid):               # tap a sheet control by its id
    g.draw()
    for h in A().hits().values():
        if str(h.id) == hid:
            g.tap(h.x + h.w // 2, h.y + h.h // 2); return
    raise AssertionError((hid, [str(h.id) for h in A().hits().values()]))
def body(): return json.loads(requests[-1]['body'])


# ---- the Lua side alone: tiles.txt, numbers, actions
H = A().H
tl = H.parse_tiles("# comment\n*light.kitchen = Light\n  sensor.power\nnot an id\nSwitch.X\n")
assert len(tl) == 3 and tl[1].pin and str(tl[1].label) == 'Light' and str(tl[2].id) == 'sensor.power' and str(tl[3].id) == 'switch.x'
assert '*light.kitchen = Light\nsensor.power\nswitch.x\n' in H.tiles_text(tl)
assert H.number('21.46', '°C') == '21.5°C' and H.number('1234.56', 'W') == '1235 W' and H.number('3.0', '') == '3'
assert H.base(' 192.168.1.20:8123/ ') == 'http://192.168.1.20:8123' and H.base('https://x.ui.nabu.casa') == 'https://x.ui.nabu.casa'
assert json.loads(H.json_str('a"b\\c\nd\x01')) == 'a"b\\c\nd\x01'
lk = lambda st, ex: H.can_open(g.L.table_from({'id': 'lock.x', 'state': st, 'extra': ex}))
assert lk('locked', '1') and not lk('locked', '0') and not lk('locked', '') and not lk('unavailable', '1')

# ---- setup: nothing yet, so the setup screen; a connection test
assert str(A().screen()) == 'setup' and requests == []
g.tap_label('Test')
assert 'Enter the address and the token first.' in g.texts()
g.tap(100, 96 + 30); typed(' 192.168.1.20:8123/ ')
g.tap(100, 96 + 84 + 30); typed(TOKEN)
assert 'eyJh...esig' not in g.texts() and 'eyJh....sig' in g.texts(), g.texts()
g.tap_label('Test')
assert requests[-1]['url'] == 'http://192.168.1.20:8123/api/' and 'Connecting...' in g.texts()
answer_now()
assert str(A().screen()) == 'main' and 'Connected.' in g.texts()
assert 'url=http://192.168.1.20:8123\ntoken=' + TOKEN + '\ntitle=Home\nlock=false' == g.store['ha.txt']
assert any(t.startswith('No tiles yet.') for t in g.texts())

# ---- add tiles: search, the list, tap to add
g.tap_label('Add'); typed('kitchen')
assert requests[-1]['method'] == 'POST' and requests[-1]['url'].endswith('/api/template')
answer_now()
assert str(A().screen()) == 'pick'
t = g.texts()
assert '[ ] Kitchen light' in t and '[ ] Kitchen / speaker' in t and 'sensor.kitchen_temperature' in t and 'Kettle' not in t, t
names = [str(r.id) for r in A().picks().values()]
assert names == sorted(names) and len(names) == 4 and 'switch.kitchen_kettle' in names    # "kitchen" in the id
for k, eid in enumerate(names):
    g.tap(100, pick_y(k))
assert '[x] Kitchen light' in g.texts()
g.tap(100, pick_y(0)); g.tap(100, pick_y(0))               # off and on again: kept once
g.tap_label('Search again'); typed("front' {{door")         # quotes and braces never reach the template
assert "'front door'" in json.loads(requests[-1]['body'])['template']
answer_now()
g.tap(100, pick_y(0)); g.tap(100, pick_y(1))
for q in ('climate', 'scene', 'garage', 'power', 'alex', 'broken'):
    g.tap_label('Search again'); typed(q); answer_now(); g.tap(100, pick_y(0))
assert len(A().tiles()) == 12, [str(t.id) for t in A().tiles().values()]
g.tap_label('Done')
tpl = json.loads(requests[-1]['body'])['template']
assert 'light.kitchen' in tpl and 'person.alex' in tpl
answer_now()
assert 'updated=' + str(NOW) in g.store['states.txt']
assert g.store['tiles.txt'].count('\n') == 13

# ---- the tiles, by domain
ids = [str(t.id) for t in A().tiles().values()]
def tile(eid): return tile_texts(ids.index(eid) + 1)
assert tile('light.kitchen')[0].startswith('Kitchen') and tile('light.kitchen')[1:] == ['On 60%'], tile('light.kitchen')
assert tile('switch.kitchen_kettle') == ['Kettle', 'Off'], tile('switch.kitchen_kettle')
assert tile('sensor.kitchen_temperature')[1] == '21.5°C', tile('sensor.kitchen_temperature')
assert tile('media_player.kitchen_speaker')[0].startswith('Kitchen') and tile('media_player.kitchen_speaker')[1:] == ['Playing', 'Song Two'], tile('media_player.kitchen_speaker')
assert tile('binary_sensor.front_door')[1] == 'Open' and tile('lock.front_door')[1] == 'Locked'
assert tile('climate.living_room') == ['Living room', '20.5°', 'Heating to 21°'], tile('climate.living_room')
assert tile('scene.movie_night')[1] == 'Run' and tile('cover.garage')[1] == 'Closed'
assert '1235 W' in g.texts()
# 10 a page: the 11th and 12th on page 2
swipe('left')
assert int(A().page()) == 2 and tile_texts(1) == ['Alex', 'Away'] and tile_texts(2) == ['Broken', '-', 'unavailable'], (tile_texts(1), tile_texts(2))
swipe('left'); assert int(A().page()) == 2
g.key('up'); assert int(A().page()) == 1

# ---- a toggle turns at once, the answer's states confirm it
n = len(requests)
x, y = tile_xy(ids.index('switch.kitchen_kettle') + 1)
g.tap(x, y)
assert requests[-1]['url'].endswith('/api/services/switch/toggle') and json.loads(requests[-1]['body']) == {'entity_id': 'switch.kitchen_kettle'}
assert tile('switch.kitchen_kettle')[1] == 'On'               # before the answer
answer_now()
assert len(requests) == n + 1 and tile('switch.kitchen_kettle')[1] == 'On' and 'switch.kitchen_kettle|on|' in g.store['states.txt']
# an answer without states: asked again
mode['echo'] = False
g.tap(x, y); answer_now()
assert requests[-1]['url'].endswith('/api/template'); answer_now()
assert tile('switch.kitchen_kettle')[1] == 'Off'
mode['echo'] = True
# a failure turns the tile back
mode['fail'] = True
g.tap(x, y)
assert tile('switch.kitchen_kettle')[1] == 'On'
answer_now()
assert tile('switch.kitchen_kettle')[1] == 'Off' and 'Failed: HTTP 502' in g.texts()
mode['fail'] = False

# ---- a lock asks first
n = len(requests)
x, y = tile_xy(ids.index('lock.front_door') + 1)
g.tap(x, y)
assert 'Unlock' in g.texts() and 'Open door' in g.texts() and len(requests) == n
g.tap_label('Cancel'); assert len(requests) == n
g.tap(x, y); g.tap_label('Unlock')
assert requests[-1]['url'].endswith('/api/services/lock/unlock'); answer_now()
assert tile('lock.front_door')[1] == 'Unlocked'
g.tap(x, y)                                                # a Nuki also unlatches, after asking again
assert 'Front door lock' in g.texts() and 'Lock' in g.texts() and 'Open door' in g.texts()
g.tap_label('Open door')
assert 'Open the door?' in g.texts() and len(requests) == n + 1
g.tap_label('Cancel'); assert len(requests) == n + 1
g.tap(x, y); g.tap_label('Open door'); g.tap_label('Open')
assert requests[-1]['url'].endswith('/api/services/lock/open') and body() == {'entity_id': 'lock.front_door'}; answer_now()
assert tile('lock.front_door')[1] == 'Open'
DB['lock.front_door'][0] = 'unlocked'                      # a Nuki latches again, unlocked
g.tap_label('Refresh'); answer_now()
x, y = tile_xy(ids.index('cover.garage') + 1)
g.tap(x, y); assert str(A().screen()) == 'sheet'; answer_now()
g.tap_label('Open')
assert requests[-1]['url'].endswith('/api/services/cover/open_cover'); answer_now()
hit('p40'); assert body() == {'entity_id': 'cover.garage', 'position': 40}; answer_now()
assert 'Open  ·  40% open' in g.texts(), g.texts()
hit('back')
assert str(A().screen()) == 'main' and tile('cover.garage')[1] == 'Open 40%', tile('cover.garage')

# ---- a light: its corner switch toggles, the rest of the tile opens its sheet
k = ids.index('light.kitchen') + 1
g.tap(*tile_corner(k))
assert requests[-1]['url'].endswith('/api/services/light/toggle') and str(A().screen()) == 'main'
assert tile('light.kitchen')[1] == 'Off'; answer_now()
g.tap(*tile_xy(k))
assert str(A().screen()) == 'sheet' and requests[-1]['url'].endswith('/api/states/light.kitchen'); answer_now()
t = g.texts()
for s in ['Kitchen light', 'Off', 'Brightness', 'Warmth', 'Warm', 'Daylight', 'Colour', 'Purple']:
    assert s in t, (s, t)
hit('b30')
assert requests[-1]['url'].endswith('/api/services/light/turn_on') and body() == {'entity_id': 'light.kitchen', 'brightness_pct': 30}
assert 'On, 30% brightness' in g.texts()                     # before the answer
answer_now()
assert 'On, 30% brightness' in g.texts() and DB['light.kitchen'][1]['brightness'] == 76
hit('plus'); assert body()['brightness_pct'] == 40; answer_now()
hit('Night'); assert body()['brightness_pct'] == 5; answer_now()
hit('plus'); assert body()['brightness_pct'] == 10; answer_now()        # − / + go to the tens
hit('plus'); assert body()['brightness_pct'] == 20; answer_now()
hit('minus'); assert body()['brightness_pct'] == 10; answer_now()
mode['lag'] = True                                                      # an answer without the change yet
hit('plus'); answer_now()
assert 'On, 20% brightness' in g.texts(), g.texts()                     # the bar does not jump back
g.L.eval('on_tick')(ctx)
assert requests[-1]['url'].endswith('/api/states/light.kitchen'); answer_now()
mode['lag'] = False
assert 'On, 20% brightness' in g.texts()
hit('plus'); hit('plus')                                                # quick taps: 30, then 40 waits
assert body()['brightness_pct'] == 30
answer_now()                                                            # 30's answer: overtaken, not shown
assert body()['brightness_pct'] == 40 and 'On, 40% brightness' in g.texts(), g.texts()
answer_now()
assert 'On, 40% brightness' in g.texts() and DB['light.kitchen'][1]['brightness'] == 102
hit('Daylight'); assert body() == {'entity_id': 'light.kitchen', 'color_temp_kelvin': 6000}; answer_now()
assert '6000 K' in g.texts()
hit('Warm'); assert body()['color_temp_kelvin'] == 2700; answer_now()
hit('Blue'); assert body() == {'entity_id': 'light.kitchen', 'hs_color': [230, 100]}; answer_now()
hit('power'); assert requests[-1]['url'].endswith('/light/toggle'); answer_now()
assert 'Off' in g.texts()
assert g.commands() < 500, g.commands()
g.key('back')
assert str(A().screen()) == 'main' and A().sheet() is None

# ---- a speaker: tracks, volume (taps while busy: the latest waits), mute, source
k = ids.index('media_player.kitchen_speaker') + 1
g.tap(*tile_corner(k))
assert requests[-1]['url'].endswith('/api/services/media_player/media_play_pause'); answer_now()
g.tap(*tile_xy(k)); answer_now()
t = g.texts()
for s in ['Kitchen | speaker', 'Paused  ·  Spotify', 'Song', 'Two', 'Band', 'Volume', '50%', 'Mute', 'Source: Spotify']:
    assert s in t, (s, t)
hit('next'); assert requests[-1]['url'].endswith('/media_next_track'); answer_now()
assert 'media_next_track' in g.texts(), g.texts()
hit('prev'); assert requests[-1]['url'].endswith('/media_previous_track'); answer_now()
hit('playpause'); assert requests[-1]['url'].endswith('/media_play_pause'); answer_now()
assert 'Playing  ·  Spotify' in g.texts()
n = len(requests)
hit('v30'); hit('v70'); hit('v80')                          # sent, then two taps while it is out
assert len(requests) == n + 1 and body()['volume_level'] == 0.3 and '80%' in g.texts()
answer_now()
assert len(requests) == n + 2 and body()['volume_level'] == 0.8   # the second tap was replaced by the third
answer_now()
assert len(requests) == n + 2 and DB['media_player.kitchen_speaker'][1]['volume_level'] == 0.8 and '80%' in g.texts()
hit('vol-'); assert body()['volume_level'] == 0.75; answer_now()
hit('mute'); assert body() == {'entity_id': 'media_player.kitchen_speaker', 'is_volume_muted': True}; answer_now()
assert 'muted' in g.texts() and 'Unmute' in g.texts()
hit('source'); g.tap_label('TV')
assert body() == {'entity_id': 'media_player.kitchen_speaker', 'source': 'TV'}; answer_now()
assert 'Source: TV' in g.texts()
assert 'onoff' not in [str(h.id) for h in A().hits().values()]   # this speaker cannot be switched off
assert g.commands() < 500, g.commands()
hit('back')

# ---- a thermostat: target and mode
g.tap(*tile_xy(ids.index('climate.living_room') + 1)); answer_now()
t = g.texts()
for s in ['Living room', '20.5° now · Heating · 45% humidity', 'Target', '21°', 'Mode', 'Heat', 'Heat cool',
          'Preset', 'Eco', 'Comfort', 'Boost', 'Fan', 'Low']:
    assert s in t, (s, t)
hit('temp+'); assert body() == {'entity_id': 'climate.living_room', 'temperature': 21.5}; answer_now()
assert '21.5°' in g.texts()
for _ in range(20):                                          # never past max_temp
    hit('temp+'); answer_now()
assert DB['climate.living_room'][1]['temperature'] == 30
hit('temp-'); answer_now(); assert DB['climate.living_room'][1]['temperature'] == 29.5
hit('preset:eco'); assert body() == {'entity_id': 'climate.living_room', 'preset_mode': 'eco'}
assert 'preset:eco' in [str(h.id) for h in A().hits().values()]; answer_now()
hit('fan:high'); assert body() == {'entity_id': 'climate.living_room', 'fan_mode': 'high'}; answer_now()
assert 'High' in g.texts() and 'Fan' in g.texts()
# heat_cool: a range instead of one target; both ends are sent together and never cross
hit('heat_cool'); assert body() == {'entity_id': 'climate.living_room', 'hvac_mode': 'heat_cool'}; answer_now()
t = g.texts()
assert 'Target range' in t and 'Heat to' in t and 'Cool to' in t and '19°' in t and '24°' in t and 'Target' not in t, t
hit('low+'); assert body() == {'entity_id': 'climate.living_room', 'target_temp_low': 19.5, 'target_temp_high': 24}; answer_now()
hit('high-'); assert body() == {'entity_id': 'climate.living_room', 'target_temp_low': 19.5, 'target_temp_high': 23.5}; answer_now()
n = len(requests)
DB['climate.living_room'][1].update(target_temp_low=23, target_temp_high=23.5)
hit('back'); g.tap(*tile_xy(ids.index('climate.living_room') + 1)); answer_now()
hit('low+'); assert len(requests) == n + 1                  # 23.5 - 23.5: not sent
assert g.commands() < 500, g.commands()
hit('back')
assert tile('climate.living_room')[:2] == ['Living room', '20.5°'] and tile('climate.living_room')[2].startswith('Heat cool · 23-2'), tile('climate.living_room')
assert A().H.climate_extra('20.5;23~23.5;idle') == ('20.5', '23-23.5°', 'idle')
assert A().H.climate_extra('20.5') == ('20.5', None, '')                 # a cache from 0.2
g.tap(*tile_xy(ids.index('climate.living_room') + 1)); answer_now()
hit('auto'); assert body() == {'entity_id': 'climate.living_room', 'hvac_mode': 'auto'}; answer_now()
hit('back')
g.no_err()

# ---- a sensor shows its details; a long press edits
x, y = tile_xy(ids.index('sensor.power') + 1)
n = len(requests)
g.tap(x, y)
assert 'Power' in g.texts() and 'sensor.power' in g.texts() and len(requests) == n
g.tap_label('Close')
long_press(*tile_xy(1))
assert 'Pin to lock' in g.texts() and '(Move back)' in g.texts()
first = ids[0]
g.tap_label('Pin to lock')
assert g.store['tiles.txt'].split('\n')[1] == '*' + first
long_press(*tile_xy(1)); g.tap_label('Rename'); typed('Kitchen # = ceiling')
assert g.store['tiles.txt'].split('\n')[1] == '*' + first + ' = Kitchen ceiling'
long_press(*tile_xy(1)); g.tap_label('Move on')
assert g.store['tiles.txt'].split('\n')[2] == '*' + first + ' = Kitchen ceiling'
for eid in ('lock.front_door', 'binary_sensor.front_door', 'sensor.kitchen_temperature', 'climate.living_room'):
    ids = [str(t.id) for t in A().tiles().values()]
    long_press(*tile_xy(ids.index(eid) + 1)); g.tap_label('Pin to lock')
ids = [str(t.id) for t in A().tiles().values()]
assert ids.index('sensor.broken') == 11
swipe('left')
long_press(*tile_xy(2)); g.tap_label('Remove'); g.tap_label('Remove')
assert len(A().tiles()) == 11 and 'sensor.broken' not in g.store['tiles.txt']
swipe('right')

# ---- kept: opens at once, asks again only when a minute old
n = len(requests)
g.restart()
assert len(requests) == n and 'Kettle' in g.texts()    # fresh: no question
later(61)
g.restart()
assert len(requests) == n + 1; answer_now()
later(30)
g.L.eval('on_tick')(ctx)
assert len(requests) == n + 1
later(31)
g.L.eval('on_tick')(ctx)
assert len(requests) == n + 2; answer_now()
later(11 * 60)                                             # left alone: no more asking, only the clock
g.L.eval('on_tick')(ctx)
assert len(requests) == n + 2
swipe('left'); assert len(requests) == n + 3; answer_now()   # a touch asks again
swipe('right')

# ---- a token that may not render templates: one entity at a time
mode['admin'] = False
g.tap_label('Refresh')
answer_now()
assert requests[-1]['url'].endswith('/api/states/' + str(A().tiles()[1].id)) and A().per_entity()
drain()
ids = [str(t.id) for t in A().tiles().values()]
assert 'Updating 11/11...' not in g.texts() and tile('switch.kitchen_kettle')[1] == 'Off'
DB['switch.kitchen_kettle'][0] = 'on'
g.tap_label('Refresh'); drain()
assert tile('switch.kitchen_kettle')[1] == 'On' and not any(r['url'].endswith('/api/template') for r in requests[-11:])
g.tap_label('Add'); typed('x'); answer_now()
assert "Search needs an admin's token" in ''.join(g.texts())
mode['admin'] = True

# ---- errors keep the old states
mode['fail'] = True
g.restart(); later(120); g.tap_label('Refresh'); drain()
assert 'Update failed: HTTP 502' in g.texts() and 'Kettle' in g.texts()
mode['fail'] = False

# ---- the lock screen
g.tap_label('Lock')
assert list(g.L.eval('lock_calls').values()) == ['set'] and 'lock=true' in g.store['ha.txt'] and 'Lock off' in g.texts()
g.tap_label('Refresh'); answer_now()

L2 = lua54.LuaRuntime(unpack_returned_tuples=True)
L2.execute(STUBS)
answer2 = setup(L2)
for k in ('ha.txt', 'tiles.txt', 'states.txt'):
    L2.globals().store[k] = g.store[k]
updated = int(g.store['states.txt'].split('\n')[0][len('updated='):])
L2.execute(f"now_sec = {updated} + 5 * 60")
L2.execute(open(os.path.join(HERE, 'lockscreen.lua'), encoding='utf-8').read())
draw2 = L2.eval("function() drawn, commands = {}, 0; on_draw(ctx, gg); local t = {} for _, d in ipairs(drawn) do t[#t + 1] = d.s end return t end")
n = len(requests)
t = list(draw2().values())
for s in ['Home', 'Monday, 27 October', '12:20', 'Kitchen ceili~', '21.5°C', '20.5°', 'updated 5 min ago']:
    assert s in t, (s, t)
for s in ['Front door lo~', 'Unlocked', 'Front door', 'Open']:   # unlocked and open: in the box, not as tiles
    assert s not in t, (s, t)
assert 'Kettle' not in t                                   # pinned tiles only
alerts = ' / '.join(s for s in t if '(' in s)
assert 'Front door (Open)' in alerts and 'Front door lock (Unlocked)' in alerts and 'Garage (Open 40%)' in alerts, t
assert int(L2.globals().commands) < 300, L2.globals().commands
assert len(requests) == n                                  # fresh: no question
L2.execute("now_sec = now_sec + 11 * 60")
DB['lock.front_door'][0] = 'locked'
draw2(); draw2()
assert len(requests) == n + 1                              # asked once, not on every draw
answer2()
t = list(draw2().values())
assert 'updated just now' in t and 'Front door lo~' in t and 'Locked' in t and not any('Front door lock (' in s for s in t), t

# no answer while locked (Wi-Fi off): it says so and tries less and less often
L2.execute("now_sec = now_sec + 11 * 60")
n = len(requests)
age_x = lambda s: [d.x for d in L2.globals().drawn.values() if str(d.s) == s]
draw2()
assert len(requests) == n + 1 and age_x('updated 11 min ago') == [24]         # just asked
L2.execute("now_sec = now_sec + 60")
draw2()
assert age_x('updated 12 min ago') == [58] and len(requests) == n + 1         # the Wi-Fi off sign in front
L2.execute("now_sec = now_sec + 10 * 60"); draw2()
assert len(requests) == n + 2                              # again after 10 minutes
L2.execute("now_sec = now_sec + 11 * 60"); draw2()
assert len(requests) == n + 2                              # then waits 20
L2.execute("now_sec = now_sec + 10 * 60"); draw2()
assert len(requests) == n + 3
mode['fail'] = True                                        # an answer, but an error
L2.execute("now_sec = now_sec + 40 * 60"); draw2(); answer2()
L2.execute("now_sec = now_sec + 60")
t = list(draw2().values())
assert len(requests) == n + 4 and any(s.endswith('· HA error 502') for s in t), t
mode['fail'] = False
L2.execute("now_sec = now_sec + 80 * 60"); draw2(); answer2()
t = list(draw2().values())
assert len(requests) == n + 5 and 'updated just now' in t, t
# a row of two-line tiles is lower than one with a third line
L2.globals().store['tiles.txt'] = '*sensor.power\n*switch.kitchen_kettle\n*sensor.kitchen_temperature\n*climate.living_room\n'
L2.execute("polys = {}; local pl = gg.polyline; gg.polyline = function(self, t) polys[#polys + 1] = t; return pl(self, t) end")
draw2()
frames = {}
for p in L2.globals().polys.values():
    v = list(p.values())
    if len(v) == 34:                                       # a rounded frame
        xs, ys = v[0::2], v[1::2]
        if max(xs) - min(xs) == 210: frames.setdefault(min(ys), max(ys) - min(ys))
assert sorted(frames.items()) == [(108, 96), (216, 118)], frames
L3 = lua54.LuaRuntime(unpack_returned_tuples=True)          # nothing saved yet
L3.execute(STUBS)
L3.execute(open(os.path.join(HERE, 'lockscreen.lua'), encoding='utf-8').read())
L3.eval("function() on_draw(ctx, gg) end")()
assert any('open the app to add tiles' in str(d.s) for d in L3.globals().drawn.values())

assert g.commands() < 500, g.commands()
g.no_err()
print('homeassistant tests passed')
