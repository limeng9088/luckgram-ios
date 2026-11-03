#!/usr/bin/env python3
"""Generate every Luckgram icon on iOS from one 1024x1024 source PNG.

    python3 branding/apply_icon.py [path/to/new-icon-1024.png]

With an argument the PNG is first copied to branding/icon-1024.png; without one the
existing branding/icon-1024.png is used. Run from anywhere; needs Pillow + numpy.

Source: a 1024x1024 app icon whose background is a linear gradient (or flat colour),
optionally with transparent rounded corners, and a light glyph on top. The gradient is
fitted and extended to full bleed (iOS masks the corners itself; app icons must be
opaque), and the glyph is extracted for the template images below.

Writes:
  branding/AppIcon.icon/Assets/icon.png -> Telegram/Telegram-iOS/Telegram.icon   primary icon (Icon Composer)
  Telegram-iOS/*.alticon/*.png            alternate icons (picker is hidden, but a user who
                                          picked one before still gets the Luckgram art)
  Telegram-iOS/IconDefault*.png, DefaultAppIcon.xcassets, AppIcons.xcassets      legacy PNG sets
  watch app AppIcon sets
  TelegramUI Images.xcassets: Chat/Links/QrLogo, Share/QrPlaneIcon (QR code centre),
                              Call/CallKitLogo (CallKit), Call/CallTitleLogo (call screen)
Every app-icon PNG keeps its file name and pixel size, so BUILD / Contents.json need no change.
"""
import glob
import json
import os
import shutil
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, 'branding')
SRC = os.path.join(BRAND, 'icon-1024.png')
APP = os.path.join(ROOT, 'Telegram', 'Telegram-iOS')
IMAGES = os.path.join(ROOT, 'submodules', 'TelegramUI', 'Images.xcassets')

ICON_PATTERNS = [
    'Telegram/Telegram-iOS/*.alticon/*.png',
    'Telegram/Telegram-iOS/IconDefault*.png',
    'Telegram/Telegram-iOS/DefaultAppIcon.xcassets/**/*.png',
    'Telegram/Telegram-iOS/AppIcons.xcassets/**/*.png',
    'Telegram/Watch/App/Assets.xcassets/AppIcon.appiconset/*.png',
    'Telegram/WatchApp/tgwatch Watch App/Assets.xcassets/AppIcon.appiconset/*.png',
]
# imageset -> (kind, width pt, height pt, glyph share). 'round' = full icon in a circle;
# 'glyph' = white silhouette fitted into share*(w, h) (tinted / used as templates by the code).
IMAGESETS = {
    'Chat/Links/QrLogo': ('round', 72, 72, 1.0),
    'Share/QrPlaneIcon': ('glyph', 72, 72, 0.5),
    'Call/CallKitLogo': ('glyph', 40, 40, 0.9),
    'Call/CallTitleLogo': ('glyph', 20, 15, 1.0),
}


# ---------------------------------------------------------------- layer split
# Kept identical in luckgram-android/branding/apply_icon.py.

class Layers:
    """Background gradient model + foreground glyph extracted from the source icon."""

    def __init__(self, img):
        rgba = np.asarray(img.convert('RGBA'), dtype=np.float64)
        n = rgba.shape[0]
        rgb, a = rgba[..., :3], rgba[..., 3]
        v, u = np.mgrid[0:n, 0:n] / (n - 1)
        design = np.stack([np.ones_like(u), u, v], -1).reshape(-1, 3)
        # Fit colour = c0 + cu*u + cv*v on opaque pixels, dropping the glyph as outliers.
        # Trimmed least squares: repeatedly keep the best-fitting 80% (the glyph drops out).
        opaque = (a == 255).reshape(-1)
        mask = opaque
        for i in range(10):
            coef, *_ = np.linalg.lstsq(design[mask], rgb.reshape(-1, 3)[mask], rcond=None)
            resid = np.linalg.norm(design @ coef - rgb.reshape(-1, 3), axis=1)
            thr = max(12.0, np.percentile(resid[mask], 80)) if i < 8 else 12.0
            mask = opaque & (resid < thr)
        self.coef = coef
        self.size = n
        if mask.mean() < 0.3 or np.median(resid[mask]) > 4:
            sys.exit('source background is not a linear gradient / flat colour; cannot split layers')

        bg = (design @ coef).reshape(n, n, 3)
        diff = np.linalg.norm(rgb - bg, axis=-1)
        diff[a < 255] = 0  # rounded-corner anti-aliasing is background, not glyph
        core = diff > 60
        # Anti-aliased glyph edge: coverage = diff / diff of the nearest solid glyph pixel.
        near = np.asarray(Image.fromarray(np.clip(diff * core, 0, 255).astype(np.uint8)).filter(
            ImageFilter.MaxFilter(7)), dtype=np.float64)
        alpha = np.where(core, 1.0, np.where(near > 60, np.clip(diff / np.maximum(near, 1), 0, 1), 0.0))
        alpha[alpha < 0.06] = 0
        color = bg + (rgb - bg) / np.maximum(alpha, 1e-6)[..., None]  # un-mix the old background
        fg = np.dstack([np.clip(color, 0, 255), alpha * 255]).round().astype(np.uint8)
        self.fg = Image.fromarray(fg, 'RGBA')
        if alpha.sum() < n * n * 0.01:
            sys.exit('no foreground glyph found (glyph must contrast with the background)')

    def background(self, size, lo=0.0, hi=1.0):
        """Gradient rendered at size x size, covering source coordinates lo..hi (may extrapolate)."""
        t = lo + (np.arange(size) + 0.5) / size * (hi - lo)
        v, u = np.meshgrid(t, t, indexing='ij')
        rgb = np.stack([np.ones_like(u), u, v], -1) @ self.coef
        return Image.fromarray(np.clip(rgb, 0, 255).round().astype(np.uint8), 'RGB').convert('RGBA')

    def square(self, size):
        """Opaque full-bleed icon (no rounded corners)."""
        out = self.background(self.size)
        out.alpha_composite(self.fg)
        return out.resize((size, size), Image.LANCZOS)

    def silhouette(self):
        """White glyph, alpha = coverage."""
        out = Image.new('RGBA', self.fg.size, (255, 255, 255, 0))
        out.putalpha(self.fg.getchannel('A'))
        return out


