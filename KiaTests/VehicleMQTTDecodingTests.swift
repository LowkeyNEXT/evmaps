import XCTest
@testable import KiaMaps

final class VehicleMQTTDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testVehicleMQTTLocationResponseDecodesLatestUpdateTimeInUTC() throws {
        let payload: [String: Any] = [
            "latestUpdateTime": "20250814123045",
            "state": [
                "Vehicle": [
                    "Location": NSNull()
                ]
            ]
        ]

        let response: VehicleMQTTLocationResponse = try decode(VehicleMQTTLocationResponse.self, from: payload)

        let utc = TimeZone(secondsFromGMT: 0)
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: utc!, from: response.lastUpdateTime)

        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 14)
        XCTAssertEqual(components.hour, 12)
        XCTAssertEqual(components.minute, 30)
        XCTAssertEqual(components.second, 45)
        XCTAssertNil(response.state.vehicle.location)
    }

    func testVehicleMQTTStatusResponseDecodesFromVehicleStatePayload() throws {
        let vehicleState = MockVehicleData.standard
        let vehicleJSON = try jsonDictionary(from: vehicleState)

        let payload: [String: Any] = [
            "latestUpdateTime": "20250814133112",
            "state": [
                "Vehicle": vehicleJSON
            ]
        ]

        let response: VehicleMQTTStatusResponse = try decode(VehicleMQTTStatusResponse.self, from: payload)

        XCTAssertEqual(response.state.vehicle.green.batteryManagement.batteryRemain.ratio, vehicleState.green.batteryManagement.batteryRemain.ratio)
        XCTAssertEqual(response.state.vehicle.drivingReady, vehicleState.drivingReady)
    }

    func testVehicleMQTTLocationResponseInvalidMergedTimestampThrows() throws {
        let payload: [String: Any] = [
            "latestUpdateTime": "2025-08-14T12:30:45Z",
            "state": [
                "Vehicle": [
                    "Location": NSNull()
                ]
            ]
        ]

        XCTAssertThrowsError(try decode(VehicleMQTTLocationResponse.self, from: payload))
    }

    func testMergedDateFormatterRoundTripUsesExpectedFormat() {
        let formatter = MergedDateFormatter()
        let expectedString = "20250814112233"

        let date = formatter.date(from: expectedString)

        XCTAssertNotNil(date)
        XCTAssertEqual(formatter.string(from: date!), expectedString)
    }

    private func decode<T: Decodable>(_ type: T.Type, from payload: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try decoder.decode(type, from: data)
    }

    private func jsonDictionary<T: Encodable>(from value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)

        guard let dictionary = object as? [String: Any] else {
            XCTFail("Expected encoded value to be a dictionary")
            return [:]
        }

        return dictionary
    }
}
