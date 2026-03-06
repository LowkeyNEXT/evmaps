//
//  PorscheApiEndpoint.swift
//  KiaMaps
//
//  Created by Codex on 06.03.2026.
//

import Foundation

enum PorscheApiEndpoint {
    case authorize
    case loginIdentifier
    case loginPassword
    case mfaOTP
    case token
    case vehicles
    case vehicle(String)
    case commands(String)
    case commandStatus(vin: String, requestId: String)
    case profile

    var path: String {
        switch self {
        case .authorize:
            "authorize"
        case .loginIdentifier:
            "u/login/identifier"
        case .loginPassword:
            "u/login/password"
        case .mfaOTP:
            "u/mfa-otp-challenge"
        case .token:
            "oauth/token"
        case .vehicles:
            "connect/v1/vehicles"
        case let .vehicle(vin):
            "connect/v1/vehicles/\(vin)"
        case let .commands(vin):
            "connect/v1/vehicles/\(vin)/commands"
        case let .commandStatus(vin, requestId):
            "connect/v1/vehicles/\(vin)/commands/\(requestId)"
        case .profile:
            "account/v1/profile"
        }
    }

    var usesIdentityHost: Bool {
        switch self {
        case .authorize, .loginIdentifier, .loginPassword, .mfaOTP, .token:
            true
        case .vehicles, .vehicle, .commands, .commandStatus, .profile:
            false
        }
    }
}

extension PorscheApiConfiguration {
    func url(for endpoint: PorscheApiEndpoint) throws -> URL {
        let base = endpoint.usesIdentityHost ? loginHost : appApiBaseURL
        let normalizedBase = base.hasSuffix("/") ? base : base + "/"
        guard let url = URL(string: endpoint.path, relativeTo: URL(string: normalizedBase)) else {
            throw URLError(.badURL)
        }
        return url
    }
}
