//
//  KiaConnectUSAManager.swift
//  KiaMaps
//
//  App-side Kia Connect US integration through BetterBlueKit.
//

import Foundation

#if canImport(BetterBlueKit)
import BetterBlueKit
#endif

struct KiaConnectUSAVehicleSummary: Identifiable, Equatable {
    let id: String
    let vin: String
    let model: String
}

struct KiaConnectUSAMFAChallenge: Equatable {
    let xid: String
    let otpKey: String
    let hasEmail: Bool
    let hasPhone: Bool
    let email: String?
    let phone: String?
}

enum KiaConnectUSACommand: String, CaseIterable, Identifiable {
    case lock
    case unlock
    case startClimate
    case stopClimate
    case startCharge
    case stopCharge
    case setChargeLimit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lock:
            return "Lock"
        case .unlock:
            return "Unlock"
        case .startClimate:
            return "Start Climate"
        case .stopClimate:
            return "Stop Climate"
        case .startCharge:
            return "Start Charge"
        case .stopCharge:
            return "Stop Charge"
        case .setChargeLimit:
            return "Set Charge Limit"
        }
    }

    var systemImage: String {
        switch self {
        case .lock:
            return "lock.fill"
        case .unlock:
            return "lock.open.fill"
        case .startClimate:
            return "fan.fill"
        case .stopClimate:
            return "fan.slash.fill"
        case .startCharge:
            return "bolt.fill"
        case .stopCharge:
            return "bolt.slash.fill"
        case .setChargeLimit:
            return "battery.100percent"
        }
    }
}

@MainActor
final class KiaConnectUSAManager: ObservableObject {
    @Published var credentials: KiaConnectUSACredentials
    @Published private(set) var isLoading = false
    @Published private(set) var runningCommand: KiaConnectUSACommand?
    @Published private(set) var statusMessage = "Not connected"
    @Published private(set) var commandStatusMessage = "No command sent"
    @Published private(set) var vehicles: [KiaConnectUSAVehicleSummary] = []
    @Published private(set) var latestTelemetry = VehicleTelemetryCache.latest(for: .kiaConnectUSA)
    @Published private(set) var mfaChallenge: KiaConnectUSAMFAChallenge?
    #if canImport(BetterBlueKit)
    private var mfaClient: (any APIClientProtocol)?
    #endif

    init() {
        credentials = KiaConnectUSACredentialsCache.load()
        if importSharedStatusCache() {
            statusMessage = "Loaded shared Kia Connect vehicle status"
        } else {
            statusMessage = credentials.hasStoredSession ? "Shared Kia Connect account available" : "Not connected"
        }
    }

    func saveCredentials() {
        KiaConnectUSACredentialsCache.store(credentials)
    }

    func reloadSharedCredentials() {
        credentials = KiaConnectUSACredentialsCache.load()
        let didLoadSharedStatus = importSharedStatusCache()
        if credentials.hasStoredCredentials && didLoadSharedStatus {
            statusMessage = "Loaded shared Kia Connect account and vehicle status"
        } else if credentials.hasStoredCredentials {
            statusMessage = "Loaded shared Kia Connect credentials"
        } else if didLoadSharedStatus {
            statusMessage = "Loaded shared Kia Connect vehicle status"
        } else {
            statusMessage = "No shared Kia Connect credentials found"
        }
    }

    func clearCredentials() {
        credentials = .empty
        KiaConnectUSACredentialsCache.clear()
        vehicles = []
        latestTelemetry = nil
        mfaChallenge = nil
        #if canImport(BetterBlueKit)
        mfaClient = nil
        #endif
        statusMessage = "Credentials removed"
        commandStatusMessage = "No command sent"
    }

    func refresh(cached: Bool = true) async {
        saveCredentials()

        _ = importSharedStatusCache()

        guard credentials.canAuthenticate else {
            statusMessage = "Sign in with Kia Connect here or refresh shared credentials from Galaxy Nav"
            return
        }

        isLoading = true
        statusMessage = "Signing in to Kia Connect US"
        defer { isLoading = false }

        #if canImport(BetterBlueKit)
        do {
            let (client, authToken) = try await makeAuthenticatedClient(status: { statusMessage = $0 })
            try await fetchAndCacheVehicleStatus(client: client, authToken: authToken, cached: cached)
            mfaChallenge = nil
            mfaClient = nil
        } catch let apiError as APIError where apiError.errorType == .requiresMFA {
            mfaChallenge = makeChallenge(from: apiError)
            statusMessage = "Kia Connect requires verification"
            await notifyReauthNeeded(for: apiError)
            await sendOnlyAvailableMFAMethodIfNeeded()
        } catch {
            statusMessage = userFacingMessage(for: error)
            await notifyReauthNeededIfNeeded(for: error)
        }
        #else
        statusMessage = "BetterBlueKit is not linked in this build"
        #endif
    }

