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

enum LocalizationPercentValidator {

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
        var offenders: [LocalizationPercentOffender] = []
        for locale in bundle.localizations where locale != "Base" {
            guard let lproj = bundle.path(forResource: locale, ofType: "lproj"),
                  let files = FileManager.default.enumerator(atPath: lproj) else { continue }

            for case let file as String in files where file.hasSuffix(".strings") {
                let path = (lproj as NSString).appendingPathComponent(file)
                guard let table = NSDictionary(contentsOfFile: path) as? [String: String] else { continue }
                offenders += strayPercentOffendersInStringsTable(
                    locale: locale,
                    table: table,
                    source: file
                )
            }
        }
        return offenders
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
        var offenders: [LocalizationPercentOffender] = []
        for locale in bundle.localizations where locale != "Base" {
            guard let lproj = bundle.path(forResource: locale, ofType: "lproj"),
                  let files = FileManager.default.enumerator(atPath: lproj) else { continue }

            for case let file as String in files where file.hasSuffix(".strings") {
                let path = (lproj as NSString).appendingPathComponent(file)
                guard let table = NSDictionary(contentsOfFile: path) as? [String: String] else { continue }
                offenders += mismatchedFormatSpecifierOffendersInStringsTable(
                    locale: locale,
                    table: table,
                    source: file
                )
            }
        }
        return offenders
    }
}
