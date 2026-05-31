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
                offenders: offenders
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

    func testFormatSpecifierPercentCount_matchesKey_inOmnipodKitBundle() {
        let offenders = LocalizationPercentValidator.mismatchedFormatSpecifierOffendersInBundle(Bundle(for: OmniPumpManager.self))
        XCTAssertTrue(
            offenders.isEmpty,
            formattedMessage(
                title: "compiled .strings with extra `%` before a format specifier from the key",
                offenders: offenders
            )
        )
    }

    // MARK: - Reporting

    private func formattedMessage(
        title: String,
        offenders: [LocalizationPercentOffender]
    ) -> String {
        let lines = offenders.prefix(25).map { offender in
            """
            \(offender.locale) – \(offender.source)
            ⟨key⟩   \(offender.key)
            ⟨value⟩ \(offender.value)
            """
        }
        var message = "Found \(offenders.count) \(title):\n\n\(lines.joined(separator: "\n\n"))"
        if offenders.count > 25 {
            message += "\n\n…and \(offenders.count - 25) more."
        }
        return message
    }
}