    func sendMFACode(method: String) async {
        guard let challenge = mfaChallenge else { return }

        isLoading = true
        statusMessage = "Sending verification code"
        defer { isLoading = false }

        #if canImport(BetterBlueKit)
        do {
            let client = try mfaClient ?? makeClient()
            try await client.sendMFACode(
                xid: challenge.xid,
                otpKey: challenge.otpKey,
                method: method == "sms" ? .sms : .email
            )
            statusMessage = "Verification code sent"
        } catch {
            statusMessage = userFacingMessage(for: error)
        }
        #else
        statusMessage = "BetterBlueKit is not linked in this build"
        #endif
    }

    func verifyMFACode(_ code: String) async {
        guard let challenge = mfaChallenge else { return }
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            statusMessage = "Enter the verification code"
            return
        }

        isLoading = true
        statusMessage = "Verifying code"
        defer { isLoading = false }

        #if canImport(BetterBlueKit)
        do {
            let client = try mfaClient ?? makeClient()
            let mfaTokens = try await client.verifyMFACode(
                xid: challenge.xid,
                otpKey: challenge.otpKey,
                code: trimmedCode
            )
            credentials.rememberMeToken = mfaTokens.rememberMeToken
            saveCredentials()
            let authToken = try await client.completeMFALogin(
                sid: mfaTokens.sid,
                rmToken: mfaTokens.rememberMeToken
            )
            storeAuthToken(authToken)
            try await fetchAndCacheVehicleStatus(client: client, authToken: authToken, cached: true)
            mfaChallenge = nil
            mfaClient = nil
        } catch {
            statusMessage = userFacingMessage(for: error)
        }
        #else
        statusMessage = "BetterBlueKit is not linked in this build"
        #endif
    }

    private func sendOnlyAvailableMFAMethodIfNeeded() async {
        guard let challenge = mfaChallenge else { return }
        if challenge.hasPhone && !challenge.hasEmail {
            await sendMFACode(method: "sms")
        } else if challenge.hasEmail && !challenge.hasPhone {
            await sendMFACode(method: "email")
        }
    }

    func perform(
        _ command: KiaConnectUSACommand,
        climateTemperatureFahrenheit: Double = 72,
        climateDurationMinutes: Int = 10,
        acChargeLimitPercent: Int = 90,
        dcChargeLimitPercent: Int = 90
    ) async {
        saveCredentials()

        guard credentials.canAuthenticate else {
            commandStatusMessage = "Enter Kia Connect credentials first"
            return
        }

        isLoading = true
        runningCommand = command
        commandStatusMessage = "\(command.displayName) requested"
        defer {
            isLoading = false
            runningCommand = nil
        }

        #if canImport(BetterBlueKit)
        do {
            let (client, authToken) = try await makeAuthenticatedClient(status: { commandStatusMessage = $0 })
            commandStatusMessage = "Finding selected vehicle"
            let fetchedVehicles = try await client.fetchVehicles(authToken: authToken)
            vehicles = fetchedVehicles.map {
                KiaConnectUSAVehicleSummary(id: $0.vin, vin: $0.vin, model: $0.model)
            }

            guard let vehicle = selectedVehicle(from: fetchedVehicles) else {
                commandStatusMessage = "No Kia Connect vehicles found"
                return
            }

            credentials.selectedVIN = vehicle.vin
            saveCredentials()

            let vehicleCommand = makeVehicleCommand(
                command,
                climateTemperatureFahrenheit: climateTemperatureFahrenheit,
                climateDurationMinutes: climateDurationMinutes,
                acChargeLimitPercent: acChargeLimitPercent,
                dcChargeLimitPercent: dcChargeLimitPercent
            )

            commandStatusMessage = "Sending \(command.displayName.lowercased()) to \(vehicle.model)"
            try await client.sendCommand(for: vehicle, command: vehicleCommand, authToken: authToken)
            commandStatusMessage = "\(command.displayName) sent to \(vehicle.model)"

            if command != .setChargeLimit {
                try? await fetchAndCacheVehicleStatus(client: client, authToken: authToken, cached: false)
            }
            mfaChallenge = nil
            mfaClient = nil
        } catch let apiError as APIError where apiError.errorType == .requiresMFA {
            mfaChallenge = makeChallenge(from: apiError)
            commandStatusMessage = "Kia Connect requires verification"
            await notifyReauthNeeded(for: apiError)
            await sendOnlyAvailableMFAMethodIfNeeded()
        } catch {
            commandStatusMessage = userFacingMessage(for: error)
            await notifyReauthNeededIfNeeded(for: error)
        }
        #else
        commandStatusMessage = "BetterBlueKit is not linked in this build"
        #endif
    }
}

