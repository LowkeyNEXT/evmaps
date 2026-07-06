//
//  GalaxyVehicleDataSourceManager.swift
//  KiaMaps
//
//  StarPilot Galaxy portal data source for comma-side vehicle telemetry.
//

import Foundation

extension Notification.Name {
    static let galaxyVehicleCredentialsDidImport = Notification.Name("galaxyVehicleCredentialsDidImport")
}

struct GalaxyVehicleCredentials: Codable, Equatable {
    var baseURLString: String
    var localBaseURLString: String
    var cookieName: String
    var sessionToken: String
    var telemetryPath: String

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

    static let empty = GalaxyVehicleCredentials(
        baseURLString: "",
        cookieName: "galaxy_session",
        sessionToken: "",
        telemetryPath: "/api/vehicle/telemetry"
    )

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

private enum GalaxyVehicleKey: String {
    case credentials = "starPilotGalaxy.credentials"
}

enum GalaxyVehicleCredentialsCache {
    static func load() -> GalaxyVehicleCredentials {
        Keychain<GalaxyVehicleKey>.value(for: .credentials) ?? .empty
    }

    static func store(_ credentials: GalaxyVehicleCredentials) {
        Keychain<GalaxyVehicleKey>.store(value: credentials, path: .credentials)
    }

    static func clear() {
        Keychain<GalaxyVehicleKey>.store(value: Optional<GalaxyVehicleCredentials>.none, path: .credentials)
    }
}

enum GalaxyVehicleDeepLinkHandler {
    static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "kiamaps",
              url.host?.lowercased() == "galaxy",
              url.path == "/connect",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return false
        }

        var query = [String: String]()
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        if let code = query["code"],
           let decoded = decodePairingCode(code) {
            query.merge(decoded) { current, _ in current }
        }

        guard let baseURL = query["baseURL"], !baseURL.isEmpty else {
            return false
        }

        let credentials = GalaxyVehicleCredentials(
            baseURLString: baseURL,
            localBaseURLString: query["localBaseURL"] ?? "",
            cookieName: query["cookieName"]?.isEmpty == false ? query["cookieName"] ?? "galaxy_session" : "galaxy_session",
            sessionToken: query["sessionToken"] ?? "",
            telemetryPath: query["telemetryPath"] ?? "/api/vehicle/telemetry"
        )
        GalaxyVehicleCredentialsCache.store(credentials)
        NotificationCenter.default.post(name: .galaxyVehicleCredentialsDidImport, object: credentials)
        Task { @MainActor in
            await GalaxyVehicleDataSourceManager().refresh()
        }
        return true
    }

    private static func decodePairingCode(_ code: String) -> [String: String]? {
        var padded = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        var decoded = [String: String]()
        for (key, value) in payload {
            decoded[key] = String(describing: value)
        }
        return decoded
    }
}

@MainActor
final class GalaxyVehicleDataSourceManager: ObservableObject {
    @Published var credentials: GalaxyVehicleCredentials
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage = "Not connected"
    @Published private(set) var latestTelemetry = VehicleTelemetryCache.latest(for: .starPilotGalaxy)

    init() {
        credentials = GalaxyVehicleCredentialsCache.load()
    }

    func saveCredentials() {
        GalaxyVehicleCredentialsCache.store(credentials)
    }

    func clearCredentials() {
        credentials = .empty
        GalaxyVehicleCredentialsCache.clear()
        statusMessage = "Galaxy settings removed"
    }

