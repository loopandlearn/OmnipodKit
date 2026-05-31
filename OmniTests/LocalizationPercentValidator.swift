//
//  LocalizationPercentValidator.swift
//  OmniTests
//
//  Validates printf-style strings in OmnipodKit localizations.
//  Stray-% logic adapted from Trio LocalizationTests.swift:
//  https://github.com/nightscout/Trio/blob/main/TrioTests/LocalizationTests.swift
//

import Foundation

struct LocalizationPercentOffender: Equatable {
    let locale: String
    let key: String
    let value: String
    let source: String
}

struct BundleStringsTable {
    let locale: String
    let source: String
    let table: [String: String]
}

struct XcstringsValidationResult {
    var stray: [LocalizationPercentOffender] = []
    var mismatched: [LocalizationPercentOffender] = []
    var nonAscii: [LocalizationPercentOffender] = []
    var mixedPositional: [LocalizationPercentOffender] = []
}

enum LocalizationPercentValidator {

    private static let xcstringsSource = "Localizable.xcstrings"

    // MARK: - Single-pass xcstrings scan

    static func validateXcstrings(
        entries: [LocalizationCatalogLoader.LocalizedStringEntry],
        source: String = xcstringsSource
    ) -> XcstringsValidationResult {
        var result = XcstringsValidationResult()

        for entry in entries {
            result.stray += strayPercentOffenders(
                locale: entry.locale,
                key: entry.key,
                value: entry.value,
                source: source
            )
            result.mismatched += mismatchedFormatSpecifierOffenders(
                locale: entry.locale,
                key: entry.key,
                value: entry.value,
                source: source
            )
            result.nonAscii += nonAsciiFormatSpecifierOffenders(
                locale: entry.locale,
                key: entry.key,
                value: entry.value,
                source: source
            )
            if entry.locale != "key" {
                result.mixedPositional += mixedPositionalFormatOffenders(
                    locale: entry.locale,
                    key: entry.key,
                    value: entry.value,
                    source: source
                )
            }
        }

        return result
    }

    // MARK: - Bundle .strings tables (load once per test class)

    static func loadStringsTables(from bundle: Bundle) -> [BundleStringsTable] {
        var tables: [BundleStringsTable] = []
        for locale in bundle.localizations where locale != "Base" {
            guard let lproj = bundle.path(forResource: locale, ofType: "lproj"),
                  let files = FileManager.default.enumerator(atPath: lproj) else { continue }

            for case let file as String in files where file.hasSuffix(".strings") {
                let path = (lproj as NSString).appendingPathComponent(file)
                guard let table = NSDictionary(contentsOfFile: path) as? [String: String] else { continue }
                tables.append(BundleStringsTable(locale: locale, source: file, table: table))
            }
        }
        return tables
    }

    static func strayPercentOffenders(inBundleTables tables: [BundleStringsTable]) -> [LocalizationPercentOffender] {
        tables.flatMap { table in
            strayPercentOffendersInStringsTable(locale: table.locale, table: table.table, source: table.source)
        }
    }

    static func mismatchedFormatSpecifierOffenders(inBundleTables tables: [BundleStringsTable]) -> [LocalizationPercentOffender] {
        tables.flatMap { table in
            mismatchedFormatSpecifierOffendersInStringsTable(locale: table.locale, table: table.table, source: table.source)
        }
    }

    static func nonAsciiFormatSpecifierOffenders(inBundleTables tables: [BundleStringsTable]) -> [LocalizationPercentOffender] {
        tables.flatMap { table in
            nonAsciiFormatSpecifierOffendersInStringsTable(locale: table.locale, table: table.table, source: table.source)
        }
    }

    static func mixedPositionalFormatOffenders(inBundleTables tables: [BundleStringsTable]) -> [LocalizationPercentOffender] {
        tables.flatMap { table in
            mixedPositionalFormatOffendersInStringsTable(locale: table.locale, table: table.table, source: table.source)
        }
    }

    /// Matches placeholders like %@, %d, %1$@, %1$03d, %g.
    private static let placeholderPattern = "%[0-9]*\\$?[.,]?[0-9]*[a-zA-Z@]"
    private static let escapedPercentPattern = "%%"
    private static let percentPattern = "%"
    /// Full token including leading percent run, e.g. `%1$d` or `%%g`.
    private static let formatTokenPattern = "%+([0-9]*\\$?[.,]?[0-9]*[a-zA-Z@])"

