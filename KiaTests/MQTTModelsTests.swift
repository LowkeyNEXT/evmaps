import XCTest
@testable import KiaMaps

final class MQTTModelsTests: XCTestCase {
    func testSubscriptionNameBuildsExpectedTopicPrefix() {
        XCTAssertEqual(MQTTBaseProtocolIds.connection.subscriptionName, "service/phone/_/connection")
        XCTAssertEqual(MQTTBaseProtocolIds.vehicleCcuUpdate.subscriptionName, "statesync/vehicle/_/ccu/update")
    }

    func testTopicNameInitParsesVehicleTopicWithVehicleIdSuffix() {
        let parsed = MQTTBaseProtocolIds(topicName: "statesync/vehicle/_/ccu/update/VIN123")

        XCTAssertEqual(parsed, .vehicleCcuUpdate)
    }

    func testTopicNameInitReturnsNilForUnknownTopic() {
        let parsed = MQTTBaseProtocolIds(topicName: "service/phone/_/missing/VIN123")

        XCTAssertNil(parsed)
    }

    func testProtocolSubscriptionRequestEncodesRawValues() throws {
        let request = ProtocolSubscriptionRequest(
            protocols: [MQTTBaseProtocolIds.connection, MQTTBaseProtocolIds.vss],
            protocolId: MQTTBaseProtocolIds.vehicleCcuUpdate,
            carId: UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!,
            brand: "KIA"
        )

        let encoded = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(json["protocolId"] as? String, "statesync.vehicle.ccu.update")
        XCTAssertEqual(json["brand"] as? String, "KIA")

        let protocols = try XCTUnwrap(json["protocols"] as? [String])
        XCTAssertEqual(protocols, ["service.phone.connection", "service.phone.vss"])
    }
}
