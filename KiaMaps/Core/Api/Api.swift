//
//  Api.swift
//  KiaMaps
//
//  Created by Lukas Foldyna on 28.05.2024.
//  Copyright © 2024 Lukas Foldyna. All rights reserved.
//

import Foundation
import os.log

protocol VehicleApiProvider {
    func webLoginUrl() throws -> URL?
    func login(username: String, password: String, recaptchaToken: String?) async throws -> AuthorizationData
    func login(authorizationCode: String) async throws -> AuthorizationData
    func logout() async throws
    func vehicles() async throws -> VehicleResponse
    func refreshVehicle(_ vehicleId: UUID) async throws -> UUID
    func vehicleCachedStatus(_ vehicleId: UUID) async throws -> VehicleStateResponse
    func profile() async throws -> String
    func startClimate(_ vehicleId: UUID, options: ClimateControlOptions, pin: String) async throws -> UUID
    func stopClimate(_ vehicleId: UUID) async throws -> UUID
}

enum VehicleApiProviderFactory {
    static func provider(for api: Api) -> VehicleApiProvider {
        switch api.configuration.apiProviderKind {
        case .hmg:
            HMGVehicleApiProvider(api: api)
        case .porsche:
            PorscheVehicleApiProvider(api: api)
        }
    }
}

final class HMGVehicleApiProvider: VehicleApiProvider {
    private unowned let api: Api

    init(api: Api) {
        self.api = api
    }

    func webLoginUrl() throws -> URL? { try api.hmgWebLoginUrl() }
    func login(username: String, password: String, recaptchaToken: String?) async throws -> AuthorizationData {
        try await api.hmgLogin(username: username, password: password, recaptchaToken: recaptchaToken)
    }

    func login(authorizationCode: String) async throws -> AuthorizationData {
        try await api.hmgLogin(authorizationCode: authorizationCode)
    }

    func logout() async throws { try await api.hmgLogout() }
    func vehicles() async throws -> VehicleResponse { try await api.hmgVehicles() }
    func refreshVehicle(_ vehicleId: UUID) async throws -> UUID { try await api.hmgRefreshVehicle(vehicleId) }
    func vehicleCachedStatus(_ vehicleId: UUID) async throws -> VehicleStateResponse { try await api.hmgVehicleCachedStatus(vehicleId) }
    func profile() async throws -> String { try await api.hmgProfile() }
    func startClimate(_ vehicleId: UUID, options: ClimateControlOptions, pin: String) async throws -> UUID {
        try await api.hmgStartClimate(vehicleId, options: options, pin: pin)
    }

    func stopClimate(_ vehicleId: UUID) async throws -> UUID {
        try await api.hmgStopClimate(vehicleId)
    }
}

final class PorscheVehicleApiProvider: VehicleApiProvider {
    private unowned let api: Api
    private let transport: PorscheHTTPTransport
    private let authClient: PorscheAuthClient
    private let commandPollIntervalNanoseconds: UInt64
    private var vinByVehicleID: [UUID: String] = [:]

    init(
        api: Api,
        transport: PorscheHTTPTransport? = nil,
        authClient: PorscheAuthClient? = nil,
        commandPollIntervalNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.api = api
        let resolvedTransport = transport ?? PorscheAuthClient.makeDefaultTransport()
        self.transport = resolvedTransport
        self.commandPollIntervalNanoseconds = commandPollIntervalNanoseconds
        if let authClient {
            self.authClient = authClient
        } else {
            self.authClient = PorscheAuthClient(configuration: Self.configuration(for: api), transport: resolvedTransport)
        }
    }

    func webLoginUrl() throws -> URL? {
        try authClient.makeAuthorizeURL()
    }

    func login(username: String, password: String, recaptchaToken _: String?) async throws -> AuthorizationData {
        let tokenSet = try await authClient.authenticate(username: username, password: password)
        let authorization = authorizationData(from: tokenSet, existing: api.authorization)
        api.authorization = authorization
        return authorization
    }

    func login(authorizationCode: String) async throws -> AuthorizationData {
        let tokenSet = try await authClient.exchangeAuthorizationCode(authorizationCode)
        let authorization = authorizationData(from: tokenSet, existing: api.authorization)
        api.authorization = authorization
        return authorization
    }

    func logout() async throws {
        api.authorization = nil
        vinByVehicleID.removeAll()
    }

    func vehicles() async throws -> VehicleResponse {
        let payload = try await authorizedJSONObject(endpoint: .vehicles)
        guard let vehiclesPayload = payload as? [PorscheVehicleMapper.JSONObject] else {
            throw PorscheApiError.decodingFailed("vehicle list payload")
        }
        let response = try PorscheVehicleMapper.mapVehicles(from: vehiclesPayload)
        vinByVehicleID = Dictionary(uniqueKeysWithValues: response.vehicles.map { ($0.vehicleId, $0.vin) })
        return response
    }

