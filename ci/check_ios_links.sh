#!/bin/bash
# Luckgram：检查 iOS 产物链接的动态库（luckgram-specs#57）。
# 用 iOS 27 SDK 编译时，调用 WebKit 的 Swift overlay API 会让 App 强链接 /usr/lib/swift/libswiftWebKit.dylib。
# iOS 26 以下没有这个库，App 一启动就闪退。所以 App 里任何 Mach-O 文件都不能链接 libswiftWebKit（弱链接也不行）。
#
# 用法：ci/check_ios_links.sh <Telegram.ipa | Telegram.app>     需要 macOS（otool）
set -euo pipefail
IN="$1"
FORBIDDEN='libswiftWebKit'

TMP=""
if [[ "$IN" == *.ipa ]]; then
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  unzip -q "$IN" -d "$TMP"
  APP=$(ls -d "$TMP"/Payload/*.app | head -1)
else
  APP="$IN"
fi
[ -d "$APP" ] || { echo "::error::app bundle not found: $IN"; exit 1; }

checked=0; bad=0
# 按文件内容识别 Mach-O（不依赖可执行权限位，unzip 不一定保留）
while IFS= read -r f; do
  [ -n "$f" ] || continue
  checked=$((checked + 1))
  hits=$(otool -L "$f" | grep "$FORBIDDEN" || true)
  if [ -n "$hits" ]; then
    bad=$((bad + 1))
    echo "::error::${f#"$APP"/} links $FORBIDDEN (iOS < 26 will crash on launch, luckgram-specs#57):"
    echo "$hits"
  fi
done < <(find "$APP" -type f -print0 | xargs -0 file -F '|' | awk -F'|' '/Mach-O/ {print $1}')

echo "checked $checked Mach-O files in $(basename "$APP"): $bad link $FORBIDDEN"
[ "$checked" -gt 0 ] || { echo "::error::no Mach-O files found"; exit 1; }
[ "$bad" -eq 0 ]
