import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Version headers on every request to the Luckgram API (specs#164): the server reads
/// `X-Luckgram-App-Build` to decide whether server-side flags such as `free_for_all` apply to this
/// build. Values that aren't plain numbers are left out rather than sent malformed.
public enum LuckgramAppHeaders {
    public static let versionHeader = "X-Luckgram-App-Version"
    public static let buildHeader = "X-Luckgram-App-Build"

    /// `CFBundleShortVersionString` (dotted numbers, 1–4 segments) and `CFBundleVersion` (digits).
    public static func headers(info: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        if let version = (info["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces), version.range(of: #"^\d+(\.\d+){0,3}$"#, options: .regularExpression) != nil {
            result[versionHeader] = version
        }
        if let build = (info["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespaces), build.range(of: #"^\d{1,12}$"#, options: .regularExpression) != nil {
            result[buildHeader] = build
        }
        return result
    }

    public static var current: [String: String] {
        return headers(info: Bundle.main.infoDictionary ?? [:])
    }

    /// Adds the headers the request doesn't already carry.
    public static func apply(_ headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers where request.value(forHTTPHeaderField: name) == nil {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }
}