    private static let placeholderRegex = try! NSRegularExpression(pattern: placeholderPattern)
    private static let escapedPercentRegex = try! NSRegularExpression(pattern: escapedPercentPattern)
    private static let percentRegex = try! NSRegularExpression(pattern: percentPattern)
    private static let formatTokenRegex = try! NSRegularExpression(pattern: formatTokenPattern)
    /// Flags a format token whose width/precision/conversion run contains a non-ASCII character (e.g. `%1$03د`).
    private static let nonAsciiFormatSpecifierPattern = #"(?:%+)(?:\d+\$)?([0-9.]*)([^\x00-\x7F])"#
    private static let nonAsciiFormatSpecifierRegex = try! NSRegularExpression(pattern: nonAsciiFormatSpecifierPattern)

    private static let conversionCharacters = CharacterSet(charactersIn: "@diouxXeEfFgGaAcspn")

    private enum ParsedFormatSpecifier {
        case positional
        case nonPositional
    }

    /// Unescape catalog `%%` so analysis matches compiled/runtime format strings.
    private static func normalizedForFormatAnalysis(_ string: String) -> String {
        string.replacingOccurrences(of: "%%", with: "%")
    }

    /// Walks printf tokens, skipping `%%` escapes.
    private static func parsedFormatSpecifiers(in string: String) -> [ParsedFormatSpecifier] {
        var specs: [ParsedFormatSpecifier] = []
        var index = string.startIndex

        while index < string.endIndex {
            guard string[index] == "%" else {
                index = string.index(after: index)
                continue
            }

            let afterPercent = string.index(after: index)
            if afterPercent < string.endIndex, string[afterPercent] == "%" {
                index = string.index(after: afterPercent)
                continue
            }

            var cursor = afterPercent
            var isPositional = false

            let digitStart = cursor
            while cursor < string.endIndex, string[cursor].isNumber {
                cursor = string.index(after: cursor)
            }
            if cursor < string.endIndex, string[cursor] == "$", digitStart < cursor {
                isPositional = true
                cursor = string.index(after: cursor)
            }

            while cursor < string.endIndex, string[cursor].isNumber || string[cursor] == "." {
                cursor = string.index(after: cursor)
            }
            while cursor < string.endIndex, "hlLjzt".contains(string[cursor]) {
                cursor = string.index(after: cursor)
            }

            if cursor < string.endIndex,
               let scalar = string[cursor].unicodeScalars.first,
               conversionCharacters.contains(scalar) {
                specs.append(isPositional ? .positional : .nonPositional)
                cursor = string.index(after: cursor)
            }

            index = cursor > afterPercent ? cursor : string.index(after: index)
        }

        return specs
    }

    // MARK: - Trio-style stray %

    static func strayPercentOffenders(
        locale: String,
        key: String,
        value: String,
        source: String
    ) -> [LocalizationPercentOffender] {
        let nsValue = value as NSString
        let range = NSRange(location: 0, length: nsValue.length)

        guard placeholderRegex.firstMatch(in: value, range: range) != nil else {
            return []
        }

        let placeholderMatches = placeholderRegex.matches(in: value, range: range)
        let escapedMatches = escapedPercentRegex.matches(in: value, range: range)
        let coveredRanges = (placeholderMatches + escapedMatches).map(\.range)
        let percentMatches = percentRegex.matches(in: value, range: range)

        for percentMatch in percentMatches {
            let percentLocation = percentMatch.range.location
            let isCovered = coveredRanges.contains { NSLocationInRange(percentLocation, $0) }
            if !isCovered {
                return [LocalizationPercentOffender(locale: locale, key: key, value: value, source: source)]
            }
        }
        return []
    }

    static func strayPercentOffendersInStringsTable(
        locale: String,
        table: [String: String],
        source: String
    ) -> [LocalizationPercentOffender] {
        table.flatMap { key, value in
            strayPercentOffenders(locale: locale, key: key, value: value, source: source)
        }
    }

    static func strayPercentOffendersInBundle(_ bundle: Bundle) -> [LocalizationPercentOffender] {
        strayPercentOffenders(inBundleTables: loadStringsTables(from: bundle))
    }

    // MARK: - Format specifier % count (issue #65: %%1$d in catalog vs %1$d in key)

