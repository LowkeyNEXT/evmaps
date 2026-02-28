import XCTest
@testable import KiaMaps

final class DatePropertyWrapperTests: XCTestCase {
    private struct TimestampPayload: Codable {
        @DateValue<TimeIntervalDateFormatter> var timestamp: Date
    }

    private struct MillisecondPayload: Codable {
        @DateValue<MillisecondDateFormatter> var eventTime: Date
    }

    private struct MergedPayload: Codable {
        @DateValue<MergedDateFormatter> var latestUpdateTime: Date
    }

    func testTimeIntervalDateValueDecodesMillisecondsString() throws {
        let data = Data("{\"timestamp\":\"1716728779116\"}".utf8)

        let payload = try JSONDecoder().decode(TimestampPayload.self, from: data)

        XCTAssertEqual(payload.timestamp.timeIntervalSince1970, 1_716_728_779.116, accuracy: 0.0001)
    }

    func testMillisecondDateValueDecodesExpectedUTCFormat() throws {
        let data = Data("{\"eventTime\":\"2024-05-16 11:52:59.116\"}".utf8)

        let payload = try JSONDecoder().decode(MillisecondPayload.self, from: data)

        XCTAssertEqual(payload.eventTime.timeIntervalSince1970, 1_715_860_379.116, accuracy: 0.0001)
    }

    func testMergedDateValueDecodesCompactUTCFormat() throws {
        let data = Data("{\"latestUpdateTime\":\"20250812153045\"}".utf8)

        let payload = try JSONDecoder().decode(MergedPayload.self, from: data)

        XCTAssertEqual(payload.latestUpdateTime.timeIntervalSince1970, 1_755_012_645, accuracy: 0.0001)
    }

    func testDateValueEncodeOutputsString() throws {
        let date = Date(timeIntervalSince1970: 1_716_728_779.116)
        let payload = TimestampPayload(timestamp: date)

        let encoded = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])

        XCTAssertEqual(object["timestamp"], "1716728779116.0")
    }

    func testInvalidDateStringThrowsParsingError() {
        let data = Data("{\"latestUpdateTime\":\"not-a-date\"}".utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(MergedPayload.self, from: data)) { error in
            guard case DateValue<MergedDateFormatter>.ParsingError.invalidString(let value, _) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(value, "not-a-date")
        }
    }
}
