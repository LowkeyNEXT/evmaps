//
//  KiaConnectUSACredentials.swift
//  KiaMaps
//
//  Keychain-backed Kia Connect US credentials and session metadata.
//

import Foundation

struct KiaConnectUSAAuthSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    var isValid: Bool {
        Date() < expiresAt.addingTimeInterval(-300)
    }
}

struct KiaConnectUSACredentials: Codable, Equatable {
    var username: String
    var password: String
    var rememberMeToken: String?
    var deviceId: String?
    var accountId: UUID
    var selectedVIN: String?
    var authSession: KiaConnectUSAAuthSession?

    static let empty = KiaConnectUSACredentials(
        username: "",
        password: "",
        rememberMeToken: nil,
        deviceId: nil,
        accountId: UUID(),
        selectedVIN: nil,
        authSession: nil
    )

    var isReadyForLogin: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !password.isEmpty
    }

    var canAuthenticate: Bool {
        isReadyForLogin || authSession?.isValid == true
    }

    var hasStoredSession: Bool {
        authSession?.isValid == true || rememberMeToken != nil || deviceId != nil
    }

    var hasStoredCredentials: Bool {
        isReadyForLogin || hasStoredSession
    }

    var redactedUsername: String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No saved account" }
        guard let atIndex = trimmed.firstIndex(of: "@") else {
            return trimmed.count <= 3 ? trimmed : "\(trimmed.prefix(3))..."
        }

        let local = trimmed[..<atIndex]
        let domain = trimmed[atIndex...]
        let visible = local.prefix(min(3, local.count))
        return "\(visible)...\(domain)"
    }
}

private enum KiaConnectUSAKey: String {
    case credentials = "kiaConnectUSA.credentials"
    case session = "shared.kiaConnect.session"
    case statusCache = "shared.kiaConnect.statusCache"
}

struct SharedKiaConnectVehicleStatusCache: Codable, Equatable {
    var sourceApp: String
    var updatedAt: Date
    var vehicleName: String?
    var vin: String?
    var stateOfChargePercent: Double?
    var estimatedRangeKilometers: Double?
    var isCharging: Bool?
    var isPluggedIn: Bool?
    var chargingPowerKilowatts: Double?
    var minutesToFull: Int?
    var distanceToEmptyKilometers: Double?
    var plugPowerType: String?
    var chargeLimitPercent: Double?

    var telemetrySnapshot: VehicleTelemetrySnapshot {
        VehicleTelemetrySnapshot(
            source: .kiaConnectUSA,
            updatedAt: updatedAt,
            adapterName: sourceApp,
            vehicleName: vehicleName,
            vin: vin,
            stateOfChargePercent: stateOfChargePercent,
            estimatedRangeKilometers: estimatedRangeKilometers,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            chargingPowerKilowatts: chargingPowerKilowatts,
            minutesToFull: minutesToFull,
            maximumBatteryCapacityKilowattHours: nil,
            activeConnector: nil,
            distanceToEmptyKilometers: distanceToEmptyKilometers ?? estimatedRangeKilometers,
            plugPowerType: plugPowerType,
            chargeLimitPercent: chargeLimitPercent,
            rawValues: [
                "sourceApp": sourceApp,
                "sharedCache": "true",
            ]
        )
    }
}

enum KiaConnectUSACredentialsCache {
    static func load() -> KiaConnectUSACredentials {
        if let credentials: KiaConnectUSACredentials = Keychain<KiaConnectUSAKey>.value(for: .credentials) {
            return credentials
        }

        if let credentials: KiaConnectUSACredentials = Keychain<KiaConnectUSAKey>.value(for: .session) {
            store(credentials)
            return credentials
        }

        return .empty
    }

    static func store(_ credentials: KiaConnectUSACredentials) {
        Keychain<KiaConnectUSAKey>.store(value: credentials, path: .credentials)
        Keychain<KiaConnectUSAKey>.store(value: credentials, path: .session)
    }

    static func loadStatusCache() -> SharedKiaConnectVehicleStatusCache? {
        Keychain<KiaConnectUSAKey>.value(for: .statusCache)
    }

    @discardableResult
    static func importStatusCache() -> VehicleTelemetrySnapshot? {
        guard let snapshot = loadStatusCache()?.telemetrySnapshot else {
            return nil
        }
        VehicleTelemetryCache.store(snapshot)
        return snapshot
    }

    static func clear() {
        Keychain<KiaConnectUSAKey>.store(value: Optional<KiaConnectUSACredentials>.none, path: .credentials)
        Keychain<KiaConnectUSAKey>.store(value: Optional<KiaConnectUSACredentials>.none, path: .session)
    }
}
