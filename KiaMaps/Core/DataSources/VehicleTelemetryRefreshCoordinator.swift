//
//  VehicleTelemetryRefreshCoordinator.swift
//  KiaMaps
//
//  Extension-safe refresh path for Apple Maps intent requests.
//

import Foundation

enum VehicleTelemetryRefreshCoordinator {
    static func bestAvailableOrRefresh(reason: String) async -> VehicleTelemetrySnapshot? {
        let preferences = VehicleDataSourcePreferencesCache.load()

        if let telemetry = VehicleTelemetryCache.bestAvailable(preferences: preferences) {
            MapsIntentDebugLog.append(event: "Telemetry cache hit", detail: "\(reason): \(summary(telemetry))")
            return telemetry
        }

        if let refreshed = await refreshAllowedSource(preferences: preferences, reason: reason) {
            return refreshed
        }

        if let stored = VehicleTelemetryCache.bestStored(preferences: preferences) {
            MapsIntentDebugLog.append(event: "Telemetry stale fallback", detail: "\(reason): \(summary(stored))")
            return stored
        }

        MapsIntentDebugLog.append(event: "Telemetry unavailable", detail: "\(reason): no cached source")
        return nil
    }

    private static func refreshAllowedSource(
        preferences: VehicleDataSourcePreferences,
        reason: String
    ) async -> VehicleTelemetrySnapshot? {
        for source in preferences.sourceOrder {
            guard preferences.isEnabled(source) else { continue }

            guard VehicleTelemetryCache.shouldRefresh(source, preferences: preferences) else {
                MapsIntentDebugLog.append(event: "Telemetry refresh throttled", detail: "\(reason): \(source.displayName)")
                continue
            }

            switch source {
            case .starPilotGalaxy:
                do {
                    let telemetry = try await SharedGalaxyTelemetryClient.refreshStoredTelemetry()
                    MapsIntentDebugLog.append(event: "Telemetry refreshed", detail: "\(reason): \(summary(telemetry))")
                    return telemetry
                } catch {
                    MapsIntentDebugLog.append(event: "Galaxy refresh failed", detail: "\(reason): \(error.localizedDescription)")
                }
            case .obdLinkCX:
                MapsIntentDebugLog.append(event: "Telemetry refresh skipped", detail: "\(reason): OBDLink CX requires an active app Bluetooth session")
            case .kiaConnectUSA:
                MapsIntentDebugLog.append(event: "Telemetry refresh skipped", detail: "\(reason): Kia Connect US refresh is app-managed to avoid background OEM polling/MFA prompts")
            case .demo:
                MapsIntentDebugLog.append(event: "Telemetry refresh skipped", detail: "\(reason): Demo has no live refresh")
            }
        }

        return nil
    }

    private static func summary(_ telemetry: VehicleTelemetrySnapshot) -> String {
        let soc = telemetry.stateOfChargePercent.map { "\($0.formatted(.number.precision(.fractionLength(1))))%" } ?? "nil"
        let range = telemetry.estimatedRangeKilometers.map { "\($0.formatted(.number.precision(.fractionLength(1)))) km" } ?? "nil"
        let dte = telemetry.distanceToEmptyKilometers.map { "\($0.formatted(.number.precision(.fractionLength(1)))) km" } ?? "nil"
        let charging = telemetry.isCharging.map(String.init) ?? "nil"
        let plugged = telemetry.isPluggedIn.map(String.init) ?? "nil"
        let power = telemetry.chargingPowerKilowatts.map { "\($0.formatted(.number.precision(.fractionLength(1)))) kW" } ?? "nil"
        let connector = telemetry.activeConnector ?? "nil"
        let plug = telemetry.plugPowerType ?? "nil"
        let limit = telemetry.chargeLimitPercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "nil"
        return "source=\(telemetry.source.displayName), updated=\(telemetry.updatedAt), soc=\(soc), range=\(range), dte=\(dte), charging=\(charging), plugged=\(plugged), power=\(power), connector=\(connector), plugPowerType=\(plug), chargeLimit=\(limit)"
    }
}
