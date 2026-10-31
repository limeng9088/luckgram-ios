load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Luckgram: settings page, LuckgramSettings switch framework, feature registry, LuckgramAI client.
swift_library(
    name = "LuckgramUI",
    module_name = "LuckgramUI",
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
        "//submodules/AlertUI:AlertUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/UndoUI:UndoUI",
        "//submodules/ItemListPeerItem:ItemListPeerItem",
        "//submodules/AccountUtils:AccountUtils",
        "//submodules/PromptUI:PromptUI",
        "//submodules/LuckgramAccountsStore:LuckgramAccountsStore",
        "//submodules/PasscodeCore:PasscodeCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
