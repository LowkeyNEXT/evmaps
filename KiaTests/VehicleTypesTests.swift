//
//  VehicleTypesTests.swift
//  KiaTests
//
//  Created by Codex on 12.03.2026.
//

import XCTest
@testable import KiaMaps

final class VehicleTypesTests: XCTestCase {
    private struct ChargeDoorStatusContainer: Codable {
        let status: ChargeDoorStatus
    }

    func testChargeDoorStatusRawValuesIncludeUnknown() {
        XCTAssertEqual(ChargeDoorStatus(rawValue: 0), .unknown)
        XCTAssertEqual(ChargeDoorStatus(rawValue: 1), .open)
        XCTAssertEqual(ChargeDoorStatus(rawValue: 2), .closed)
        XCTAssertNil(ChargeDoorStatus(rawValue: 3))
    }

    func testChargeDoorStatusDecodesUnknownFromZero() throws {
        let payload = #"{"status":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChargeDoorStatusContainer.self, from: payload)

        XCTAssertEqual(decoded.status, .unknown)
    }

    func testChargeDoorStatusEncodesUnknownAsZero() throws {
        let encoded = try JSONEncoder().encode(ChargeDoorStatusContainer(status: .unknown))
        let decoded = try JSONDecoder().decode(ChargeDoorStatusContainer.self, from: encoded)

        XCTAssertEqual(decoded.status, .unknown)
    }
}
