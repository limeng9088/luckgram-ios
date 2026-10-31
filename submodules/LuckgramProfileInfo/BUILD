load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Luckgram — profile details (spec 07).
swift_library(
    name = "LuckgramProfileInfo",
    module_name = "LuckgramProfileInfo",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/AppBundle:AppBundle",
        "//submodules/LuckgramUI:LuckgramUI",
    ],
    visibility = [
        "//visibility:public",
    ],
)
