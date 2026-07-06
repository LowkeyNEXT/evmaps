//
//  VehicleTelemetry.swift
//  KiaMaps
//
//  Shared normalized vehicle telemetry cache for app data sources and the
//  Apple Maps Intents extension.
//

import Foundation

enum VehicleTelemetrySourceKind: String, Codable, CaseIterable, Identifiable {
    case obdLinkCX
    case kiaConnectUSA
    case starPilotGalaxy
    case demo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .obdLinkCX:
            return "OBDLink CX"
        case .kiaConnectUSA:
            return "Kia Connect US"
        case .starPilotGalaxy:
            return "StarPilot Galaxy"
        case .demo:
            return "Demo"
        }
    }

    var freshnessInterval: TimeInterval {
        switch self {
        case .obdLinkCX:
            return 5 * 60
        case .kiaConnectUSA:
            return 60 * 60
        case .starPilotGalaxy:
            return 15 * 60
        case .demo:
            return 24 * 60 * 60
        }
    }
}

enum VehicleTelemetrySelectionMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    case preferredOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "Smart choose"
        case .preferredOnly:
            return "Preferred only"
        }
    }
}

struct VehicleDataSourcePreferences: Codable, Equatable {
    var enabledSources: [VehicleTelemetrySourceKind]
    var selectionMode: VehicleTelemetrySelectionMode
    var preferredSource: VehicleTelemetrySourceKind
    var minimumRefreshIntervalSecondsBySource: [String: TimeInterval]

    static let defaultMinimumRefreshIntervals = Dictionary(
        uniqueKeysWithValues: VehicleTelemetrySourceKind.allCases.map {
            ($0.rawValue, $0.freshnessInterval)
        }
    )

    static let `default` = VehicleDataSourcePreferences(
        enabledSources: [.obdLinkCX, .kiaConnectUSA, .starPilotGalaxy, .demo],
        selectionMode: .automatic,
        preferredSource: .obdLinkCX,
        minimumRefreshIntervalSecondsBySource: Self.defaultMinimumRefreshIntervals
    )

    enum CodingKeys: String, CodingKey {
        case enabledSources
        case selectionMode
        case preferredSource
        case minimumRefreshIntervalSecondsBySource
    }

    init(
        enabledSources: [VehicleTelemetrySourceKind],
        selectionMode: VehicleTelemetrySelectionMode,
        preferredSource: VehicleTelemetrySourceKind,
        minimumRefreshIntervalSecondsBySource: [String: TimeInterval] = Self.defaultMinimumRefreshIntervals
    ) {
        self.enabledSources = enabledSources
        self.selectionMode = selectionMode
        self.preferredSource = preferredSource
        self.minimumRefreshIntervalSecondsBySource = minimumRefreshIntervalSecondsBySource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabledSources = try container.decode([VehicleTelemetrySourceKind].self, forKey: .enabledSources)
        selectionMode = try container.decode(VehicleTelemetrySelectionMode.self, forKey: .selectionMode)
        preferredSource = try container.decode(VehicleTelemetrySourceKind.self, forKey: .preferredSource)
        minimumRefreshIntervalSecondsBySource = try container.decodeIfPresent(
            [String: TimeInterval].self,
            forKey: .minimumRefreshIntervalSecondsBySource
        ) ?? Self.defaultMinimumRefreshIntervals
    }

    func isEnabled(_ source: VehicleTelemetrySourceKind) -> Bool {
        enabledSources.contains(source)
    }

    mutating func setEnabled(_ source: VehicleTelemetrySourceKind, isEnabled: Bool) {
        if isEnabled {
            guard !enabledSources.contains(source) else { return }
            enabledSources.append(source)
        } else {
            enabledSources.removeAll { $0 == source }
        }
    }

    var sourceOrder: [VehicleTelemetrySourceKind] {
        let remaining = enabledSources.filter { $0 != preferredSource }
        if enabledSources.contains(preferredSource) {
            return [preferredSource] + remaining
        }
        return remaining
    }

    func minimumRefreshInterval(for source: VehicleTelemetrySourceKind) -> TimeInterval {
        minimumRefreshIntervalSecondsBySource[source.rawValue] ?? source.freshnessInterval
    }

