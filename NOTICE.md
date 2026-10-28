# Third-party code

This project's own code (`homeassistant/`, `build.py`, `tools/make_icon.py`) is under the MIT
License in `LICENSE`. It is built with tools taken from two other MIT-licensed projects; their
copyright notices stay with them.

| files | from | license |
|---|---|---|
| `xtpack.py`, `tools/gamekit/gamekit.lua`, `tools/gamekit/bundle.py`, `tools/gamekit/harness.py`, `tools/lualint55.py`, the `Pen` class in `tools/make_icon.py` | [omer-faruq-xteink/touch-licorice-apps](https://github.com/omer-faruq-xteink/touch-licorice-apps), Copyright (c) 2026 Omer Faruk Inel | MIT |
| `tools/vendor/xtapp.py`, `tools/vendor/mksd.py` | [kycube/x4pro-emu](https://github.com/kycube/x4pro-emu), Copyright (c) 2026 KFloyd.com | MIT, see `tools/vendor/LICENSE-x4pro-emu` |

The MIT License of touch-licorice-apps:

```
MIT License

Copyright (c) 2026 Omer Faruk Inel

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The packing format, the device key and the mini-app API were reverse-engineered in those two
projects; the firmware notes they are based on are in touch-licorice-apps'
[docs/firmware-notes.md](https://github.com/omer-faruq-xteink/touch-licorice-apps/blob/main/docs/firmware-notes.md).

"Home Assistant" is a trademark of its owners; this project is not affiliated with or endorsed by
the Home Assistant project, Nabu Casa or Xteink.