    func refreshVehicle(_ vehicleId: UUID) async throws -> UUID {
        let vin = try await resolveVIN(for: vehicleId)
        _ = try await authorizedJSONObject(
            endpoint: .vehicle(vin),
            queryItems: measurementQueryItems(wakeUp: true)
        )
        return vehicleId
    }

    func vehicleCachedStatus(_ vehicleId: UUID) async throws -> VehicleStateResponse {
        let vin = try await resolveVIN(for: vehicleId)
        let payload = try await authorizedJSONObject(
            endpoint: .vehicle(vin),
            queryItems: measurementQueryItems(wakeUp: false)
        )
        guard let statusPayload = payload as? PorscheVehicleMapper.JSONObject else {
            throw PorscheApiError.decodingFailed("vehicle status payload")
        }
        return try PorscheVehicleMapper.mapVehicleState(from: statusPayload)
    }

    func profile() async throws -> String {
        let payload = try await authorizedJSONObject(endpoint: .profile)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func startClimate(_ vehicleId: UUID, options: ClimateControlOptions, pin _: String) async throws -> UUID {
        guard options.isValid else {
            if !options.isTemperatureValid {
                throw ClimateControlError.invalidTemperature(options.temperature)
            }
            if !options.areSeatLevelsValid {
                throw ClimateControlError.invalidSeatLevel(-1)
            }
            throw ClimateControlError.invalidDuration(options.duration)
        }
        let vin = try await resolveVIN(for: vehicleId)
        return try await sendCommand(.climateOn(vin: vin, temperatureC: Double(options.temperature)))
    }

    func stopClimate(_ vehicleId: UUID) async throws -> UUID {
        let vin = try await resolveVIN(for: vehicleId)
        return try await sendCommand(.climateOff(vin: vin))
    }

    private static func configuration(for api: Api) -> PorscheApiConfiguration {
        guard let configuration = api.configuration as? PorscheApiConfiguration else {
            fatalError("Porsche provider requires PorscheApiConfiguration")
        }
        return configuration
    }

    private var configuration: PorscheApiConfiguration {
        Self.configuration(for: api)
    }

    private func authorizationData(from tokenSet: PorscheTokenSet, existing: AuthorizationData?) -> AuthorizationData {
        AuthorizationData(
            stamp: existing?.stamp ?? "porsche",
            deviceId: existing?.deviceId ?? UUID(),
            accessToken: tokenSet.accessToken,
            expiresIn: tokenSet.expiresIn,
            refreshToken: tokenSet.refreshToken,
            isCcuCCS2Supported: true,
            providerKind: "porsche",
            tokenIssuer: configuration.loginHost,
            tokenAudience: configuration.audience,
            tokenScope: tokenSet.scope ?? configuration.scope
        )
    }

    private func resolveVIN(for vehicleId: UUID) async throws -> String {
        if let vin = vinByVehicleID[vehicleId] {
            return vin
        }
        let vehicles = try await self.vehicles()
        guard let vehicle = vehicles.vehicles.first(where: { $0.vehicleId == vehicleId }) else {
            throw PorscheApiError.missingVehicle(vehicleId.uuidString)
        }
        return vehicle.vin
    }

    private func measurementQueryItems(wakeUp: Bool) -> [URLQueryItem] {
        var items = PorscheMeasurementCatalog.overview.map { URLQueryItem(name: "mf", value: $0) }
        if wakeUp {
            items.append(URLQueryItem(name: "wakeUpJob", value: UUID().uuidString))
        }
        return items
    }

    private func authorizedJSONObject(
        endpoint: PorscheApiEndpoint,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        retryOnUnauthorized: Bool = true
    ) async throws -> Any {
        guard let authorization = api.authorization else {
            throw ApiError.unauthorized
        }

        let response = try await send(
            endpoint: endpoint,
            method: method,
            queryItems: queryItems,
            body: body,
            accessToken: authorization.accessToken,
            accept: [200, 202, 401]
        )

        if response.response.statusCode == 401 {
            guard retryOnUnauthorized else {
                throw ApiError.unauthorized
            }
            let refreshedTokens = try await authClient.refreshToken(authorization.refreshToken)
            let refreshedAuthorization = authorizationData(from: refreshedTokens, existing: authorization)
            api.authorization = refreshedAuthorization
            return try await authorizedJSONObject(
                endpoint: endpoint,
                method: method,
                queryItems: queryItems,
                body: body,
                retryOnUnauthorized: false
            )
        }

        if response.data.isEmpty {
            return [:]
        }
        return try JSONSerialization.jsonObject(with: response.data)
    }

    private func sendCommand(_ request: PorscheCommandRequest) async throws -> UUID {
        let payload = try await authorizedJSONObject(
            endpoint: .commands(request.vin),
            method: "POST",
            body: PorscheVehicleMapper.commandBody(for: request)
        )

        guard let json = payload as? PorscheVehicleMapper.JSONObject,
              let status = json["status"] as? PorscheVehicleMapper.JSONObject,
              let identifier = status["id"] as? String,
              let requestID = UUID(uuidString: identifier)
        else {
            throw PorscheApiError.missingCommandRequestId
        }

        let initialState = (status["result"] as? String).flatMap(PorscheCommandExecutionState.init(rawValue:)) ?? .unknown
        if initialState == .accepted {
            try await pollCommand(vin: request.vin, requestID: requestID)
        }
        return requestID
    }

    private func pollCommand(vin: String, requestID: UUID) async throws {
        for _ in 0..<10 {
            if commandPollIntervalNanoseconds > 0 {
                try await Task.sleep(nanoseconds: commandPollIntervalNanoseconds)
            }
            let payload = try await authorizedJSONObject(endpoint: .commandStatus(vin: vin, requestId: requestID.uuidString))
            guard let json = payload as? PorscheVehicleMapper.JSONObject else {
                continue
            }
            let resultString = ((json["status"] as? PorscheVehicleMapper.JSONObject)?["result"] as? String) ?? "UNKNOWN"
            switch PorscheCommandExecutionState(rawValue: resultString) ?? .unknown {
            case .performed:
                return
            case .error:
                throw PorscheApiError.commandFailed(resultString)
            case .accepted, .unknown:
                continue
            }
        }
        throw PorscheApiError.commandFailed("timeout")
    }

    private func send(
        endpoint: PorscheApiEndpoint,
        method: String,
        queryItems: [URLQueryItem],
        body: Data?,
        accessToken: String,
        accept statusCodes: Set<Int>
    ) async throws -> PorscheHTTPTransportResponse {
        var components = URLComponents(url: try configuration.url(for: endpoint), resolvingAgainstBaseURL: true)
        if !queryItems.isEmpty {
            let existingItems = components?.queryItems ?? []
            components?.queryItems = existingItems + queryItems
        }

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(configuration.xClientId, forHTTPHeaderField: "X-Client-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let response = try await transport(request)
        guard statusCodes.contains(response.response.statusCode) else {
            throw ApiError.unexpectedStatusCode(response.response.statusCode)
        }
        return response
    }
}

/**
 * Api - Main interface for Kia/Hyundai/Genesis vehicle API communication
 * 
 * This class handles all aspects of vehicle API interaction including:
 * - RSA-encrypted OAuth2 authentication flow
 * - Vehicle status retrieval (cached and live refresh)
 * - Climate control operations with PIN protection
 * - User profile and session management
 * - Device registration for push notifications
 * 
 * ## Authentication Flow
 * The API uses a secure RSA-encrypted authentication process:
 * 1. Connector authorization with CSRF protection
 * 2. Client configuration retrieval
 * 3. Password encryption settings validation
 * 4. RSA certificate retrieval for password encryption
 * 5. OAuth2 flow initialization
 * 6. Encrypted sign-in with RSA-encrypted password
 * 7. Authorization code exchange for access tokens
 * 8. Device registration for push notifications
 * 
 * ## CCS2 Support
 * The API automatically detects and uses CCS2 endpoints when supported by the vehicle,
 * falling back to standard endpoints for older vehicles.
 * 
 * ## Thread Safety
 * This class is designed to be used from async contexts and is not thread-safe.
 * Use a single instance per authentication session.
 */
class Api {
    /// The API configuration containing endpoints, credentials, and service identifiers
    let configuration: ApiConfiguration

    /// Current authorization data including access tokens and device information
    /// Managed through the provider for consistent state management
    var authorization: AuthorizationData? {
        get {
            provider.authorization
        }
        set {
            provider.authorization = newValue
        }
    }

    /// Service for RSA encryption operations, used for password encryption during authentication
    private let rsaService: RSAEncryptionService
    
    /// Provider that handles actual API request execution and token management
    private let provider: ApiRequestProvider
    private lazy var vehicleApiProvider: VehicleApiProvider = VehicleApiProviderFactory.provider(for: self)

    init(configuration: ApiConfiguration, rsaService: RSAEncryptionService) {
        self.configuration = configuration
        self.rsaService = rsaService
        provider = ApiRequestProvider(configuration: configuration)
    }

    init(configuration: ApiConfiguration, rsaService: RSAEncryptionService, provider: ApiRequestProvider) {
        self.configuration = configuration
        self.rsaService = rsaService
        self.provider = provider
    }

    func webLoginUrl() throws -> URL? {
        try vehicleApiProvider.webLoginUrl()
    }

    func hmgWebLoginUrl() throws -> URL? {
        let queryItems = [
            URLQueryItem(name: "client_id", value: configuration.serviceId),
            URLQueryItem(name: "redirect_uri", value: "https://prd.eu-ccapi.kia.com:8080/api/v1/user/oauth2/redirect"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "lang", value: "en"),
            URLQueryItem(name: "state", value: "ccsp"),
        ]

        return try provider.request(
            endpoint: .oauth2UserAuthorize,
            queryItems: queryItems,
            headers: commonNavigationHeaders()
        ).urlRequest.url
    }

    /// Authenticate user and establish session with vehicle API using RSA-encrypted authentication
    /// - Parameters:
    ///   - username: User's login username/email
    ///   - password: User's login password
    ///   - recaptchaToken: Optional reCAPTCHA verification token
    /// - Returns: Complete authorization data including tokens and device ID
    /// - Throws: Authentication errors, network errors, or validation failures
    func login(username: String, password: String, recaptchaToken: String? = nil) async throws -> AuthorizationData {
        try await vehicleApiProvider.login(username: username, password: password, recaptchaToken: recaptchaToken)
    }

    func hmgLogin(username: String, password: String, recaptchaToken: String? = nil) async throws -> AuthorizationData {
        cleanCookies()
        // Step 0: Get connector authorization (handles 302 redirect to get next_uri)
        let referer: String
        do {
            referer = try await fetchConnectorAuthorization()
            logInfo("Retrieved referer: \(referer)", category: .api)
        } catch {
            logError("Client connector authorization failed: \(error.localizedDescription)", category: .api)
            throw AuthenticationError.clientConfigurationFailed
        }

        // Step 1: Get client configuration
        let clientConfig = try await fetchClientConfiguration(referer: referer)
        logInfo("Client configured for: \(clientConfig.clientName)", category: .api)
        
        // Step 2: Check if password encryption is enabled
        let encryptionSettings = try await fetchPasswordEncryptionSettings(referer: referer)
        guard encryptionSettings.useEnabled && encryptionSettings.value1 == "true" else {
            throw AuthenticationError.encryptionSettingsFailed
        }
        
        // Step 3: Get RSA certificate for password encryption
        let rsaKey: RSAEncryptionService.RSAKeyData
        do {
            rsaKey = try await fetchRSACertificate(referer: referer)
        } catch {
            logError("Fetch RSA Certificate failed: \(error.localizedDescription)", category: .api)
            throw AuthenticationError.certificateRetrievalFailed
        }
        // Step 4: Initialize OAuth2 flow
        let csrfToken = try await initializeOAuth2(referer: referer)

        // Step 5: Sign in with encrypted password
        let authorizationCode = try await signIn(
            referer: referer,
            username: username,
            password: password,
            rsaKey: rsaKey,
            csrfToken: csrfToken,
            recaptchaToken: recaptchaToken
        )

        // Step 6: Exchange authorization code for tokens
        return try await login(authorizationCode: authorizationCode)
    }

    func login(authorizationCode: String) async throws -> AuthorizationData {
        try await vehicleApiProvider.login(authorizationCode: authorizationCode)
    }

    func hmgLogin(authorizationCode: String) async throws -> AuthorizationData {
        // Step 6: Exchange authorization code for tokens
        let tokenResponse: TokenResponse
        do {
            tokenResponse = try await exchangeCodeForTokens(authorizationCode: authorizationCode)
        } catch {
            logError("Exchange code for token failed: \(error.localizedDescription)", category: .api)
            throw AuthenticationError.tokenExchangeFailed
        }

        // Generate device ID and stamp for compatibility
        let stamp = AuthorizationData.generateStamp(for: configuration)
        let deviceId = try await deviceId(stamp: stamp)

        // Convert to existing AuthorizationData format
        let authorizationData = AuthorizationData(
            stamp: stamp,
            deviceId: deviceId,
            accessToken: tokenResponse.accessToken,
            expiresIn: tokenResponse.expiresIn,
            refreshToken: tokenResponse.refreshToken,
            isCcuCCS2Supported: true
        )

        provider.authorization = authorizationData
        try await notificationRegister(deviceId: deviceId)
        return authorizationData
    }

    /// Logout user and clean up session data
    /// - Throws: Network errors (non-critical - cleanup continues regardless)
    func logout() async throws {
        try await vehicleApiProvider.logout()
    }

    func hmgLogout() async throws {
        do {
            try await provider.request(with: .post, endpoint: .logout).empty()
            logInfo("Successfully logout", category: .auth)
        } catch {
            logError("Failed to logout: \(error.localizedDescription)", category: .auth)
        }
        provider.authorization = nil
        cleanCookies()
    }

    /// Retrieve list of vehicles associated with the user account
    /// - Returns: Complete vehicle response containing all registered vehicles
    /// - Throws: Network errors or authentication failures
    func vehicles() async throws -> VehicleResponse {
        try await vehicleApiProvider.vehicles()
    }

    func hmgVehicles() async throws -> VehicleResponse {
        guard authorization != nil else {
            throw ApiError.unauthorized
        }
        return try await provider.request(endpoint: .vehicles).response()
    }

    /// Request fresh vehicle status update from the vehicle
    /// - Parameter vehicleId: The vehicle's unique identifier
    /// - Returns: Operation result ID for tracking the refresh request
    /// - Note: Uses CCS2 endpoint if supported, fallback to standard endpoint
    /// - Throws: Network errors or vehicle communication failures
    func refreshVehicle(_ vehicleId: UUID) async throws -> UUID {
        try await vehicleApiProvider.refreshVehicle(vehicleId)
    }

    func hmgRefreshVehicle(_ vehicleId: UUID) async throws -> UUID {
        guard let authorization = authorization else {
            throw ApiError.unauthorized
        }
        let endpoint: ApiEndpoint = authorization.isCcuCCS2Supported == true ? .refreshCCS2Vehicle(vehicleId) : .refreshVehicle(vehicleId)
        return try await provider.request(endpoint: endpoint).responseEmpty().resultId
    }

    /// Retrieve cached vehicle status (last known state)
    /// - Parameter vehicleId: The vehicle's unique identifier
    /// - Returns: Complete vehicle status including battery, location, and system states
    /// - Note: Uses CCS2 endpoint if supported, fallback to standard endpoint
    /// - Throws: Network errors or data parsing failures
    func vehicleCachedStatus(_ vehicleId: UUID) async throws -> VehicleStateResponse {
        try await vehicleApiProvider.vehicleCachedStatus(vehicleId)
    }

    func hmgVehicleCachedStatus(_ vehicleId: UUID) async throws -> VehicleStateResponse {
        guard let authorization = authorization else {
            throw ApiError.unauthorized
        }
        let endpoint: ApiEndpoint = authorization.isCcuCCS2Supported == true ? .vehicleCachedCCS2Status(vehicleId) : .vehicleCachedStatus(vehicleId)
        return try await provider.request(endpoint: endpoint).response()
    }

    /// Retrieve user profile information
    /// - Returns: User profile data as JSON string
    /// - Throws: Network errors or authentication failures
    func profile() async throws -> String {
        try await vehicleApiProvider.profile()
    }

    func hmgProfile() async throws -> String {
        guard authorization != nil else {
            throw ApiError.unauthorized
        }
        return try await provider.request(endpoint: .userProfile).string()
    }
    
    // MARK: - Climate Control
    
    /// Start climate control with specified options
    /// - Parameters:
    ///   - vehicleId: The vehicle ID
    ///   - options: Climate control configuration options
    ///   - pin: Vehicle PIN (required for climate control)
    /// - Returns: Operation result ID for tracking
    func startClimate(_ vehicleId: UUID, options: ClimateControlOptions, pin: String) async throws -> UUID {
        try await vehicleApiProvider.startClimate(vehicleId, options: options, pin: pin)
    }

    func hmgStartClimate(_ vehicleId: UUID, options: ClimateControlOptions, pin: String) async throws -> UUID {
        guard authorization?.accessToken != nil else {
            throw ApiError.unauthorized
        }
        guard !pin.isEmpty else {
            throw ClimateControlError.missingPin
        }
        
        guard options.isValid else {
            if !options.isTemperatureValid {
                throw ClimateControlError.invalidTemperature(options.temperature)
            }
            if !options.areSeatLevelsValid {
                let invalidLevel = [options.driverSeatLevel, options.passengerSeatLevel, 
                                 options.rearLeftSeatLevel, options.rearRightSeatLevel]
                    .first { $0 < 0 || $0 > 3 } ?? -1
                throw ClimateControlError.invalidSeatLevel(invalidLevel)
            }
            if !options.isDurationValid {
                throw ClimateControlError.invalidDuration(options.duration)
            }
            throw ClimateControlError.vehicleNotReady
        }

        let request = options.toClimateControlRequest(pin: pin)
        
        return try await provider.request(
            with: .post,
            endpoint: .startClimate(vehicleId),
            encodable: request
        ).responseEmpty().resultId
    }
    
    /// Stop climate control
    /// - Parameter vehicleId: The vehicle ID
    /// - Returns: Operation result ID for tracking
    func stopClimate(_ vehicleId: UUID) async throws -> UUID {
        try await vehicleApiProvider.stopClimate(vehicleId)
    }

    func hmgStopClimate(_ vehicleId: UUID) async throws -> UUID {
        guard authorization?.accessToken != nil else {
            throw ApiError.unauthorized
        }
        return try await provider.request(
            with: .post,
            endpoint: .stopClimate(vehicleId)
        ).responseEmpty().resultId
    }
}

extension Api {
    // MARK: - MQTT Service Hub Methods

    /**
     * MQTT Step 1: Get device host information for MQTT connection
     * GET /api/v3/servicehub/device/host
     */
    func fetchMQTTDeviceHost() async throws -> MQTTHostInfo {
        guard authorization?.accessToken != nil else {
            throw ApiError.unauthorized
        }

        let response: MQTTHostResponse = try await provider.request(endpoint: .mqttDeviceHost).data()
        return MQTTHostInfo(
            host: response.mqtt.host,
            port: response.mqtt.port,
            ssl: response.mqtt.ssl
        )
    }

    /**
     * MQTT Step 2: Register device as mobile unit for MQTT communication
     * POST /api/v3/servicehub/device/register
     */
    func registerMQTTDevice() async throws -> MQTTDeviceInfo {
        guard authorization?.accessToken != nil else {
            throw ApiError.unauthorized
        }

        let deviceUUID = "\(UUID().uuidString)_UVO"
        let request = DeviceRegisterRequest(unit: "mobile", uuid: deviceUUID)
        let response: DeviceRegisterResponse = try await provider.request(endpoint: .mqttRegisterDevice, encodable: request).data()

        return MQTTDeviceInfo(
            clientId: response.clientId,
            deviceId: response.deviceId,
            uuid: deviceUUID
        )
    }

    /**
     * MQTT Step 3: Get vehicle metadata and supported protocols for MQTT
     * GET /api/v3/servicehub/vehicles/metadatalist?carId=<carId>&brand=K
     */
    func fetchMQTTVehicleMetadata(for vehicleId: UUID, clientId: String) async throws -> [MQTTVehicleMetadata] {
        guard authorization?.accessToken != nil else {
            throw ApiError.unauthorized
        }

        let response: VehicleMetadataResponse = try await provider.request(
            endpoint: .mqttVehicleMetadata,
            queryItems: [
                URLQueryItem(name: "carId", value: vehicleId.uuidString),
                URLQueryItem(name: "brand", value: configuration.brandCode)
            ],
            headers: [
                "client-id": clientId
            ]
        ).data()

        return response.vehicles
    }

    /**
     * MQTT Step 4: Subscribe to specific vehicle protocols for MQTT communication
     * POST /api/v3/servicehub/device/protocol
     */
    func subscribeMQTTVehicleProtocols(for vehicleId: UUID, clientId: String, protocolId: any MQTTProtocol, protocols: [any MQTTProtocol]) async throws {
        guard authorization?.accessToken != nil else {
            throw ApiError.unauthorized
        }

        // Subscribe to CCU (Car Control Unit) real-time updates
        let request = ProtocolSubscriptionRequest(
            protocols: protocols,
            protocolId: protocolId,
            carId: vehicleId,
            brand: configuration.brandCode
        )

        try await provider.request(
            endpoint: .mqttDeviceProtocol,
            headers: [
                "client-id": clientId
            ],
            encodable: request
        ).empty()
    }

    /**
     * MQTT Step 5: Check MQTT connection state after protocol subscription
     * GET /api/v3/vstatus/connstate?clientId=<clientId>
     */
    func checkMQTTConnectionState(clientId: String) async throws -> ConnectionStateResponse {
        guard authorization?.accessToken != nil else {
            throw ApiError.unauthorized
        }

        return try await provider.request(
            endpoint: .mqttConnectionState,
            queryItems: [
                URLQueryItem(name: "clientId", value: clientId),
            ],
            headers: [
                "client-id": clientId
            ]
        ).data()
    }
}

extension Api {
    /// Login - Step 0: Get Connector Authorization
    func fetchConnectorAuthorization() async throws -> String {
        // Build the state parameter (base64 encoded JSON)
        let stateObject = ConnectorAuthorizationState(
            scope: nil,
            state: nil,
            lang: nil,
            cert: "",
            action: "idpc_auth_endpoint",
            clientId: configuration.serviceId,
            redirectUri: try makeRedirectUri(endpoint: .loginRedirect),
            responseType: "code",
            signupLink: nil,
            hmgid2ClientId: configuration.authClientId,
            hmgid2RedirectUri: try makeRedirectUri(),
            hmgid2Scope: nil,
            hmgid2State: "ccsp",
            hmgid2UiLocales: nil
        )
        let stateData = try JSONEncoder().encode(stateObject)

        let queryItems = [
            URLQueryItem(name: "client_id", value: configuration.serviceId),
            URLQueryItem(name: "redirect_uri", value: try makeRedirectUri(endpoint: .loginRedirect).absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: stateData.base64EncodedString()),
            URLQueryItem(name: "cert", value: ""),
            URLQueryItem(name: "action", value: "idpc_auth_endpoint"),
            URLQueryItem(name: "sso_session_reset", value: "true")
        ]

        let referalUrl = try await provider.request(
            endpoint: .oauth2ConnectorAuthorize,
            queryItems: queryItems,
            headers: commonNavigationHeaders()
        ).referalUrl()

        // Extract next_uri from Location header
        guard let nextUri = extractNextUri(from: referalUrl) else {
            throw AuthenticationError.oauth2InitializationFailed
        }
        return nextUri
    }

    /// Login - Step 1: Get Client Configuration
    func fetchClientConfiguration(referer: String) async throws -> ClientConfiguration {
        try await provider.request(
            endpoint: .loginConnectorClients(configuration.serviceId),
            headers: commonJSONHeaders()
        ).responseValue()
    }

    /// Login - Step 2: Check Password Encryption Settings
    func fetchPasswordEncryptionSettings(referer: String) async throws -> PasswordEncryptionSettings {
        try await provider.request(
            endpoint: .loginCodes,
            headers: commonJSONHeaders(referer: referer)
        ).responseValue()
    }

    /// Login - Step 3: Get RSA Certificate
    func fetchRSACertificate(referer: String) async throws -> RSAEncryptionService.RSAKeyData {
        let certificate: RSACertificateResponse = try await provider.request(
            endpoint: .loginCertificates,
            headers: commonJSONHeaders(referer: referer)
        ).responseValue()

        return RSAEncryptionService.RSAKeyData(
            keyType: certificate.kty,
            exponent: certificate.e,
            keyId: certificate.kid,
            modulus: certificate.n
        )
    }

    /// Login - Step 4: Initialize OAuth2 Flow
    func initializeOAuth2(referer: String) async throws -> String {
        let queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.serviceId),
            URLQueryItem(name: "redirect_uri", value: try makeRedirectUri().absoluteString),
            URLQueryItem(name: "lang", value: "en"),
            URLQueryItem(name: "state", value: "ccsp")
        ]

        _ = try await provider.request(
            endpoint: .oauth2UserAuthorize,
            queryItems: queryItems,
            headers: commonNavigationHeaders(referer: referer)
        ).empty(acceptStatusCode: 302)

        let cookies = HTTPCookieStorage.shared.cookies

        // Parse HTML response to extract CSRF token and session key
        guard let cookie = cookies?.first(where: { $0.name == "account" }) else {
            throw AuthenticationError.csrfTokenNotFound
        }
        return cookie.value
    }