#if canImport(BetterBlueKit)
private extension KiaConnectUSAManager {
    func makeClient() throws -> any APIClientProtocol {
        let configuration = APIClientConfiguration(
            region: .usa,
            brand: .kia,
            username: credentials.username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: credentials.password,
            pin: "",
            accountId: credentials.accountId,
            rememberMeToken: credentials.rememberMeToken,
            deviceId: credentials.deviceId,
            onRememberMeTokenRotated: { [weak self] token in
                guard let self, self.credentials.rememberMeToken != token else { return }
                self.credentials.rememberMeToken = token
                self.saveCredentials()
            }
        )
        return try createBetterBlueKitAPIClient(configuration: configuration)
    }

    func makeAuthenticatedClient(status: (String) -> Void) async throws -> (client: any APIClientProtocol, authToken: AuthToken) {
        var client = try makeClient()
        if let authToken = credentials.authSession?.authToken, authToken.isValid {
            status("Using shared Kia Connect session")
            return (client, authToken)
        }

        guard credentials.isReadyForLogin else {
            throw KiaConnectUSALocalError.reauthenticationNeeded
        }

        if credentials.deviceId == nil {
            status("Registering this device with Kia Connect")
            credentials.deviceId = try await client.registerDevice()
            saveCredentials()
            client = try makeClient()
        }

        status("Signing in to Kia Connect US")
        mfaClient = client
        let authToken = try await client.login()
        storeAuthToken(authToken)
        return (client, authToken)
    }

    func storeAuthToken(_ authToken: AuthToken) {
        credentials.authSession = KiaConnectUSAAuthSession(authToken: authToken)
        saveCredentials()
    }

    func fetchAndCacheVehicleStatus(
        client: any APIClientProtocol,
        authToken: AuthToken,
        cached: Bool
    ) async throws {
        statusMessage = "Fetching vehicles"
        let fetchedVehicles = try await client.fetchVehicles(authToken: authToken)
        vehicles = fetchedVehicles.map {
            KiaConnectUSAVehicleSummary(id: $0.vin, vin: $0.vin, model: $0.model)
        }

        guard let vehicle = selectedVehicle(from: fetchedVehicles) else {
            statusMessage = "No Kia Connect vehicles found"
            return
        }

        credentials.selectedVIN = vehicle.vin
        saveCredentials()

        statusMessage = "Fetching EV9 status"
        let status = try await client.fetchVehicleStatus(for: vehicle, authToken: authToken, cached: cached)
        let snapshot = makeTelemetrySnapshot(vehicle: vehicle, status: status)
        VehicleTelemetryCache.store(snapshot)
        latestTelemetry = snapshot
        statusMessage = "Kia Connect updated \(vehicle.model)"
    }

    @discardableResult
    func importSharedStatusCache() -> Bool {
        guard let sharedStatus = KiaConnectUSACredentialsCache.loadStatusCache(),
              let snapshot = KiaConnectUSACredentialsCache.importStatusCache()
        else {
            return false
        }

        latestTelemetry = snapshot
        if let vin = sharedStatus.vin, credentials.selectedVIN == nil {
            credentials.selectedVIN = vin
            saveCredentials()
        }
        return true
    }

    func selectedVehicle(from vehicles: [BetterBlueKit.Vehicle]) -> BetterBlueKit.Vehicle? {
        if let selectedVIN = credentials.selectedVIN,
           let selectedVehicle = vehicles.first(where: { $0.vin == selectedVIN }) {
            return selectedVehicle
        }

        return vehicles.first { $0.model.localizedCaseInsensitiveContains("EV9") } ?? vehicles.first
    }

