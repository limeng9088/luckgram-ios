import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

/// spec 18 需求 5: "问 AI" in the message menu. Builds the text that goes into the assistant's input
/// field: the message text, its links, the file name and, for text files of at most 1 MB that are
/// already on the device, their content.
public enum LuckgramAskAI {
    static let maxTextFile: Int64 = 1024 * 1024
    private static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm", "log", "yaml", "yml",
        "ini", "conf", "srt", "vtt", "java", "kt", "swift", "js", "ts", "py", "go", "rs", "c", "h", "cpp", "hpp", "cs", "rb", "php", "sh", "sql", "css"]

    private static func file(_ message: EngineMessage) -> TelegramMediaFile? {
        guard let file = message.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile else {
            return nil
        }
        if file.isVoice || file.isInstantVideo || file.isSticker || file.isAnimatedSticker {
            return nil
        }
        return file
    }

    private static func webpageURL(_ message: EngineMessage) -> String? {
        for media in message.media {
            if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content, !content.url.isEmpty {
                return content.url
            }
        }
        return nil
    }

    public static func canAsk(_ message: EngineMessage) -> Bool {
        return LuckgramAIChatController.isEnabled && (!message.text.isEmpty || self.file(message) != nil || self.webpageURL(message) != nil)
    }

    static func isTextFile(mimeType: String, name: String?) -> Bool {
        if mimeType.hasPrefix("text/") || mimeType == "application/json" || mimeType == "application/xml" {
            return true
        }
        guard let ext = name?.split(separator: ".").last, name?.contains(".") == true else {
            return false
        }
        return self.textExtensions.contains(ext.lowercased())
    }

    public static func prompt(context: AccountContext, messages: [EngineMessage]) -> Signal<String, NoError> {
        var text = ""
        var links: [String] = []
        var fileParts: [Signal<String, NoError>] = []
        for message in messages {
            if !message.text.isEmpty {
                if !text.isEmpty {
                    text += "\n\n"
                }
                text += message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for attribute in message.attributes {
                if let attribute = attribute as? TextEntitiesMessageAttribute {
                    for entity in attribute.entities {
                        if case let .TextUrl(url) = entity.type, !links.contains(url) {
                            links.append(url)
                        }
                    }
                }
            }
            if let url = self.webpageURL(message), !message.text.contains(url), !links.contains(url) {
                links.append(url)
            }
            if let file = self.file(message) {
                var header = ""
                if let name = file.fileName, !name.isEmpty {
                    header = "\n" + LuckgramStrings.pick("文件：", "File: ") + name
                }
                if self.isTextFile(mimeType: file.mimeType, name: file.fileName), let size = file.size, size <= self.maxTextFile {
                    let content: Signal<String, NoError> = context.engine.resources.data(id: EngineMediaResource.Id(file.resource.id))
                    |> take(1)
                    |> map { data -> String in
                        guard data.isComplete, let bytes = try? Data(contentsOf: URL(fileURLWithPath: data.path)), bytes.count <= Int(maxTextFile), let string = String(data: bytes, encoding: .utf8) else {
                            return header
                        }
                        return header + "\n" + LuckgramStrings.pick("文件内容：", "File content:") + "\n```\n" + string.trimmingCharacters(in: .whitespacesAndNewlines) + "\n```"
                    }
                    fileParts.append(content)
                } else {
                    fileParts.append(.single(header))
                }
            }
        }
        var head = text
        for link in links {
            head += "\n" + LuckgramStrings.pick("链接：", "Link: ") + link
        }
        let prefix = head
        return combineLatest(fileParts)
        |> map { parts -> String in
            let result = (prefix + parts.joined()).trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? "" : result + "\n\n"
        }
    }
}
