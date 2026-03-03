//
//  VehicleMQTTLocationResponseTests.swift
//  KiaTests
//
//  Created by Codex on 03/03/26.
//

import XCTest
@testable import KiaMaps

final class VehicleMQTTLocationResponseTests: XCTestCase {

    func testDecode_ValidMergedTimestampWithNullLocation() throws {
        let data = Data(
            """
            {
              "latestUpdateTime": "20250901142733",
              "state": {
                "Vehicle": {
                  "Location": null
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(VehicleMQTTLocationResponse.self, from: data)
        XCTAssertNil(response.state.vehicle.location)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: response.lastUpdateTime
        )

        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 27)
        XCTAssertEqual(components.second, 33)
    }

    func testDecode_InvalidMergedTimestamp_Throws() {
        let data = Data(
            """
            {
              "latestUpdateTime": "2025-09-01T14:27:33Z",
              "state": {
                "Vehicle": {
                  "Location": null
                }
              }
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(VehicleMQTTLocationResponse.self, from: data))
    }

    func testMergedDateFormatter_RoundTrip() {
        let formatter = MergedDateFormatter()
        let source = "20241231235958"

        let date = formatter.date(from: source)
        XCTAssertNotNil(date)
        XCTAssertEqual(formatter.string(from: date!), source)
    }
}
