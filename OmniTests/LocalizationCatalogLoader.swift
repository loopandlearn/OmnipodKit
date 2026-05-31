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

    /// All string keys and per-locale values from `Localizable.xcstrings`.
    static func loadEntries(from url: URL) throws -> [LocalizedStringEntry] {
        let data = try Data(contentsOf: url)
        let catalog = try JSONDecoder().decode(XcstringsCatalog.self, from: data)
        var entries: [LocalizedStringEntry] = []

        for (key, entry) in catalog.strings {
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
