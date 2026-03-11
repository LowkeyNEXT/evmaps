//
//  ChargeDoorStatusTests.swift
//  KiaTests
//
//  Created by Codex on 11/3/26.
//

import XCTest
@testable import KiaMaps

final class ChargeDoorStatusTests: XCTestCase {
    func testDecodeUnknownChargeDoorStatus() throws {
        let decoded = try JSONDecoder().decode(ChargeDoorStatus.self, from: Data("0".utf8))
        XCTAssertEqual(decoded, .unknown)
    }

    func testChargeDoorStatusRoundTripCodable() throws {
        for status in [ChargeDoorStatus.unknown, .open, .closed] {
            let encoded = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(ChargeDoorStatus.self, from: encoded)
            XCTAssertEqual(decoded, status)
        }
    }
}
