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

    private var catalogURL: URL {
        LocalizationCatalogLoader.localizableXcstringsURL()
    }

    private lazy var catalogKeyLineNumbers: [String: Int] = {
        (try? LocalizationCatalogLoader.loadKeyLineNumbers(from: catalogURL)) ?? [:]
    }()

    // MARK: - Localizable.xcstrings (source catalog)

    func testNoStrayPercent_inLocalizableXcstrings() throws {
        let entries = try LocalizationCatalogLoader.loadEntries(from: catalogURL)
        var offenders: [LocalizationPercentOffender] = []

        for entry in entries {
            offenders += LocalizationPercentValidator.strayPercentOffenders(
                locale: entry.locale,
                key: entry.key,
                value: entry.value,
                source: "Localizable.xcstrings"
            )
        }

        XCTAssertTrue(
            offenders.isEmpty,
            formattedMessage(
                title: "string(s) with a single % although the value contains printf placeholders",
                offenders: offenders
            )
        )
    }

    func testFormatSpecifiers_useAsciiConversionLetters_inLocalizableXcstrings() throws {
        let entries = try LocalizationCatalogLoader.loadEntries(from: catalogURL)
        var offenders: [LocalizationPercentOffender] = []

        for entry in entries {
            offenders += LocalizationPercentValidator.nonAsciiFormatSpecifierOffenders(
                locale: entry.locale,
                key: entry.key,
                value: entry.value,
                source: "Localizable.xcstrings"
            )
        }

        XCTAssertTrue(
            offenders.isEmpty,
            formattedMessage(
                title: "string(s) with non-ASCII characters in a printf format specifier (conversion letters must be ASCII, e.g. use %1$03d not %1$03د)",
                offenders: offenders
            )
        )
    }

    func testFormatStrings_doNotMixPositionalAndNonPositional_inLocalizableXcstrings() throws {
        let entries = try LocalizationCatalogLoader.loadEntries(from: catalogURL)
        var offenders: [LocalizationPercentOffender] = []

        for entry in entries where entry.locale != "key" {
            offenders += LocalizationPercentValidator.mixedPositionalFormatOffenders(
                locale: entry.locale,
                key: entry.key,
                value: entry.value,
                source: "Localizable.xcstrings"
            )
        }

        XCTAssertTrue(
            offenders.isEmpty,
            formattedMessage(
                title: "localized value(s) mixing positional (`%1$@`) and non-positional (`%@`) specifiers in one format string (can crash `String(format:)`; e.g. use `%3$@` not `%@` after `%2$@`)",
                offenders: offenders
            )
        )
    }

    func testFormatSpecifierPercentCount_matchesKey_inLocalizableXcstrings() throws {
        let entries = try LocalizationCatalogLoader.loadEntries(from: catalogURL)
        var offenders: [LocalizationPercentOffender] = []

        for entry in entries {
            offenders += LocalizationPercentValidator.mismatchedFormatSpecifierOffenders(
                locale: entry.locale,
                key: entry.key,
                value: entry.value,
                source: "Localizable.xcstrings"
            )
        }

        XCTAssertTrue(
            offenders.isEmpty,
            formattedMessage(
                title: "localized value(s) with extra `%` before a format specifier from the source key (e.g. key %1$d vs value %%1$d; see OmnipodKit#65)",
                offenders: offenders,
                listAll: false
            )
        )
    }

    // MARK: - Compiled OmnipodKit bundle (runtime tables)

    func testNoStrayPercent_inOmnipodKitBundle() {
        let offenders = LocalizationPercentValidator.strayPercentOffendersInBundle(Bundle(for: OmniPumpManager.self))
        XCTAssertTrue(
            offenders.isEmpty,
            formattedMessage(
                title: "compiled .strings with stray %",
                offenders: offenders
            )
        )
    }

    func testFormatSpecifiers_useAsciiConversionLetters_inOmnipodKitBundle() {
        let offenders = LocalizationPercentValidator.nonAsciiFormatSpecifierOffendersInBundle(
            Bundle(for: OmniPumpManager.self)
        )
        XCTAssertTrue(
            offenders.isEmpty,
            formattedMessage(
                title: "compiled .strings with non-ASCII characters in a printf format specifier",
                offenders: offenders
            )
        )
    }

    func testFormatStrings_doNotMixPositionalAndNonPositional_inOmnipodKitBundle() {
        let offenders = LocalizationPercentValidator.mixedPositionalFormatOffendersInBundle(
            Bundle(for: OmniPumpManager.self)
        )
        XCTAssertTrue(
            offenders.isEmpty,
            formattedMessage(
                title: "compiled .strings mixing positional and non-positional format specifiers",
                offenders: offenders
            )
        )
    }

    func testFormatSpecifierPercentCount_matchesKey_inOmnipodKitBundle() {
        let offenders = LocalizationPercentValidator.mismatchedFormatSpecifierOffendersInBundle(Bundle(for: OmniPumpManager.self))
        XCTAssertTrue(
            offenders.isEmpty,
            formattedMessage(
                title: "compiled .strings with extra `%` before a format specifier from the key",
                offenders: offenders,
                listAll: false
            )
        )
    }

    // MARK: - Full location report (fails with every issue + file:line)

    func testLocalizationIssueLocationsReport_inLocalizableXcstrings() throws {
        let entries = try LocalizationCatalogLoader.loadEntries(from: catalogURL)
        var sections: [String] = []

        func collect(
            _ name: String,
            _ offenders: [LocalizationPercentOffender]
        ) {
            guard !offenders.isEmpty else { return }
            sections.append(
                formattedMessage(title: name, offenders: offenders, listAll: offenders.count <= 50)
            )
        }

        collect("double-escaped format specifier (%% vs key %)", entries.flatMap { entry in
            LocalizationPercentValidator.mismatchedFormatSpecifierOffenders(
                locale: entry.locale,
                key: entry.key,
                value: entry.value,
                source: "Localizable.xcstrings"
            )
        })

        collect("non-ASCII conversion letter in format specifier", entries.flatMap { entry in
            LocalizationPercentValidator.nonAsciiFormatSpecifierOffenders(
                locale: entry.locale,
                key: entry.key,
                value: entry.value,
                source: "Localizable.xcstrings"
            )
        })

        collect("mixed positional + non-positional specifiers", entries.flatMap { entry in
            guard entry.locale != "key" else { return [] as [LocalizationPercentOffender] }
            return LocalizationPercentValidator.mixedPositionalFormatOffenders(
                locale: entry.locale,
                key: entry.key,
                value: entry.value,
                source: "Localizable.xcstrings"
            )
        })

        collect("stray % in format string", entries.flatMap { entry in
            LocalizationPercentValidator.strayPercentOffenders(
                locale: entry.locale,
                key: entry.key,
                value: entry.value,
                source: "Localizable.xcstrings"
            )
        })

        guard !sections.isEmpty else { return }

        XCTFail(
            """
            Localization/Localizable.xcstrings issue locations (\(sections.count) rule group(s)):

            \(sections.joined(separator: "\n\n---\n\n"))
            """
        )
    }

    // MARK: - Reporting

    private static let catalogPath = "OmnipodKit/Localization/Localizable.xcstrings"

    /// One line per issue in the test console (Xcode test log / `xcodebuild` stdout).
    private func logOffendersToConsole(
        _ offenders: [LocalizationPercentOffender],
        rule: String
    ) {
        guard !offenders.isEmpty else { return }
        print("\n--- Localization: \(rule) (\(offenders.count)) ---")
        for offender in offenders {
            let line = catalogKeyLineNumbers[offender.key].map(String.init) ?? "?"
            let key = offender.key
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
            print("\(Self.catalogPath):\(line)\tlocale=\(offender.locale)\tkey=\(key)")
        }
        print("--- end \(rule) ---\n")
    }

    private func formattedMessage(
        title: String,
        offenders: [LocalizationPercentOffender],
        listAll: Bool = true
    ) -> String {
        logOffendersToConsole(offenders, rule: title)

        let listed = listAll ? offenders : Array(offenders.prefix(25))
        let lines = listed.enumerated().map { index, offender in
            let line = catalogKeyLineNumbers[offender.key].map { String($0) } ?? "?"
            let key = offender.key
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "[\(index + 1)/\(offenders.count)] \(Self.catalogPath):\(line)  locale=\(offender.locale)  key=\(key)"
        }

        var message = "Found \(offenders.count) \(title) (see test console for full list):\n\n\(lines.joined(separator: "\n"))"
        if !listAll, offenders.count > 25 {
            message += "\n\n…and \(offenders.count - 25) more in test console."
        }
        return message
    }
}
