//
//  PorscheModels.swift
//  KiaMaps
//
//  Created by Codex on 06.03.2026.
//

import Foundation

struct PorscheTokenSet: Codable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int
    let scope: String?
    let obtainedAt: Date

    var expiresAt: Date {
        obtainedAt.addingTimeInterval(TimeInterval(expiresIn))
    }

    func isExpired(leeway: TimeInterval = 60) -> Bool {
        Date().addingTimeInterval(leeway) >= expiresAt
    }
}

struct PorscheMFAChallenge: Codable, Equatable {
    let state: String
    let challengeType: String
}

enum PorscheAuthorizationCallback: Equatable {
    case authorizationCode(String)
    case mfaRequired(PorscheMFAChallenge)
}

struct PorscheVehicleSummary: Codable {
    struct Capabilities: Codable {
        let canLock: Bool?
        let canClimatise: Bool?
        let canCharge: Bool?
    }

    let vin: String
    let displayName: String
    let model: String
    let modelYear: Int?
    let batterySoc: Double?
    let rangeKm: Double?
    let charging: Bool?
    let locked: Bool?
    let latitude: Double?
    let longitude: Double?
    let capabilities: Capabilities?
}

struct PorscheVehicleSnapshot: Equatable {
    struct Capabilities: Equatable {
        let canLock: Bool
        let canClimatise: Bool
        let canCharge: Bool
    }

    let vin: String
    let batterySoc: Double
    let rangeKm: Double
    let charging: Bool
    let locked: Bool
    let latitude: Double?
    let longitude: Double?
    let capabilities: Capabilities
}

enum PorscheCommandRequest {
    case lock(vin: String)
    case climateOn(vin: String, temperatureC: Double)
    case climateOff(vin: String)
    case startCharging(vin: String)
    case stopCharging(vin: String)
}

struct PorscheCommandResult: Equatable {
    let requestId: UUID
}

enum PorscheAuthError: LocalizedError, Equatable {
    case mfaRequired(PorscheMFAChallenge)
    case invalidMFACode
    case missingAuthorizationCode
    case invalidRedirect
    case backendError(String)

    var errorDescription: String? {
        switch self {
        case let .mfaRequired(challenge):
            "MFA required (\(challenge.challengeType))."
        case .invalidMFACode:
            "Invalid MFA code."
        case .missingAuthorizationCode:
            "Authorization code not present in callback."
        case .invalidRedirect:
            "Invalid redirect callback URL."
        case let .backendError(message):
            "Porsche auth backend error: \(message)"
        }
    }
}

enum PorscheApiError: LocalizedError, Equatable {
    case unsupportedOperation(String)
    case blockedByCaptchaOrDeviceBinding
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedOperation(operation):
            "Unsupported Porsche operation in current implementation: \(operation)."
        case .blockedByCaptchaOrDeviceBinding:
            "Porsche account requires captcha/device-binding; complete login in My Porsche app and retry."
        case let .decodingFailed(message):
            "Failed to decode Porsche API response: \(message)"
        }
    }
}

enum PorscheMFASubmitResult {
    case success
    case invalidCode
}