    func makeTelemetrySnapshot(vehicle: BetterBlueKit.Vehicle, status: VehicleStatus) -> VehicleTelemetrySnapshot {
        let evStatus = status.evStatus
        let rangeKilometers = evStatus.map {
            $0.evRange.range.units.convert($0.evRange.range.length, to: .kilometers)
        }

        return VehicleTelemetrySnapshot(
            source: .kiaConnectUSA,
            updatedAt: status.syncDate ?? status.lastUpdated,
            adapterName: nil,
            vehicleName: vehicle.model,
            vin: vehicle.vin,
            stateOfChargePercent: evStatus?.evRange.percentage,
            estimatedRangeKilometers: rangeKilometers,
            isCharging: evStatus?.charging,
            isPluggedIn: evStatus?.pluggedIn,
            chargingPowerKilowatts: nil,
            minutesToFull: nil,
            maximumBatteryCapacityKilowattHours: nil,
            activeConnector: nil,
            distanceToEmptyKilometers: rangeKilometers,
            plugPowerType: nil,
            chargeLimitPercent: nil,
            rawValues: [
                "vin": vehicle.vin,
                "model": vehicle.model,
                "regId": vehicle.regId,
                "cached": "true",
            ]
        )
    }

    func makeVehicleCommand(
        _ command: KiaConnectUSACommand,
        climateTemperatureFahrenheit: Double,
        climateDurationMinutes: Int,
        acChargeLimitPercent: Int,
        dcChargeLimitPercent: Int
    ) -> VehicleCommand {
        switch command {
        case .lock:
            return .lock
        case .unlock:
            return .unlock
        case .startClimate:
            var options = ClimateOptions(preferredUnits: .fahrenheit)
            options.temperature = Temperature(value: climateTemperatureFahrenheit, units: .fahrenheit)
            options.duration = climateDurationMinutes
            options.climate = true
            return .startClimate(options)
        case .stopClimate:
            return .stopClimate
        case .startCharge:
            return .startCharge
        case .stopCharge:
            return .stopCharge
        case .setChargeLimit:
            return .setTargetSOC(
                acLevel: min(100, max(50, acChargeLimitPercent)),
                dcLevel: min(100, max(50, dcChargeLimitPercent))
            )
        }
    }

    func makeChallenge(from error: APIError) -> KiaConnectUSAMFAChallenge? {
        guard let userInfo = error.userInfo,
              let xid = userInfo["xid"]
        else {
            return nil
        }

        return KiaConnectUSAMFAChallenge(
            xid: xid,
            otpKey: userInfo["otpKey"] ?? "",
            hasEmail: userInfo["hasEmail"] == "true",
            hasPhone: userInfo["hasPhone"] == "true",
            email: userInfo["email"],
            phone: userInfo["phone"]
        )
    }

    func userFacingMessage(for error: Error) -> String {
        if let localError = error as? KiaConnectUSALocalError {
            switch localError {
            case .reauthenticationNeeded:
                return "Shared Kia Connect session expired. Re-authenticate in Kia Maps or Galaxy Nav."
            }
        }

        guard let apiError = error as? APIError else {
            return error.localizedDescription
        }

        switch apiError.errorType {
        case .invalidCredentials:
            if credentials.hasStoredSession {
                return "Kia Connect rejected the shared session. Re-authenticate in Kia Maps or Galaxy Nav."
            }
            return "Kia Connect rejected the email or password."
        case .requiresMFA:
            return "Kia Connect requires verification."
        case .regionNotSupported:
            return "This sign-in screen is configured for Kia Connect US."
        case .kiaInvalidRequest:
            return "Kia Connect rejected this session. Remove the saved credentials and sign in again."
        case .serverError:
            return "Kia Connect is temporarily unavailable. Try again later."
        case .concurrentRequest:
            return "Kia Connect is already processing a request. Wait a moment and try again."
        default:
            return apiError.errorDescription ?? apiError.message
        }
    }

    func notifyReauthNeededIfNeeded(for error: Error) async {
        guard let apiError = error as? APIError else { return }

        switch apiError.errorType {
        case .invalidCredentials, .requiresMFA, .kiaInvalidRequest:
            await notifyReauthNeeded(for: apiError)
        default:
            break
        }
    }

    func notifyReauthNeeded(for error: APIError) async {
        await KiaConnectReauthNotifier.notify(reason: userFacingMessage(for: error))
    }
}

private enum KiaConnectUSALocalError: Error {
    case reauthenticationNeeded
}

private extension KiaConnectUSAAuthSession {
    init(authToken: AuthToken) {
        accessToken = authToken.accessToken
        refreshToken = authToken.refreshToken
        expiresAt = authToken.expiresAt
    }

    var authToken: AuthToken {
        AuthToken(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
    }
}
#endif
