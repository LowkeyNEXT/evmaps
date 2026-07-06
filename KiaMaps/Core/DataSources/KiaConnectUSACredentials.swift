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
}

private enum KiaConnectUSAKey: String {
    case credentials = "kiaConnectUSA.credentials"
}

enum KiaConnectUSACredentialsCache {
    static func load() -> KiaConnectUSACredentials {
        Keychain<KiaConnectUSAKey>.value(for: .credentials) ?? .empty
    }

    static func store(_ credentials: KiaConnectUSACredentials) {
        Keychain<KiaConnectUSAKey>.store(value: credentials, path: .credentials)
    }

    static func clear() {
        Keychain<KiaConnectUSAKey>.store(value: Optional<KiaConnectUSACredentials>.none, path: .credentials)
    }
}