    /// Login - Step 5: Encrypted Sign-In
    func signIn(referer: String, username: String, password: String, rsaKey: RSAEncryptionService.RSAKeyData, csrfToken: String, recaptchaToken: String? = nil) async throws -> String {
        // Encrypt password
        let encryptedPassword = try rsaService.encryptPassword(password, with: rsaKey)

        guard let connectorSessionKey = extractConnectorSessionKey(from: referer) else {
            throw AuthenticationError.sessionKeyNotFound
        }

        // Prepare form data
        var form: [String: String] = [
            "client_id": configuration.serviceId,
            "encryptedPassword": "true",
            "orgHmgSid": "",
            "password": encryptedPassword,
            "kid": rsaKey.keyId,
            "redirect_uri": try makeRedirectUri().absoluteString,
            "scope": "",
            "nonce": "",
            "state": "ccsp",
            "username": username,
            "remember_me": "false",
            "connector_session_key": connectorSessionKey,
            "_csrf": csrfToken
        ]
        
        // Add reCAPTCHA token if provided
        if let recaptchaToken = recaptchaToken {
            form["g-recaptcha-response"] = recaptchaToken
            logInfo("Including reCAPTCHA token in sign-in request", category: .auth)
        }

        let referalUrl = try await provider.request(
            with: .post,
            endpoint: .loginSignin,
            headers: [
                "Sec-Fetch-Site": "same-origin",
                "Sec-Fetch-Mode": "navigate",
                "Sec-Fetch-Dest": "document",
                "Origin": "https://idpconnect-eu.\(configuration.key).com",
                "Referer": referer
            ],
            form: form
        ).referalUrl()

        let (code, _, loginSuccess) = try extractAuthorizationCode(from: referalUrl)
        guard loginSuccess else {
            throw AuthenticationError.signInFailed
        }
        return code
    }

