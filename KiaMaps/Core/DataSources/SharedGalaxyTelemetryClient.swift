//
//  SharedGalaxyTelemetryClient.swift
//  KiaMaps
//
//  Minimal StarPilot Galaxy client usable from both the app and the Maps intent extension.
//

import Foundation

struct SharedGalaxyVehicleCredentials: Codable, Equatable {
    var baseURLString: String
    var localBaseURLString: String
    var cookieName: String
    var sessionToken: String
    var telemetryPath: String

    static let empty = SharedGalaxyVehicleCredentials(
        baseURLString: "",
        localBaseURLString: "",
        cookieName: "galaxy_session",
        sessionToken: "",
        telemetryPath: "/api/vehicle/telemetry"
    )

    init(
        baseURLString: String,
        localBaseURLString: String = "",
        cookieName: String,
        sessionToken: String,
        telemetryPath: String = "/api/vehicle/telemetry"
    ) {
        self.baseURLString = baseURLString
        self.localBaseURLString = localBaseURLString
        self.cookieName = cookieName
        self.sessionToken = sessionToken
        self.telemetryPath = telemetryPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURLString = try container.decode(String.self, forKey: .baseURLString)
        localBaseURLString = try container.decodeIfPresent(String.self, forKey: .localBaseURLString) ?? ""
        cookieName = try container.decode(String.self, forKey: .cookieName)
        sessionToken = try container.decode(String.self, forKey: .sessionToken)
        telemetryPath = try container.decodeIfPresent(String.self, forKey: .telemetryPath) ?? "/api/vehicle/telemetry"
    }

    var normalizedLocalBaseURL: URL? {
        normalizedURL(from: localBaseURLString)
    }

    var normalizedBaseURL: URL? {
        normalizedURL(from: baseURLString)
    }

    var orderedBaseURLs: [URL] {
        [normalizedLocalBaseURL, normalizedBaseURL]
            .compactMap { $0 }
            .reduce(into: [URL]()) { result, url in
                if !result.contains(url) {
                    result.append(url)
                }
            }
    }

    private func normalizedURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            return URL(string: trimmed)
        }
        return URL(string: "https://\(trimmed)")
    }

    var normalizedSessionToken: String {
        let trimmed = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String
        if let cookieValue = trimmed.split(separator: "=", maxSplits: 1).last,
           trimmed.contains("=") {
            token = String(cookieValue)
        } else {
            token = trimmed
        }

        guard token.contains(":") else { return token }
        return token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
    }

    var normalizedTelemetryPath: String {
        let trimmed = telemetryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/api/vehicle/telemetry" : trimmed
    }

    var isConfigured: Bool {
        !orderedBaseURLs.isEmpty && !normalizedSessionToken.isEmpty
    }
}

private enum SharedGalaxyVehicleKey: String {
    case credentials = "starPilotGalaxy.credentials"
}

enum SharedGalaxyVehicleCredentialsCache {
    static func load() -> SharedGalaxyVehicleCredentials {
        Keychain<SharedGalaxyVehicleKey>.value(for: .credentials) ?? .empty
    }
}

