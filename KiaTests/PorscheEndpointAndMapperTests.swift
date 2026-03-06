//
//  PorscheEndpointAndMapperTests.swift
//  KiaTests
//
//  Created by Codex on 06.03.2026.
//

import XCTest
@testable import KiaMaps

final class PorscheEndpointAndMapperTests: XCTestCase {
    func testApiBrandPorscheSelectsRegionSpecificConfiguration() {
        let euConfiguration = ApiBrand.porsche.configuration(for: .europe)
        let usConfiguration = ApiBrand.porsche.configuration(for: .usa)
        XCTAssertTrue(euConfiguration is PorscheApiConfiguration)
        XCTAssertTrue(usConfiguration is PorscheApiConfiguration)
    }

    func testPorscheEndpointURLCompositionEU() throws {
        let config = PorscheApiConfiguration.europe
        let lockURL = try config.url(for: .lock("WP0ZZZ99ZTS392124"))
        XCTAssertEqual(lockURL.absoluteString, "https://api.ppa.porsche.com/app/vehicles/WP0ZZZ99ZTS392124/commands/lock")
    }

    func testPorscheEndpointURLCompositionUS() throws {
        let config = PorscheApiConfiguration.usa
        let climateURL = try config.url(for: .climateOn("VIN123"))
        XCTAssertEqual(climateURL.absoluteString, "https://api.ppa.porsche.com/app/vehicles/VIN123/commands/climate/on")
    }

    func testProviderFactoryChoosesPorscheProvider() {
        let api = Api(configuration: PorscheApiConfiguration.europe, rsaService: .init())
        let provider = VehicleApiProviderFactory.provider(for: api)
        XCTAssertTrue(provider is PorscheVehicleApiProvider)
    }

    func testMapperUsesSafeDefaultsWhenCapabilitiesMissing() {
        let summary = PorscheVehicleSummary(
            vin: "VIN",
            displayName: "My Porsche",
            model: "Taycan",
            modelYear: 2024,
            batterySoc: 62.5,
            rangeKm: 280.0,
            charging: nil,
            locked: nil,
            latitude: 50.1,
            longitude: 14.4,
            capabilities: nil
        )

        let snapshot = PorscheVehicleMapper.map(summary: summary)
        XCTAssertEqual(snapshot.vin, "VIN")
        XCTAssertEqual(snapshot.batterySoc, 62.5)
        XCTAssertEqual(snapshot.rangeKm, 280.0)
        XCTAssertFalse(snapshot.charging)
        XCTAssertFalse(snapshot.locked)
        XCTAssertFalse(snapshot.capabilities.canLock)
        XCTAssertFalse(snapshot.capabilities.canClimatise)
        XCTAssertFalse(snapshot.capabilities.canCharge)
    }
}
