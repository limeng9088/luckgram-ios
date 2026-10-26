load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Luckgram — private notes (spec 05).
swift_library(
    name = "LuckgramUserNotes",
    module_name = "LuckgramUserNotes",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/AccountContext:AccountContext",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/ItemListPeerItem:ItemListPeerItem",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/LocalizedPeerData:LocalizedPeerData",
        "//submodules/AppBundle:AppBundle",
    ],
    visibility = [
        "//visibility:public",
    ],
)
