load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Luckgram 09 (more accounts): account order, local names and notification switches.
# Foundation + SwiftSignalKit only, so the notification service extension can link it.
swift_library(
    name = "LuckgramAccountsStore",
    module_name = "LuckgramAccountsStore",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