def circle(img):
    size = img.size[0]
    mask = Image.new('L', (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
    out = Image.new('RGBA', img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask.resize(img.size, Image.LANCZOS))
    return out


def centered(art, size, scale):
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    inner = round(size * scale)
    off = (size - inner) // 2
    canvas.alpha_composite(art.resize((inner, inner), Image.LANCZOS), (off, off))
    return canvas


def fit_bbox(art, size, live):
    """Crop to the glyph's bounding box and fit it (aspect kept) into live*size, centered."""
    glyph = art.crop(art.getchannel('A').getbbox())
    box = size * live
    k = box / max(glyph.size)
    glyph = glyph.resize((max(1, round(glyph.width * k)), max(1, round(glyph.height * k))), Image.LANCZOS)
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(glyph, ((size - glyph.width) // 2, (size - glyph.height) // 2))
    return canvas


def circle(img):
    size = img.size[0]
    mask = Image.new('L', (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
    out = Image.new('RGBA', img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask.resize(img.size, Image.LANCZOS))
    return out


def fit_bbox(art, w, h, live=1.0):
    """Crop to the glyph's bounding box and fit it (aspect kept) into live*(w, h), centered."""
    glyph = art.crop(art.getchannel('A').getbbox())
    k = min(w * live / glyph.width, h * live / glyph.height)
    glyph = glyph.resize((max(1, round(glyph.width * k)), max(1, round(glyph.height * k))), Image.LANCZOS)
    canvas = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    canvas.alpha_composite(glyph, ((w - glyph.width) // 2, (h - glyph.height) // 2))
    return canvas


def write_imageset(name, kind, w, h, live, L, full):
    d = os.path.join(IMAGES, name + '.imageset')
    for old in glob.glob(os.path.join(d, '*')):
        os.remove(old)
    base = os.path.basename(name)
    images = []
    for scale in (2, 3):
        fn = '%s@%dx.png' % (base, scale)
        if kind == 'round':
            img = circle(full.resize((w * scale, h * scale), Image.LANCZOS))
        else:
            img = fit_bbox(L.silhouette(), w * scale, h * scale, live)
        img.save(os.path.join(d, fn), optimize=True)
        images.append({'idiom': 'universal', 'filename': fn, 'scale': '%dx' % scale})
    with open(os.path.join(d, 'Contents.json'), 'w') as f:
        json.dump({'images': images, 'info': {'author': 'xcode', 'version': 1}}, f, indent=2)
        f.write('\n')


def main():
    if len(sys.argv) > 1:
        shutil.copyfile(sys.argv[1], SRC)
    src = Image.open(SRC).convert('RGBA')
    assert src.size == (1024, 1024), 'source must be 1024x1024, got %s' % (src.size,)
    L = Layers(src)
    full = L.square(1024)
    opaque = full.convert('RGB')  # app icons must not have alpha

    # Primary icon: Icon Composer bundle with the full-bleed art as its single layer.
    opaque.save(os.path.join(BRAND, 'AppIcon.icon', 'Assets', 'icon.png'), optimize=True)
    dst = os.path.join(APP, 'Telegram.icon')
    shutil.rmtree(dst)
    shutil.copytree(os.path.join(BRAND, 'AppIcon.icon'), dst)

    files = sorted({f for p in ICON_PATTERNS for f in glob.glob(os.path.join(ROOT, p), recursive=True)})
    for f in files:
        with Image.open(f) as old:
            size = old.size
        opaque.resize(size, Image.LANCZOS).save(f, optimize=True)

    for name, (kind, w, h, live) in IMAGESETS.items():
        write_imageset(name, kind, w, h, live, L, full)
    print('Telegram.icon replaced, %d icon PNGs and %d imagesets re-rendered' % (len(files), len(IMAGESETS)))


if __name__ == '__main__':
    main()