    /// Login - Step 6: Exchange Authorization Code for Tokens
    func exchangeCodeForTokens(authorizationCode: String) async throws -> TokenResponse {
        let form: [String: String] = [
            "client_id": configuration.serviceId,
            "client_secret": "secret", // TODO: something generated
            "code": authorizationCode,
            "grant_type": "authorization_code",
            "redirect_uri": try makeRedirectUri().absoluteString
        ]

        return try await provider.request(
            with: .post,
            endpoint: .loginToken,
            form: form
        ).data()
    }

    /// Register device and retrieve device ID for push notifications
    /// - Parameter stamp: Authorization stamp for device registration
    /// - Returns: Unique device ID for this installation
    /// - Throws: Device registration failures or network errors
    func deviceId(stamp: String) async throws -> UUID {
        /* let number = Int.random(in: 80_000_000_000...100_000_000_000)
         let myHex = String(format: "%064x", number)
         String(myHex.prefix(64)) */
        let registrationId = "60a0cce8de8b3b51745f10bc35fe07cb000000ef"
        let uuid = UUID().uuidString

        let headers = [
            "ccsp-service-id": configuration.serviceId,
            "ccsp-application-id": configuration.appId,
            "Stamp": stamp,
        ]
        let payload: [String: String] = [
            "pushRegId": registrationId,
            "pushType": configuration.pushType,
            "uuid": uuid,
        ]

        let response: NotificationRegistrationResponse = try await provider.request(
            endpoint: .notificationRegister,
            headers: headers,
            encodable: payload
        ).response(acceptStatusCode: 302)
        return response.deviceId
    }

