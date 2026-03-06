//
//  PorscheEndpointAndMapperTests.swift
//  KiaTests
//
//  Created by Codex on 06.03.2026.
//

import XCTest
@testable import KiaMaps

private final class PorscheProviderTransportStub {
    struct StubResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data

        init(statusCode: Int, headers: [String: String] = [:], json: Any? = nil) {
            self.statusCode = statusCode
            self.headers = headers
            if let json {
                self.body = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            } else {
                self.body = Data()
            }
        }
    }

    private(set) var requests: [URLRequest] = []
    private var responses: [StubResponse]

    init(responses: [StubResponse]) {
        self.responses = responses
    }

    func transport(_ request: URLRequest) async throws -> PorscheHTTPTransportResponse {
        requests.append(request)
        let response = responses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: response.headers
        )!
        return PorscheHTTPTransportResponse(data: response.body, response: httpResponse)
    }
}

final class PorscheEndpointAndMapperTests: XCTestCase {
    func testApiBrandPorscheSelectsRegionSpecificConfiguration() {
        let euConfiguration = ApiBrand.porsche.configuration(for: .europe)
        let usConfiguration = ApiBrand.porsche.configuration(for: .usa)
        XCTAssertTrue(euConfiguration is PorscheApiConfiguration)
        XCTAssertTrue(usConfiguration is PorscheApiConfiguration)
    }

    func testPorscheEndpointURLCompositionEU() throws {
        let config = PorscheApiConfiguration.europe
        let vehicleURL = try config.url(for: .vehicle("WP0ZZZ99ZTS392124"))
        XCTAssertEqual(vehicleURL.absoluteString, "https://api.ppa.porsche.com/app/connect/v1/vehicles/WP0ZZZ99ZTS392124")
    }

    func testPorscheEndpointURLCompositionUS() throws {
        let config = PorscheApiConfiguration.usa
        let commandsURL = try config.url(for: .commands("VIN123"))
        XCTAssertEqual(commandsURL.absoluteString, "https://api.ppa.porsche.com/app/connect/v1/vehicles/VIN123/commands")
    }

    func testProviderFactoryChoosesPorscheProvider() {
        let api = Api(configuration: PorscheApiConfiguration.europe, rsaService: .init())
        let provider = VehicleApiProviderFactory.provider(for: api)
        XCTAssertTrue(provider is PorscheVehicleApiProvider)
    }

    func testMapperUsesMeasurementPayloadAndSafeDefaults() throws {
        let payload: [String: Any] = [
            "vin": "VIN",
            "modelName": "Taycan",
            "modelType": [
                "year": "2024",
                "engine": "BEV",
                "model": "4S",
            ],
            "customName": "My Porsche",
            "measurements": [
                [
                    "key": "BATTERY_LEVEL",
                    "status": ["isEnabled": true],
                    "value": ["percent": 62.5],
                ],
                [
                    "key": "GPS_LOCATION",
                    "status": ["isEnabled": true],
                    "value": [
                        "location": "50.1,14.4",
                        "direction": 90,
                        "lastModified": "2026-03-06T16:00:00Z",
                    ],
                ],
                [
                    "key": "LOCK_STATE_VEHICLE",
                    "status": ["isEnabled": true],
                    "value": ["isLocked": true],
                ],
                [
                    "key": "MILEAGE",
                    "status": ["isEnabled": true],
                    "value": ["kilometers": 15432],
                ],
                [
                    "key": "CLIMATIZER_STATE",
                    "status": ["isEnabled": true],
                    "value": ["isOn": true, "targetTemperature": 294.15],
                ],
                [
                    "key": "CHARGING_RATE",
                    "status": ["isEnabled": true],
                    "value": ["chargingPower": 11000],
                ],
            ],
        ]

        let summary = PorscheVehicleMapper.mapSummary(from: payload)
        let snapshot = PorscheVehicleMapper.map(summary: summary)
        let state = try PorscheVehicleMapper.mapVehicleState(from: payload)

        XCTAssertEqual(snapshot.batterySoc, 62.5)
        XCTAssertEqual(snapshot.latitude, 50.1)
        XCTAssertEqual(snapshot.longitude, 14.4)
        XCTAssertEqual(snapshot.odometerKm, 15_432)
        XCTAssertTrue(snapshot.locked)
        XCTAssertTrue(snapshot.climateActive)
        XCTAssertEqual(snapshot.chargingPowerKw, 11)
        XCTAssertEqual(state.state.vehicle.green.batteryManagement.batteryRemain.ratio, 62.5)
        XCTAssertEqual(state.state.vehicle.drivetrain.odometer, 15_432)
        XCTAssertEqual(state.state.vehicle.location?.geoCoordinate.latitude, 50.1)
        XCTAssertEqual(state.state.vehicle.location?.geoCoordinate.longitude, 14.4)
        XCTAssertEqual(state.state.vehicle.cabin.hvac.row1.driver.blower.speedLevel, 1)
    }