    private struct FormatToken: Equatable {
        let percentCount: Int
        let spec: String
    }

    private static func formatTokens(in string: String) -> [FormatToken] {
        let ns = string as NSString
        let range = NSRange(location: 0, length: ns.length)
        return formatTokenRegex.matches(in: string, range: range).map { match in
            let full = ns.substring(with: match.range)
            let spec = ns.substring(with: match.range(at: 1))
            let percentCount = full.count - spec.count
            return FormatToken(percentCount: percentCount, spec: spec)
        }
    }

    /// Flags localized values that double-escape a key format specifier (e.g. key `%1$d` stored as `%%1$d`).
    /// Does not flag intentional specifier changes such as `%1$03d` → `%@`.
    static func mismatchedFormatSpecifierOffenders(
        locale: String,
        key: String,
        value: String,
        source: String
    ) -> [LocalizationPercentOffender] {
        let keyTokens = formatTokens(in: key)
        guard !keyTokens.isEmpty else { return [] }

        let valueTokens = formatTokens(in: value)
        for keyToken in keyTokens {
            if valueTokens.contains(where: { $0.spec == keyToken.spec && $0.percentCount > keyToken.percentCount }) {
                return [LocalizationPercentOffender(locale: locale, key: key, value: value, source: source)]
            }
        }
        return []
    }

    static func mismatchedFormatSpecifierOffendersInStringsTable(
        locale: String,
        table: [String: String],
        source: String
    ) -> [LocalizationPercentOffender] {
        table.flatMap { key, value in
            mismatchedFormatSpecifierOffenders(locale: locale, key: key, value: value, source: source)
        }
    }

    static func mismatchedFormatSpecifierOffendersInBundle(_ bundle: Bundle) -> [LocalizationPercentOffender] {
        mismatchedFormatSpecifierOffenders(inBundleTables: loadStringsTables(from: bundle))
    }

    // MARK: - ASCII conversion letters (e.g. Arabic `د` in `%1$03د`)

    static func nonAsciiFormatSpecifierOffenders(
        locale: String,
        key: String,
        value: String,
        source: String
    ) -> [LocalizationPercentOffender] {
        guard nonAsciiFormatSpecifierRegex.firstMatch(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length)
        ) != nil else {
            return []
        }
        return [LocalizationPercentOffender(locale: locale, key: key, value: value, source: source)]
    }

    static func nonAsciiFormatSpecifierOffendersInStringsTable(
        locale: String,
        table: [String: String],
        source: String
    ) -> [LocalizationPercentOffender] {
        table.flatMap { key, value in
            nonAsciiFormatSpecifierOffenders(locale: locale, key: key, value: value, source: source)
        }
    }

    static func nonAsciiFormatSpecifierOffendersInBundle(_ bundle: Bundle) -> [LocalizationPercentOffender] {
        nonAsciiFormatSpecifierOffenders(inBundleTables: loadStringsTables(from: bundle))
    }

    // MARK: - Mixed positional + non-positional (Arabic Previous Pod crash)

    /// `String(format:)` can crash when a format mixes `%1$…` with bare `%@` / `%d` (e.g. key `%3$@` translated as `%@`).
    /// Values are analyzed after collapsing catalog `%%` → `%`.
    static func mixedPositionalFormatOffenders(
        locale: String,
        key: String,
        value: String,
        source: String
    ) -> [LocalizationPercentOffender] {
        let specs = parsedFormatSpecifiers(in: normalizedForFormatAnalysis(value))
        let hasPositional = specs.contains { if case .positional = $0 { return true }; return false }
        let hasNonPositional = specs.contains { if case .nonPositional = $0 { return true }; return false }

        guard hasPositional, hasNonPositional else { return [] }
        return [LocalizationPercentOffender(locale: locale, key: key, value: value, source: source)]
    }

    static func mixedPositionalFormatOffendersInStringsTable(
        locale: String,
        table: [String: String],
        source: String
    ) -> [LocalizationPercentOffender] {
        table.flatMap { key, value in
            mixedPositionalFormatOffenders(locale: locale, key: key, value: value, source: source)
        }
    }

    static func mixedPositionalFormatOffendersInBundle(_ bundle: Bundle) -> [LocalizationPercentOffender] {
        mixedPositionalFormatOffenders(inBundleTables: loadStringsTables(from: bundle))
    }
}