    mutating func setMinimumRefreshInterval(_ interval: TimeInterval, for source: VehicleTelemetrySourceKind) {
        minimumRefreshIntervalSecondsBySource[source.rawValue] = max(60, interval)
    }
}

struct VehicleTelemetrySnapshot: Codable, Equatable {
    let source: VehicleTelemetrySourceKind
    let updatedAt: Date
    let adapterName: String?
    let vehicleName: String?
    let vin: String?
    let stateOfChargePercent: Double?
    let estimatedRangeKilometers: Double?
    let isCharging: Bool?
    let isPluggedIn: Bool?
    let chargingPowerKilowatts: Double?
    let minutesToFull: Int?
    let maximumBatteryCapacityKilowattHours: Double?
    let activeConnector: String?
    let distanceToEmptyKilometers: Double?
    let plugPowerType: String?
    let chargeLimitPercent: Double?
    let rawValues: [String: String]

    var isFresh: Bool {
        updatedAt.addingTimeInterval(source.freshnessInterval) > Date()
    }

    func isFresh(preferences: VehicleDataSourcePreferences) -> Bool {
        updatedAt.addingTimeInterval(preferences.minimumRefreshInterval(for: source)) > Date()
    }
}

private enum VehicleTelemetryKey: String {
    case preferences = "vehicleTelemetry.preferences"
    case snapshots = "vehicleTelemetry.snapshots"
}

enum VehicleDataSourcePreferencesCache {
    static func load() -> VehicleDataSourcePreferences {
        Keychain<VehicleTelemetryKey>.value(for: .preferences) ?? .default
    }

    static func store(_ preferences: VehicleDataSourcePreferences) {
        Keychain<VehicleTelemetryKey>.store(value: preferences, path: .preferences)
    }
}

enum VehicleTelemetryCache {
    static func store(_ snapshot: VehicleTelemetrySnapshot?) {
        guard let snapshot else { return }
        var snapshots = allLatest()
        snapshots[snapshot.source] = snapshot
        Keychain<VehicleTelemetryKey>.store(value: snapshots, path: .snapshots)
    }

    static func latest(for source: VehicleTelemetrySourceKind) -> VehicleTelemetrySnapshot? {
        allLatest()[source]
    }

    static func allLatest() -> [VehicleTelemetrySourceKind: VehicleTelemetrySnapshot] {
        Keychain<VehicleTelemetryKey>.value(for: .snapshots) ?? [:]
    }

    static func bestAvailable(
        preferences: VehicleDataSourcePreferences = VehicleDataSourcePreferencesCache.load()
    ) -> VehicleTelemetrySnapshot? {
        let snapshots = allLatest()

        switch preferences.selectionMode {
        case .automatic:
            return preferences.sourceOrder
                .compactMap { snapshots[$0] }
                .first { $0.isFresh(preferences: preferences) && $0.hasUsefulMapsData }
        case .preferredOnly:
            guard preferences.isEnabled(preferences.preferredSource),
                  let snapshot = snapshots[preferences.preferredSource],
                  snapshot.isFresh(preferences: preferences),
                  snapshot.hasUsefulMapsData
            else {
                return nil
            }
            return snapshot
        }
    }

    static func bestStored(
        preferences: VehicleDataSourcePreferences = VehicleDataSourcePreferencesCache.load()
    ) -> VehicleTelemetrySnapshot? {
        let snapshots = allLatest()
        switch preferences.selectionMode {
        case .automatic:
            return preferences.sourceOrder
                .compactMap { snapshots[$0] }
                .first { $0.hasUsefulMapsData }
        case .preferredOnly:
            guard preferences.isEnabled(preferences.preferredSource),
                  let snapshot = snapshots[preferences.preferredSource],
                  snapshot.hasUsefulMapsData
            else {
                return nil
            }
            return snapshot
        }
    }

    static func shouldRefresh(
        _ source: VehicleTelemetrySourceKind,
        preferences: VehicleDataSourcePreferences = VehicleDataSourcePreferencesCache.load()
    ) -> Bool {
        guard let snapshot = latest(for: source) else { return true }
        return Date().timeIntervalSince(snapshot.updatedAt) >= preferences.minimumRefreshInterval(for: source)
    }
}

private extension VehicleTelemetrySnapshot {
    var hasUsefulMapsData: Bool {
        stateOfChargePercent != nil || estimatedRangeKilometers != nil
    }
}
