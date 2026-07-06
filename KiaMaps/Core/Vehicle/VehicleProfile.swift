//
//  VehicleProfile.swift
//  KiaMaps
//
//  Shared Apple Maps vehicle configuration for the app and Intents extension.
//

import Foundation
import Intents
import Security

enum VehicleChargingConnector: String, Codable, CaseIterable, Identifiable {
    case nacsAC
    case nacsDC
    case j1772
    case ccs1
    case ccs2
    case mennekes
    case chaDeMo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nacsAC:
            return "NACS AC"
        case .nacsDC:
            return "NACS DC"
        case .j1772:
            return "J1772"
        case .ccs1:
            return "CCS1"
        case .ccs2:
            return "CCS2"
        case .mennekes:
            return "Type 2"
        case .chaDeMo:
            return "CHAdeMO"
        }
    }

    var intentType: INCar.ChargingConnectorType? {
        switch self {
        case .nacsAC:
            if #available(iOS 17.4, *) {
                return .nacsAC
            }
            return nil
        case .nacsDC:
            if #available(iOS 17.4, *) {
                return .nacsDC
            }
            return nil
        case .j1772:
            return .j1772
        case .ccs1:
            return .ccs1
        case .ccs2:
            return .ccs2
        case .mennekes:
            return .mennekes
        case .chaDeMo:
            return .chaDeMo
        }
    }
}

struct VehicleChargingConnectorConfiguration: Codable, Equatable, Identifiable {
    var connector: VehicleChargingConnector
    var maximumPowerKilowatts: Double

    var id: VehicleChargingConnector { connector }
}

struct VehicleProfile: Codable, Equatable, Identifiable, VehicleParameters {
    var id: String
    var displayName: String
    var year: String
    var make: String
    var model: String
    var trim: String
    var region: String
    var maximumDistanceKilometers: Double
    var maximumBatteryCapacityKilowattHours: Double
    var consumptionModelId: Int
    var chargingModelId: Int
    var auxiliaryPowerWatts: Double
    var consumptionValuesWattHoursPerMeter: [Double]
    var altitudeGainConsumptionWattHoursPerMeter: Double
    var altitudeLossConsumptionWattHoursPerMeter: Double
    var chargingEfficiencyFactor: Double
    var connectors: [VehicleChargingConnectorConfiguration]

    var supportedChargingConnectors: [INCar.ChargingConnectorType] {
        connectors.compactMap(\.connector.intentType)
    }

    func maximumPower(for connector: INCar.ChargingConnectorType) -> Double? {
        connectors.first { $0.connector.intentType == connector }?.maximumPowerKilowatts
    }

    var maximumDistance: Double {
        maximumDistanceKilometers
    }

    var consumptionFormulaParameters: [String: Any] {
        [
            "vehicle_auxiliary_power_w": auxiliaryPowerWatts,
            "vehicle_consumption_values_wh_per_m": consumptionValuesWattHoursPerMeter,
            "vehicle_altitude_gain_consumption_wh_per_m": altitudeGainConsumptionWattHoursPerMeter,
            "vehicle_altitude_loss_consumption_wh_per_m": altitudeLossConsumptionWattHoursPerMeter,
        ]
    }

    func chargingFormulaParameters(maximumBatteryCapacity: Double, unit: UnitEnergy) -> [String: Any] {
        let capacityKilowattHours = Measurement(value: maximumBatteryCapacity, unit: unit).converted(to: .kilowattHours).value
        let capacityWattHours = max(1, Int((capacityKilowattHours * 1000).rounded()))
        let energyAxis = [0, 2, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100]
            .map { capacityWattHours * $0 / 100 }
        let peakDCPower = connectors
            .filter { [.nacsDC, .ccs1, .ccs2].contains($0.connector) }
            .map(\.maximumPowerKilowatts)
            .max() ?? 150
        let peak = Int((peakDCPower * 1000).rounded())
        let chargeAxis = [
            50_000,
            min(150_000, peak),
            min(180_000, peak),
            min(195_000, peak),
            min(205_000, peak),
            peak,
            peak,
            peak,
            Int(Double(peak) * 0.98),
            Int(Double(peak) * 0.95),
            Int(Double(peak) * 0.90),
            Int(Double(peak) * 0.85),
            Int(Double(peak) * 0.80),
            Int(Double(peak) * 0.74),
            Int(Double(peak) * 0.68),
            Int(Double(peak) * 0.58),
            Int(Double(peak) * 0.43),
            Int(Double(peak) * 0.33),
            Int(Double(peak) * 0.24),
            Int(Double(peak) * 0.16),
            Int(Double(peak) * 0.10),
            15_000,
        ]
        let displayAxis = (0 ... 20).map { capacityWattHours * $0 / 20 }

        return [
            "vehicle_energy_axis_wh": energyAxis,
            "vehicle_charge_axis_w": chargeAxis,
            "energy_w_per_h": displayAxis,
            "efficiency_factor": chargingEfficiencyFactor,
        ]
    }

