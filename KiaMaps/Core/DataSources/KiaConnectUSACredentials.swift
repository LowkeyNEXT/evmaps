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

    static func clear() {
        Keychain<KiaConnectUSAKey>.store(value: Optional<KiaConnectUSACredentials>.none, path: .credentials)
        Keychain<KiaConnectUSAKey>.store(value: Optional<KiaConnectUSACredentials>.none, path: .session)
    }
}
