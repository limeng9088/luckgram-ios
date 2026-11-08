load(
    "@build_bazel_rules_apple//apple:apple.bzl",
    "apple_dynamic_xcframework_import",
)

# specs#119: the built-in Xray core (XTLS/libXray, MIT; Xray-core, MPL-2.0). The xcframework is
# built in CI by scripts/luckgram-xray-build.sh and is not in git. Linked by the app binary only
# (//Telegram:Lib), never by TelegramUIFramework, so extensions do not load a Go runtime.
apple_dynamic_xcframework_import(
    name = "LuckgramXray",
    xcframework_imports = glob(["LuckgramXray.xcframework/**"]),
    visibility = [
        "//visibility:public",
    ],
)