    static let ev9GTLineUSA2026 = VehicleProfile(
        id: "kia-ev9-gt-line-awd-usa-2026",
        displayName: "Kia EV9 GT-Line AWD",
        year: "2026",
        make: "Kia",
        model: "EV9",
        trim: "GT-Line AWD",
        region: "USA",
        maximumDistanceKilometers: 450.6,
        maximumBatteryCapacityKilowattHours: 99.8,
        consumptionModelId: 12_582_912,
        chargingModelId: 12_582_916,
        auxiliaryPowerWatts: 670,
        consumptionValuesWattHoursPerMeter: [
            0.232,
            0.205,
            0.210,
            0.220,
            0.225,
            0.235,
            0.238,
            0.260,
            0.277,
            0.300,
        ],
        altitudeGainConsumptionWattHoursPerMeter: 8.346,
        altitudeLossConsumptionWattHoursPerMeter: 6.973,
        chargingEfficiencyFactor: 0.9,
        connectors: [
            .init(connector: .nacsAC, maximumPowerKilowatts: 10.9),
            .init(connector: .nacsDC, maximumPowerKilowatts: 210),
            .init(connector: .j1772, maximumPowerKilowatts: 10.9),
            .init(connector: .ccs1, maximumPowerKilowatts: 210),
        ]
    )

    static let porscheTaycanDemo = VehicleProfile(
        id: "porsche-taycan-demo",
        displayName: "Porsche Taycan Demo",
        year: "2024",
        make: "Porsche",
        model: "Taycan",
        trim: "Demo",
        region: "EU",
        maximumDistanceKilometers: 541,
        maximumBatteryCapacityKilowattHours: 90.25,
        consumptionModelId: 12_582_912,
        chargingModelId: 12_582_916,
        auxiliaryPowerWatts: 670,
        consumptionValuesWattHoursPerMeter: [
            0.2254000186920166,
            0.18230000734329224,
            0.19320000410079957,
            0.21390001773834227,
            0.1721000075340271,
            0.1721000075340271,
            0.18310000896453857,
            0.2052000045776367,
            0.2266000032424927,
            0.25840001106262206,
        ],
        altitudeGainConsumptionWattHoursPerMeter: 8.345999908447265,
        altitudeLossConsumptionWattHoursPerMeter: 6.972999572753906,
        chargingEfficiencyFactor: 0.9,
        connectors: [
            .init(connector: .mennekes, maximumPowerKilowatts: 11),
            .init(connector: .ccs2, maximumPowerKilowatts: 234),
        ]
    )

    static let presets: [VehicleProfile] = [
        .ev9GTLineUSA2026,
        .porscheTaycanDemo,
    ]
}

private enum VehicleProfileKey: String {
    case selected = "vehicleProfile.selected"
}

enum VehicleProfileStore {
    static func selected() -> VehicleProfile {
        VehicleProfileKeychain.value(for: VehicleProfileKey.selected.rawValue) ?? .ev9GTLineUSA2026
    }

    static func store(_ profile: VehicleProfile) {
        VehicleProfileKeychain.store(profile, key: VehicleProfileKey.selected.rawValue)
    }
}

private enum VehicleProfileKeychain {
    private static let accessGroupId = "EEDU4Y93YR.com.riddlenext.vehicle.shared"
    private static let legacyAccessGroupIds = ["EEDU4Y93YR.com.porsche.one.shared"]
    private static var accessGroupIds: [String] {
        [accessGroupId] + legacyAccessGroupIds
    }

    static func value(for key: String) -> VehicleProfile? {
        for accessGroupId in accessGroupIds {
            if let profile = value(for: key, accessGroupId: accessGroupId) {
                if accessGroupId != Self.accessGroupId {
                    store(profile, key: key)
                }
                return profile
            }
        }
        return nil
    }

    private static func value(for key: String, accessGroupId: String) -> VehicleProfile? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key,
            kSecAttrAccount as String: "local",
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecAttrAccessGroup as String: accessGroupId,
        ]

        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }
        return try? JSONDecoder().decode(VehicleProfile.self, from: data)
    }

    static func store(_ profile: VehicleProfile, key: String) {
        guard let data = try? JSONEncoder().encode(profile) else {
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key,
            kSecAttrAccount as String: "local",
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessGroup as String: accessGroupId,
        ]
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
