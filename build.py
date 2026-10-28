"""Build the Home Assistant mini app into dist/homeassistant.xtapp.

  python build.py            bundle, check, pack
  python build.py --test     the same, and run the offline tests first

Steps: homeassistant/bundle.py turns src/ into index.lua and lockscreen.lua; tools/lualint55.py and
(when lupa has it) a real Lua 5.5 compiler check them, since the device runs Lua 5.5 and rejects at
compile time what the Lua 5.4 tests let through; xtpack.py packs and encrypts the package.
"""
import argparse, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, 'homeassistant')

ap = argparse.ArgumentParser()
ap.add_argument('--test', action='store_true', help='run the offline tests first')
ap.add_argument('--image', help='a Licorice app image to take the device key from (see xtpack.py)')
a = ap.parse_args()


def run(*cmd):
    subprocess.run([sys.executable, '-I', *cmd], check=True)


run(os.path.join(APP, 'bundle.py'))
lua = [os.path.join(APP, f) for f in ('index.lua', 'lockscreen.lua')]
run(os.path.join(HERE, 'tools', 'lualint55.py'), *lua)
try:
    from lupa import lua55
except ImportError:
    print('lua55: not checked (pip install -U lupa)')
else:
    check = lua55.LuaRuntime().eval('function(s, n) local f, e = load(s, n); return e end')
    errors = [e for e in (check(open(f, encoding='utf-8').read(), '@' + os.path.relpath(f, HERE)) for f in lua) if e]
    for e in errors:
        print(e)
    if errors:
        sys.exit('Lua 5.5 rejects the files above')
    print('lua55: both files compile')
if a.test:
    run(os.path.join(APP, 'test_homeassistant.py'))
os.makedirs(os.path.join(HERE, 'dist'), exist_ok=True)
cmd = [os.path.join(HERE, 'xtpack.py'), APP, '-o', os.path.join(HERE, 'dist', 'homeassistant.xtapp')]
if a.image:
    cmd += ['--image', a.image]
run(*cmd)
