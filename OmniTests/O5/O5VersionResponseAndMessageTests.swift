//
//  O5VersionResponseAndMessageTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

final class O5VersionResponseAndMessageTests: XCTestCase {

    func testAssignAddress_fullMessageWrapper() throws {
        throw XCTSkip("AssignAddress VersionResponse inner body is tested; full Message wrapper encode/decode is not.")
    }

    func testSetupPod_fullMessageWrapper() throws {
        throw XCTSkip("SetupPod VersionResponse inner body is tested; full Message wrapper encode/decode is not.")
    }

    func testMessageTests_versionResponse_o5ProductId() throws {
        throw XCTSkip("MessageTests uses Eros/DASH VersionResponse hex; O5 productId and progress fields are covered in O5VersionResponseTests.")
    }
}