    func discoverAndConnectLocalGalaxy() async {
        isLoading = true
        statusMessage = "Looking for StarPilot Galaxy on your local network"
        defer { isLoading = false }

        do {
            let baseURL = try await GalaxyBonjourDiscovery().discover()
            let statusURL = endpointURL(baseURL: baseURL, path: "/api/galaxy/status")
            let payload = try await fetchJSON(from: statusURL)
            guard let iosConnectUrl = payload["iosConnectUrl"] as? String,
                  let url = URL(string: iosConnectUrl),
                  GalaxyVehicleDeepLinkHandler.handle(url)
            else {
                throw GalaxyVehicleError.invalidResponse
            }

            credentials = GalaxyVehicleCredentialsCache.load()
            statusMessage = "Found StarPilot Galaxy on LAN"
            await refresh()
        } catch {
            statusMessage = "Local Galaxy discovery failed: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        saveCredentials()

        let baseURLs = credentials.orderedBaseURLs
        guard !baseURLs.isEmpty else {
            statusMessage = "Enter your Galaxy portal URL"
            return
        }

        isLoading = true
        statusMessage = "Connecting to StarPilot Galaxy"
        defer { isLoading = false }

        do {
            let (telemetryPayload, sourceURL) = try await fetchFirstAvailableJSON(baseURLs: baseURLs)
            let snapshot = try makeTelemetrySnapshot(from: telemetryPayload, baseURL: sourceURL)
            VehicleTelemetryCache.store(snapshot)
            latestTelemetry = snapshot
            statusMessage = sourceURL == credentials.normalizedLocalBaseURL ? "Galaxy telemetry updated over LAN" : "Galaxy telemetry updated"
        } catch {
            statusMessage = galaxyMessage(for: error)
        }
    }

    private func fetchFirstAvailableJSON(baseURLs: [URL]) async throws -> ([String: Any], URL) {
        var lastError: Error?
        for baseURL in baseURLs {
            do {
                let payload = try await fetchJSON(from: endpointURL(baseURL: baseURL, path: credentials.normalizedTelemetryPath))
                return (payload, baseURL)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? GalaxyVehicleError.invalidResponse
    }

    private func fetchJSON(from url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let token = credentials.normalizedSessionToken
        if !token.isEmpty {
            let cookieName = credentials.cookieName.trimmingCharacters(in: .whitespacesAndNewlines)
            request.setValue("\(cookieName.isEmpty ? "galaxy_session" : cookieName)=\(token)", forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GalaxyVehicleError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GalaxyVehicleError.httpStatus(httpResponse.statusCode)
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GalaxyVehicleError.invalidResponse
        }
        return payload
    }

    private func endpointURL(baseURL: URL, path: String) -> URL {
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

    private func makeTelemetrySnapshot(from payload: [String: Any], baseURL: URL) throws -> VehicleTelemetrySnapshot {
        let telemetryPayload = payload["vehicleTelemetry"] as? [String: Any] ?? payload
        if bool(telemetryPayload, keys: ["available"]) == false,
           let status = string(telemetryPayload, keys: ["status"]),
           status.contains("waiting") {
            throw GalaxyVehicleError.httpStatus(503)
        }

        let socPercent = number(telemetryPayload, keys: ["stateOfChargePercent", "socPercent", "batteryPercent"])
            ?? number(telemetryPayload, keys: ["stateOfCharge", "soc", "fuelGauge"]).map { value in
                value <= 1 ? value * 100 : value
            }
        let rangeKilometers = number(telemetryPayload, keys: ["distanceToEmptyKilometers", "estimatedRangeKilometers", "rangeKilometers", "rangeKm"])
        let chargingPowerKilowatts = number(telemetryPayload, keys: ["chargingPowerKilowatts", "chargePowerKilowatts", "powerKilowatts"])
        let maximumBatteryCapacityKilowattHours = number(telemetryPayload, keys: ["maximumBatteryCapacityKilowattHours", "batteryCapacityKilowattHours"])

        guard socPercent != nil || rangeKilometers != nil else {
            throw GalaxyVehicleError.missingTelemetry
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
            chargingPowerKilowatts: chargingPowerKilowatts,
            minutesToFull: int(telemetryPayload, keys: ["minutesToFull", "minutesUntilFull"]),
            maximumBatteryCapacityKilowattHours: maximumBatteryCapacityKilowattHours,
            activeConnector: string(telemetryPayload, keys: ["activeConnector", "connector"]),
            distanceToEmptyKilometers: number(telemetryPayload, keys: ["distanceToEmptyKilometers", "dteKilometers"]),
            plugPowerType: string(telemetryPayload, keys: ["plugPowerType", "chargePowerType"]),
            chargeLimitPercent: number(telemetryPayload, keys: ["chargeLimitPercent", "targetStateOfChargePercent"]),
            rawValues: [
                "baseURL": baseURL.absoluteString,
                "endpoint": credentials.normalizedTelemetryPath,
            ]
        )
    }

    private func number(_ payload: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = payload[key] as? Double { return value }
            if let value = payload[key] as? Int { return Double(value) }
            if let value = payload[key] as? String, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    private func int(_ payload: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = payload[key] as? Int { return value }
            if let value = payload[key] as? Double { return Int(value.rounded()) }
            if let value = payload[key] as? String, let parsed = Double(value) { return Int(parsed.rounded()) }
        }
        return nil
    }

    private func string(_ payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private func bool(_ payload: [String: Any], keys: [String]) -> Bool? {
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

    private func date(_ payload: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let value = payload[key] as? TimeInterval {
                return Date(timeIntervalSince1970: value)
            }
            if let value = payload[key] as? String {
                if let interval = TimeInterval(value) {
                    return Date(timeIntervalSince1970: interval)
                }
                if let date = ISO8601DateFormatter().date(from: value) {
                    return date
                }
            }
        }
        return nil
    }

    private func galaxyMessage(for error: Error) -> String {
        guard let galaxyError = error as? GalaxyVehicleError else {
            return error.localizedDescription
        }

        switch galaxyError {
        case .httpStatus(401), .httpStatus(403):
            return "Galaxy rejected the session token."
        case .httpStatus(404):
            return "Galaxy is reachable, but this StarPilot build does not expose EV telemetry yet."
        case .httpStatus(503):
            return "Galaxy is connected. Waiting for live CAN vehicle data."
        case .httpStatus(let code):
            return "Galaxy request failed with HTTP \(code)."
        case .invalidResponse:
            return "Galaxy returned an invalid response."
        case .missingTelemetry:
            return "Galaxy responded, but did not include battery or range data."
        }
    }
}

private final class GalaxyBonjourDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var continuation: CheckedContinuation<URL, Error>?
    private var services: [NetService] = []
    private var timeoutTask: Task<Void, Never>?

    func discover(timeout: TimeInterval = 8) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            browser.delegate = self
            browser.searchForServices(ofType: "_sp-galaxy._tcp.", inDomain: "local.")
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run {
                    self?.finish(.failure(GalaxyDiscoveryError.notFound))
                }
            }
        }
    }

    func netServiceBrowser(_: NetServiceBrowser, didFind service: NetService, moreComing _: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName,
              sender.port > 0,
              let url = URL(string: "http://\(host):\(sender.port)")
        else {
            return
        }
        finish(.success(url))
    }

    func netService(_: NetService, didNotResolve _: [String: NSNumber]) {
        if services.allSatisfy({ $0.hostName == nil }) {
            finish(.failure(GalaxyDiscoveryError.notFound))
        }
    }

    func netServiceBrowser(_: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish(.failure(GalaxyDiscoveryError.searchFailed(errorDict.description)))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        browser.stop()
        services.forEach { $0.stop() }
        services.removeAll()

        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private enum GalaxyDiscoveryError: LocalizedError {
    case notFound
    case searchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "No StarPilot Galaxy Bonjour service was found"
        case .searchFailed(let detail):
            return "Bonjour search failed: \(detail)"
        }
    }
}

private enum GalaxyVehicleError: Error {
    case httpStatus(Int)
    case invalidResponse
    case missingTelemetry
}