    func testCommandBodyUsesRemoteClimatizerStartPayload() throws {
        let data = PorscheVehicleMapper.commandBody(for: .climateOn(vin: "VIN", temperatureC: 22))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["key"] as? String, "REMOTE_CLIMATIZER_START")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        let targetTemperature = try XCTUnwrap(payload["targetTemperature"] as? Double)
        XCTAssertEqual(targetTemperature, 295.15, accuracy: 0.001)
    }

    func testProviderRefreshesTokenAfterUnauthorizedVehiclesCall() async throws {
        let vehiclePayload: [[String: Any]] = [[
            "vin": "WP0AA2Y1XNSA00001",
            "modelName": "Taycan",
            "modelType": [
                "year": "2025",
                "engine": "BEV",
                "model": "Turbo",
            ],
            "customName": "Turbo",
        ]]

        let stub = PorscheProviderTransportStub(responses: [
            .init(statusCode: 401),
            .init(statusCode: 200, json: [
                "access_token": "fresh-access",
                "refresh_token": "fresh-refresh",
                "token_type": "Bearer",
                "expires_in": 3600,
                "scope": "openid cars",
            ]),
            .init(statusCode: 200, json: vehiclePayload),
        ])

        let api = Api(configuration: PorscheApiConfiguration.europe, rsaService: .init())
        api.authorization = AuthorizationData(
            stamp: "porsche",
            deviceId: UUID(),
            accessToken: "expired",
            expiresIn: 3600,
            refreshToken: "refresh-token",
            isCcuCCS2Supported: true,
            providerKind: "porsche",
            tokenIssuer: PorscheApiConfiguration.europe.loginHost,
            tokenAudience: PorscheApiConfiguration.europe.audience,
            tokenScope: PorscheApiConfiguration.europe.scope
        )
        let provider = PorscheVehicleApiProvider(api: api, transport: stub.transport, commandPollIntervalNanoseconds: 0)

        let response = try await provider.vehicles()

        XCTAssertEqual(response.vehicles.count, 1)
        XCTAssertEqual(api.authorization?.accessToken, "fresh-access")
        XCTAssertEqual(stub.requests[1].url?.path, "/oauth/token")
    }

    func testProviderStartClimateUsesCommandsEndpoint() async throws {
        let vehicleID = UUID.porscheVehicleID(for: "WP0AA2Y1XNSA00001")
        let stub = PorscheProviderTransportStub(responses: [
            .init(statusCode: 200, json: [[
                "vin": "WP0AA2Y1XNSA00001",
                "modelName": "Taycan",
                "modelType": [
                    "year": "2025",
                    "engine": "BEV",
                    "model": "4S",
                ],
            ]]),
            .init(statusCode: 200, json: [
                "status": [
                    "id": "4FD78B24-3C94-4EC2-8BE4-7D53FA3B84B6",
                    "result": "ACCEPTED",
                ],
            ]),
            .init(statusCode: 200, json: [
                "status": [
                    "result": "PERFORMED",
                ],
            ]),
        ])

        let api = Api(configuration: PorscheApiConfiguration.europe, rsaService: .init())
        api.authorization = AuthorizationData(
            stamp: "porsche",
            deviceId: UUID(),
            accessToken: "access",
            expiresIn: 3600,
            refreshToken: "refresh",
            isCcuCCS2Supported: true,
            providerKind: "porsche"
        )
        let provider = PorscheVehicleApiProvider(api: api, transport: stub.transport, commandPollIntervalNanoseconds: 0)

        let commandID = try await provider.startClimate(vehicleID, options: .init(temperature: 21), pin: "")

        XCTAssertEqual(commandID.uuidString, "4FD78B24-3C94-4EC2-8BE4-7D53FA3B84B6")
        XCTAssertEqual(stub.requests[1].url?.path, "/app/connect/v1/vehicles/WP0AA2Y1XNSA00001/commands")
        let body = try XCTUnwrap(stub.requests[1].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["key"] as? String, "REMOTE_CLIMATIZER_START")
    }
}
