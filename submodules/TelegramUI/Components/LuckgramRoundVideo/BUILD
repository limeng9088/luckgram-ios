load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

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
        "//submodules/PresentationDataUtils:PresentationDataUtils",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "LuckgramRoundVideoTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":LuckgramRoundVideo",
    ],
)

ios_test_runner(
    name = "LuckgramRoundVideoTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "LuckgramRoundVideoTests",
    minimum_os_version = "15.0",
    runner = ":LuckgramRoundVideoTestRunner",
    deps = [
        ":LuckgramRoundVideoTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