enum SharedGalaxyTelemetryClient {
    static func refreshStoredTelemetry() async throws -> VehicleTelemetrySnapshot {
        let credentials = SharedGalaxyVehicleCredentialsCache.load()
        let baseURLs = credentials.orderedBaseURLs
        guard !baseURLs.isEmpty else {
            throw SharedGalaxyTelemetryError.notConfigured
        }

        var lastError: Error?
        for baseURL in baseURLs {
            do {
                return try await refreshStoredTelemetry(credentials: credentials, baseURL: baseURL)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? SharedGalaxyTelemetryError.invalidResponse
    }

    private static func refreshStoredTelemetry(
        credentials: SharedGalaxyVehicleCredentials,
        baseURL: URL
    ) async throws -> VehicleTelemetrySnapshot {
        let url = endpointURL(baseURL: baseURL, path: credentials.normalizedTelemetryPath)
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let cookieName = credentials.cookieName.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = credentials.normalizedSessionToken
        if !token.isEmpty {
            request.setValue("\(cookieName.isEmpty ? "galaxy_session" : cookieName)=\(token)", forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SharedGalaxyTelemetryError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SharedGalaxyTelemetryError.httpStatus(httpResponse.statusCode)
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SharedGalaxyTelemetryError.invalidResponse
        }

        let snapshot = try makeTelemetrySnapshot(from: payload, baseURL: baseURL, endpoint: credentials.normalizedTelemetryPath)
        VehicleTelemetryCache.store(snapshot)
        return snapshot
    }

    private static func endpointURL(baseURL: URL, path: String) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.isEmpty || (components.host == "galaxy.firestar.link" && endpointPath.hasPrefix("api/")) {
            components.path = "/\(endpointPath)"
        } else {
            components.path = "/\(basePath)/\(endpointPath)"
        }

        return components.url ?? baseURL.appendingPathComponent(path)
    }

    private static func makeTelemetrySnapshot(from payload: [String: Any], baseURL: URL, endpoint: String) throws -> VehicleTelemetrySnapshot {
        let telemetryPayload = payload["vehicleTelemetry"] as? [String: Any] ?? payload
        if bool(telemetryPayload, keys: ["available"]) == false,
           let status = string(telemetryPayload, keys: ["status"]),
           status.contains("waiting") {
            throw SharedGalaxyTelemetryError.httpStatus(503)
        }

        let socPercent = number(telemetryPayload, keys: ["stateOfChargePercent", "socPercent", "batteryPercent"])
            ?? number(telemetryPayload, keys: ["stateOfCharge", "soc", "fuelGauge"]).map { value in
                value <= 1 ? value * 100 : value
            }
        let rangeKilometers = number(telemetryPayload, keys: ["distanceToEmptyKilometers", "estimatedRangeKilometers", "rangeKilometers", "rangeKm"])
        guard socPercent != nil || rangeKilometers != nil else {
            throw SharedGalaxyTelemetryError.missingTelemetry
        }

        return VehicleTelemetrySnapshot(
            source: .starPilotGalaxy,
            updatedAt: date(telemetryPayload, keys: ["updatedAt", "timestamp"]) ?? Date(),
            adapterName: "StarPilot Galaxy",
            vehicleName: string(telemetryPayload, keys: ["vehicleName", "model"]) ?? "EV9",
            vin: string(telemetryPayload, keys: ["vin"]),
            stateOfChargePercent: socPercent,
            estimatedRangeKilometers: rangeKilometers,
            isCharging: bool(telemetryPayload, keys: ["isCharging", "charging"]),
            isPluggedIn: bool(telemetryPayload, keys: ["isPluggedIn", "pluggedIn"]),
            chargingPowerKilowatts: number(telemetryPayload, keys: ["chargingPowerKilowatts", "chargePowerKilowatts", "powerKilowatts"]),
            minutesToFull: int(telemetryPayload, keys: ["minutesToFull", "minutesUntilFull"]),
            maximumBatteryCapacityKilowattHours: number(telemetryPayload, keys: ["maximumBatteryCapacityKilowattHours", "batteryCapacityKilowattHours"]),
            activeConnector: string(telemetryPayload, keys: ["activeConnector", "connector"]),
            distanceToEmptyKilometers: number(telemetryPayload, keys: ["distanceToEmptyKilometers", "dteKilometers"]),
            plugPowerType: string(telemetryPayload, keys: ["plugPowerType", "chargePowerType"]),
            chargeLimitPercent: number(telemetryPayload, keys: ["chargeLimitPercent", "targetStateOfChargePercent"]),
            rawValues: [
                "baseURL": baseURL.absoluteString,
                "endpoint": endpoint,
            ]
        )
    }

    private static func number(_ payload: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = payload[key] as? Double { return value }
            if let value = payload[key] as? Int { return Double(value) }
            if let value = payload[key] as? String, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    private static func int(_ payload: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = payload[key] as? Int { return value }
            if let value = payload[key] as? Double { return Int(value.rounded()) }
            if let value = payload[key] as? String, let parsed = Double(value) { return Int(parsed.rounded()) }
        }
        return nil
    }

    private static func string(_ payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func bool(_ payload: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = payload[key] as? Bool { return value }
            if let value = payload[key] as? String {
                switch value.lowercased() {
                case "true", "yes", "1":
                    return true
                case "false", "no", "0":
                    return false
                default:
                    break
                }
            }
        }
        return nil
    }

    private static func date(_ payload: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let value = payload[key] as? TimeInterval {
                return Date(timeIntervalSince1970: value)
            }
            if let value = payload[key] as? String,
               let parsed = TimeInterval(value) {
                return Date(timeIntervalSince1970: parsed)
            }
        }
        return nil
    }
}

enum SharedGalaxyTelemetryError: LocalizedError {
    case notConfigured
    case invalidResponse
    case httpStatus(Int)
    case missingTelemetry

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Galaxy is not configured"
        case .invalidResponse:
            return "Galaxy returned an invalid response"
        case .httpStatus(let status):
            return "Galaxy returned HTTP \(status)"
        case .missingTelemetry:
            return "Galaxy did not return battery or range telemetry"
        }
    }
}