    /// Register device for push notifications with vehicle service
    /// - Parameter deviceId: Device ID obtained from device registration
    /// - Throws: Notification registration failures or network errors
    func notificationRegister(deviceId: UUID) async throws {
        var headers: ApiRequest.Headers = provider.authorization?.authorizatioHeaders(for: configuration) ?? [:]
        headers["Content-Type"] = "application/json; charset=UTF-8"
        headers["offset"] = "2"
        try await provider.request(with: .post, endpoint: .notificationRegisterWithDeviceId(deviceId), headers: headers).empty(acceptStatusCode: 200)
    }

    // MARK: - Helpers

    func makeRedirectUri(endpoint: ApiEndpoint = .oauth2Redirect) throws -> URL {
        try provider.configuration.url(for: endpoint)
    }

    func extractNextUri(from location: URL) -> String? {
        guard let components = URLComponents(url: location, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }

        // Look for next_uri parameters
        return queryItems.first(where: {  $0.name == "next_uri" })?.value
    }

    func extractConnectorSessionKey(from location: String) -> String? {
        guard let url = URL(string: location),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }

        // Look for both next_uri parameters
        return queryItems.first(where: { $0.name == "connector_session_key" })?.value
    }

    func extractAuthorizationCode(from location: URL) throws -> (code: String, state: String, loginSuccess: Bool) {
        guard let components = URLComponents(url: location, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            throw AuthenticationError.authorizationCodeNotFound
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw AuthenticationError.authorizationCodeNotFound
        }

        let state = queryItems.first(where: { $0.name == "state" })?.value ?? "ccsp"
        let loginSuccess = queryItems.first(where: { $0.name == "login_success" })?.value == "y"

        return (code: code, state: state, loginSuccess: loginSuccess)
    }

    func commonJSONHeaders(referer: String? = nil) -> [String: String] {
        var headers = [
            "Sec-Fetch-Site": "same-origin",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty",
        ]
        if let referer = referer {
            headers["Referer"] = referer
        }
        return headers
    }

    func commonNavigationHeaders(referer: String? = nil) -> [String: String] {
        var headers = [
            "Sec-Fetch-Site": "none",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Dest": "document",

        ]
        if let referer = referer {
            headers["Referer"] = referer
        }
        return headers
    }

    /// Clear all HTTP cookies to ensure clean authentication state
    func cleanCookies() {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        for cookie in cookies {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }
}
