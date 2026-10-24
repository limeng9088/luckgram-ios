#!/usr/bin/env python3
"""Replace every Telegram app icon with the Luckgram artwork.

Sources (branding/):
  icon-1024.png        flat 1024x1024 artwork (no alpha)
  AppIcon.icon/        Icon Composer bundle (icon.json + Assets/icon.png)

Targets (Telegram/Telegram-iOS/):
  Telegram.icon/                      primary icon (bazel app_icons)
  *.alticon/*.png                     alternate icons (in-app icon picker)
  IconDefault*.png, DefaultAppIcon.xcassets, AppIcons.xcassets   legacy PNG sets
Every PNG keeps its file name and pixel size, so BUILD / Contents.json need no change.

Run from the repo root: python3 branding/apply_icon.py   (needs Pillow)
"""
import glob
import os
import shutil

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, 'branding')
APP = os.path.join(ROOT, 'Telegram', 'Telegram-iOS')


def main():
    art = Image.open(os.path.join(BRAND, 'icon-1024.png')).convert('RGB')  # app icons must not have alpha
    assert art.size == (1024, 1024), art.size

    # Primary icon: swap the whole Icon Composer bundle.
    dst = os.path.join(APP, 'Telegram.icon')
    shutil.rmtree(dst)
    shutil.copytree(os.path.join(BRAND, 'AppIcon.icon'), dst)

    patterns = ['*.alticon/*.png', 'IconDefault*.png', 'DefaultAppIcon.xcassets/**/*.png', 'AppIcons.xcassets/**/*.png']
    files = sorted({f for p in patterns for f in glob.glob(os.path.join(APP, p), recursive=True)})
    for f in files:
        with Image.open(f) as old:
            size = old.size
        art.resize(size, Image.LANCZOS).save(f, optimize=True)
    print('Telegram.icon replaced, {} PNGs re-rendered'.format(len(files)))


if __name__ == '__main__':
    main()
