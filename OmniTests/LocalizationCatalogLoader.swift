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

    /// Cached catalog: one read, one JSON decode, file text retained for lazy line lookup.
    struct Snapshot {
        let url: URL
        let entries: [LocalizedStringEntry]
        let fileContent: String

        static func load(from url: URL) throws -> Snapshot {
            let data = try Data(contentsOf: url)
            guard let fileContent = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadUnknownStringEncoding)
            }
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

            return Snapshot(url: url, entries: entries, fileContent: fileContent)
        }

        /// Line where the key is declared (`"…" : {`). Results are cached in `lineCache`.
        func lineNumber(for key: String, lineCache: inout [String: Int]) -> Int? {
            if let cached = lineCache[key] {
                return cached
            }
            let needle = "\"\(Self.escapeJSONStringKey(key))\" : {"
            guard let range = fileContent.range(of: needle) else {
                return nil
            }
            let line = fileContent[..<range.lowerBound].filter(\.isNewline).count + 1
            lineCache[key] = line
            return line
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

    /// Per-locale values plus each catalog key checked as `locale == "key"`.
    static func loadEntries(from url: URL) throws -> [LocalizedStringEntry] {
        try Snapshot.load(from: url).entries
    }

    static func stringsTableByLocale(from entries: [LocalizedStringEntry]) -> [String: [String: String]] {
        var byLocale: [String: [String: String]] = [:]
        for entry in entries {
            byLocale[entry.locale, default: [:]][entry.key] = entry.value
        }
        return byLocale
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
