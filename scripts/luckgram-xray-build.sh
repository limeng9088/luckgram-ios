#!/bin/bash
# specs#119: builds LuckgramXray.xcframework, the built-in Xray core, for the app.
#
#   scripts/luckgram-xray-build.sh <output dir of the xcframework> [cache dir]
#
# XTLS/libXray (MIT) with Xray-core (MPL-2.0) at LIBXRAY_VERSION, compiled with Go as a C archive
# (libXray's cgo_bridge: CGoInvoke / CGoFree) and linked into a small dynamic framework per
# platform: iphoneos arm64, iphonesimulator arm64 + x86_64. Only the main app links it (not the
# extensions, which load TelegramUIFramework); Swift finds CGoInvoke with dlsym, so nothing
# imports a module. Needs Xcode and Go (go.mod of libXray decides the version). With a cache dir,
# a finished build for the same version is reused.
set -euo pipefail

OUT=${1:?output dir}
CACHE=${2:-}
LIBXRAY_VERSION=${LIBXRAY_VERSION:-v26.10.31}
REV=1 # bump when this script's output changes
MIN_IOS=15.0
NAME=LuckgramXray

if [ -n "$CACHE" ] && [ -f "$CACHE/$LIBXRAY_VERSION-r$REV/$NAME.xcframework/Info.plist" ]; then
  echo "LuckgramXray: cached $LIBXRAY_VERSION-r$REV"
  rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
  cp -R "$CACHE/$LIBXRAY_VERSION-r$REV/$NAME.xcframework" "$OUT"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
git clone -q --depth 1 --branch "$LIBXRAY_VERSION" https://github.com/XTLS/libXray.git "$WORK/libXray"
go version

# slice: <goarch> <sdk> <clang arch> <clang target>
build_slice() {
  local goarch=$1 sdk=$2 arch=$3 target=$4
  local dir="$WORK/$sdk-$arch"
  local sysroot; sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  local flags="-isysroot $sysroot -target $target -arch $arch"
  mkdir -p "$dir"
  (
    cd "$WORK/libXray"
    GOOS=ios GOARCH=$goarch CGO_ENABLED=1 GOFLAGS=-tags=ios \
    CC="xcrun --sdk $sdk clang" CXX="xcrun --sdk $sdk clang++" \
    CGO_CFLAGS="$flags" CGO_CXXFLAGS="$flags" CGO_LDFLAGS="$flags" \
      go build -trimpath -buildvcs=false -buildmode=c-archive \
        -ldflags="-s -w -buildid= -checklinkname=0" -o "$dir/libxray.a" ./cgo_bridge
  )
  xcrun --sdk "$sdk" clang $flags -dynamiclib -o "$dir/$NAME" \
    -Wl,-all_load "$dir/libxray.a" \
    -framework Foundation -framework Security -framework CoreFoundation -lresolv \
    -install_name "@rpath/$NAME.framework/$NAME" \
    -Wl,-exported_symbol,_CGoInvoke -Wl,-exported_symbol,_CGoFree \
    -Wl,-dead_strip -Wl,-x
}

make_framework() { # <dir> <binary> <platform>
  local fw="$1/$NAME.framework"
  mkdir -p "$fw"
  cp "$2" "$fw/$NAME"
  cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>cc.luckgram.xray</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${LIBXRAY_VERSION#v}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$3</string></array>
  <key>MinimumOSVersion</key><string>$MIN_IOS</string>
</dict>
</plist>
PLIST
}

build_slice arm64 iphoneos arm64 "arm64-apple-ios$MIN_IOS"
build_slice arm64 iphonesimulator arm64 "arm64-apple-ios$MIN_IOS-simulator"
build_slice amd64 iphonesimulator x86_64 "x86_64-apple-ios$MIN_IOS-simulator"

mkdir -p "$WORK/fw/device" "$WORK/fw/sim"
make_framework "$WORK/fw/device" "$WORK/iphoneos-arm64/$NAME" iPhoneOS
lipo -create "$WORK/iphonesimulator-arm64/$NAME" "$WORK/iphonesimulator-x86_64/$NAME" -output "$WORK/sim-$NAME"
make_framework "$WORK/fw/sim" "$WORK/sim-$NAME" iPhoneSimulator

rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
  -framework "$WORK/fw/device/$NAME.framework" \
  -framework "$WORK/fw/sim/$NAME.framework" \
  -output "$OUT"

for f in "$WORK/iphoneos-arm64/$NAME" "$WORK/sim-$NAME"; do
  ls -l "$f"
  nm -gU "$f" | grep -E ' _CGo(Invoke|Free)$'
done

if [ -n "$CACHE" ]; then
  mkdir -p "$CACHE/$LIBXRAY_VERSION-r$REV"
  rm -rf "$CACHE/$LIBXRAY_VERSION-r$REV/$NAME.xcframework"
  cp -R "$OUT" "$CACHE/$LIBXRAY_VERSION-r$REV/$NAME.xcframework"
fi
