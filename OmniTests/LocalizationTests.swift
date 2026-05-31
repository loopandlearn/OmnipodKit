//
//  LocalizationTests.swift
//  OmniTests
//
//  Catches printf format issues in OmnipodKit string catalogs (see loopandlearn/OmnipodKit#65).
//  Stray-% check adapted from Trio LocalizationTests.swift:
//  https://github.com/nightscout/Trio/blob/main/TrioTests/LocalizationTests.swift
//

import XCTest
@testable import OmnipodKit

class LocalizationTests: XCTestCase {

    private static var catalog: LocalizationCatalogLoader.Snapshot!
    private static var xcstringsValidation: XcstringsValidationResult!
    private static var bundleTables: [BundleStringsTable]!

    private var lineNumberCache: [String: Int] = [:]

    /// e.g. `LoopWorkspace/OmnipodKit/Localization/Localizable.xcstrings`
    private static var catalogDisplayPath: String!

    override class func setUp() {
        super.setUp()
        do {
            catalog = try LocalizationCatalogLoader.Snapshot.load(
                from: LocalizationCatalogLoader.localizableXcstringsURL()
            )
            catalogDisplayPath = displayPath(relativeToLoopWorkspace: catalog.url)
            xcstringsValidation = LocalizationPercentValidator.validateXcstrings(
                entries: catalog.entries
            )
            bundleTables = LocalizationPercentValidator.loadStringsTables(
                from: Bundle(for: OmniPumpManager.self)
            )
        } catch {
            XCTFail("LocalizationTests setup failed: \(error)")
        }
    }

    private static func displayPath(relativeToLoopWorkspace url: URL) -> String {
        let path = url.path
        if let range = path.range(of: "/LoopWorkspace/") {
            return "LoopWorkspace/" + path[range.upperBound...]
        }
        return "OmnipodKit/Localization/\(url.lastPathComponent)"
    }

    // MARK: - Localizable.xcstrings (source catalog)

    func testNoStrayPercent_inLocalizableXcstrings() {
        assertXcstringsEmpty(
            Self.xcstringsValidation.stray,
            title: "string(s) with a single % although the value contains printf placeholders"
        )
    }

    func testFormatSpecifiers_useAsciiConversionLetters_inLocalizableXcstrings() {
        assertXcstringsEmpty(
            Self.xcstringsValidation.nonAscii,
            title: "string(s) with non-ASCII characters in a printf format specifier (conversion letters must be ASCII, e.g. use %1$03d not %1$03د)"
        )
    }

    func testFormatStrings_doNotMixPositionalAndNonPositional_inLocalizableXcstrings() {
        assertXcstringsEmpty(
            Self.xcstringsValidation.mixedPositional,
            title: "localized value(s) mixing positional (`%1$@`) and non-positional (`%@`) specifiers in one format string (can crash `String(format:)`; e.g. use `%3$@` not `%@` after `%2$@`)"
        )
    }

    func testFormatSpecifierPercentCount_matchesKey_inLocalizableXcstrings() {
        assertXcstringsEmpty(
            Self.xcstringsValidation.mismatched,
            title: "localized value(s) with extra `%` before a format specifier from the source key (e.g. key %1$d vs value %%1$d; see OmnipodKit#65)",
            listAll: false
        )
    }

    // MARK: - Compiled OmnipodKit bundle (runtime tables)

    func testNoStrayPercent_inOmnipodKitBundle() {
        let offenders = LocalizationPercentValidator.strayPercentOffenders(
            inBundleTables: Self.bundleTables
        )
        assertBundleEmpty(offenders, title: "compiled .strings with stray %")
    }

    func testFormatSpecifiers_useAsciiConversionLetters_inOmnipodKitBundle() {
        let offenders = LocalizationPercentValidator.nonAsciiFormatSpecifierOffenders(
            inBundleTables: Self.bundleTables
        )
        assertBundleEmpty(
            offenders,
            title: "compiled .strings with non-ASCII characters in a printf format specifier"
        )
    }

    func testFormatStrings_doNotMixPositionalAndNonPositional_inOmnipodKitBundle() {
        let offenders = LocalizationPercentValidator.mixedPositionalFormatOffenders(
            inBundleTables: Self.bundleTables
        )
        assertBundleEmpty(
            offenders,
            title: "compiled .strings mixing positional and non-positional format specifiers"
        )
    }

    func testFormatSpecifierPercentCount_matchesKey_inOmnipodKitBundle() {
        let offenders = LocalizationPercentValidator.mismatchedFormatSpecifierOffenders(
            inBundleTables: Self.bundleTables
        )
        assertBundleEmpty(
            offenders,
            title: "compiled .strings with extra `%` before a format specifier from the key",
            listAll: false
        )
    }

    // MARK: - Assertions

    private func assertXcstringsEmpty(
        _ offenders: [LocalizationPercentOffender],
        title: String,
        listAll: Bool = true
    ) {
        XCTAssertTrue(
            offenders.isEmpty,
            formattedMessage(title: title, offenders: offenders, listAll: listAll, useCatalogLines: true)
        )
    }

    private func assertBundleEmpty(
        _ offenders: [LocalizationPercentOffender],
        title: String,
        listAll: Bool = true
    ) {
        XCTAssertTrue(
            offenders.isEmpty,
            formattedMessage(title: title, offenders: offenders, listAll: listAll, useCatalogLines: true)
        )
    }

    // MARK: - Reporting

    private func formattedMessage(
        title: String,
        offenders: [LocalizationPercentOffender],
        listAll: Bool,
        useCatalogLines: Bool
    ) -> String {
        logOffendersToConsole(offenders, rule: title, useCatalogLines: useCatalogLines)

        let listed = listAll ? offenders : Array(offenders.prefix(25))
        let lines = listed.enumerated().map { index, offender in
            let line = lineNumber(for: offender.key, useCatalogLines: useCatalogLines) ?? "?"
            let key = escapedKeyForDisplay(offender.key)
            return "[\(index + 1)/\(offenders.count)] \(Self.catalogDisplayPath):\(line)  locale=\(offender.locale)  key=\(key)"
        }

        var message = "Found \(offenders.count) \(title) (location errors below):\n\n\(lines.joined(separator: "\n"))"
        if !listAll, offenders.count > 25 {
            message += "\n\n…and \(offenders.count - 25) more location errors below."
        }
        return message
    }

    private func logOffendersToConsole(
        _ offenders: [LocalizationPercentOffender],
        rule: String,
        useCatalogLines: Bool
    ) {
        guard !offenders.isEmpty else { return }
        print("\n--- Localization: \(rule) (\(offenders.count)) ---")
        for offender in offenders {
            let line = lineNumber(for: offender.key, useCatalogLines: useCatalogLines) ?? "?"
            let key = escapedKeyForDisplay(offender.key)
            print("\(Self.catalogDisplayPath):\(line)\tlocale=\(offender.locale)\tkey=\(key)")
        }
        print("--- end \(rule) ---\n")
    }

    private func lineNumber(for key: String, useCatalogLines: Bool) -> Int? {
        guard useCatalogLines else { return nil }
        return Self.catalog.lineNumber(for: key, lineCache: &lineNumberCache)
    }

    private func escapedKeyForDisplay(_ key: String) -> String {
        key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
