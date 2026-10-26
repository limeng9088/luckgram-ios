load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "LuckgramRoundVideo",
    module_name = "LuckgramRoundVideo",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
    ],
    visibility = [
        "//visibility:public",
    ],
)
