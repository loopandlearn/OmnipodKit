//
//  LocalizationCatalogLoader.swift
//  OmniTests
//

import Foundation

enum LocalizationCatalogLoader {

    static func localizableXcstringsURL(file: StaticString = #file) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Localization/Localizable.xcstrings")
    }

    struct LocalizedStringEntry {
        let key: String
        let locale: String
        let value: String
    }

    /// Per-locale values plus each catalog key checked as `locale == "key"`.
    static func loadEntries(from url: URL) throws -> [LocalizedStringEntry] {
        let data = try Data(contentsOf: url)
        let catalog = try JSONDecoder().decode(XcstringsCatalog.self, from: data)
        var entries: [LocalizedStringEntry] = []

        for (key, entry) in catalog.strings {
            entries.append(LocalizedStringEntry(key: key, locale: "key", value: key))
            guard let localizations = entry.localizations else { continue }
            for (locale, localization) in localizations {
                guard let value = localization.stringUnit?.value else { continue }
                entries.append(LocalizedStringEntry(key: key, locale: locale, value: value))
            }
        }
        return entries
    }

    static func stringsTableByLocale(from entries: [LocalizedStringEntry]) -> [String: [String: String]] {
        var byLocale: [String: [String: String]] = [:]
        for entry in entries {
            byLocale[entry.locale, default: [:]][entry.key] = entry.value
        }
        return byLocale
    }

    /// Line number in `Localizable.xcstrings` where the string key is declared (`"…" : {`).
    static func loadKeyLineNumbers(from url: URL) throws -> [String: Int] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let catalog = try JSONDecoder().decode(XcstringsCatalog.self, from: Data(contentsOf: url))
        var lineNumbers: [String: Int] = [:]

        for key in catalog.strings.keys {
            let needle = "\"\(escapeJSONStringKey(key))\" : {"
            if let range = content.range(of: needle) {
                let prefix = content[..<range.lowerBound]
                lineNumbers[key] = prefix.filter(\.isNewline).count + 1
            }
        }

        return lineNumbers
    }

    private static func escapeJSONStringKey(_ key: String) -> String {
        key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

// MARK: - Decodable types for String Catalog JSON

private struct XcstringsCatalog: Decodable {
    let strings: [String: XcstringsStringEntry]
}

private struct XcstringsStringEntry: Decodable {
    let localizations: [String: XcstringsLocalization]?
}

private struct XcstringsLocalization: Decodable {
    let stringUnit: XcstringsStringUnit?
}

private struct XcstringsStringUnit: Decodable {
    let value: String?
}
