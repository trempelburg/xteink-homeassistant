"""Draw the app icon (homeassistant/icon.png) (96x96, black on white, 1 bpp).

  python -I tools/make_icon.py

Each icon is drawn at 4x and reduced with a threshold, so edges stay clean in 1 bpp. The Ink App
grid scales the icon to its slot and rounds the corners, so nothing important goes in the outer
6 px. xtpack.py packs APP_DIR/icon.png (docs/firmware-notes.md, "App icons").
"""
import os, sys
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
N, S = 96, 4                      # icon size, supersampling
FONTS = 'C:/Windows/Fonts/'


def font(name, px):
    for f in (name, 'arialbd.ttf', 'DejaVuSans-Bold.ttf'):
        try:
            return ImageFont.truetype(FONTS + f if os.path.isabs(FONTS + f) else f, px * S)
        except OSError:
            pass
    return ImageFont.load_default()


class Pen:
    """Coordinates in icon pixels; drawn at S times the size."""
    def __init__(self):
        self.im = Image.new('L', (N * S, N * S), 255)
        self.d = ImageDraw.Draw(self.im)

    def _b(self, box):
        return [v * S for v in box]

    def rect(self, box, w=0, fill=False, r=0):
        b = self._b(box)
        if r:
            self.d.rounded_rectangle(b, radius=r * S, fill=0 if fill else None, outline=0, width=max(1, int(w * S)) if w else 0)
        else:
            self.d.rectangle(b, fill=0 if fill else None, outline=0 if w else None, width=int(w * S))

    def line(self, pts, w):
        self.d.line([v * S for p in pts for v in p], fill=0, width=int(w * S), joint='curve')

    def ellipse(self, box, w=0, fill=False):
        self.d.ellipse(self._b(box), fill=0 if fill else None, outline=0 if w else None, width=int(w * S))

    def arc(self, box, a0, a1, w):
        self.d.arc(self._b(box), a0, a1, fill=0, width=int(w * S))

    def poly(self, pts, fill=True, w=0):
        self.d.polygon([v * S for p in pts for v in p], fill=0 if fill else None, outline=0 if w else None, width=int(w * S) or 1)

    def text(self, xy, s, f, white=False):
        """centred on xy"""
        self.d.text((xy[0] * S, xy[1] * S), s, font=f, fill=255 if white else 0, anchor='mm')

    def white_rect(self, box):
        self.d.rectangle(self._b(box), fill=255)

    def white_ellipse(self, box):
        self.d.ellipse(self._b(box), fill=255)

    def save(self, path):
        small = self.im.resize((N, N), Image.LANCZOS)
        small.point(lambda v: 0 if v < 128 else 255).convert('1').save(path)


def homeassistant(p):
    # a house outline with a light bulb inside: roof, walls, the bulb and its base
    p.line([(8, 46), (48, 10), (88, 46)], 7)
    p.line([(18, 38), (18, 86), (78, 86), (78, 38)], 6)
    p.ellipse((34, 36, 62, 64), w=5)
    p.rect((41, 64, 55, 76), fill=True, r=2)


if __name__ == '__main__':
    p = Pen()
    homeassistant(p)
    p.save(os.path.join(HERE, 'homeassistant', 'icon.png'))
    print('homeassistant/icon.png')
