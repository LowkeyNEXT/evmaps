//
//  PorscheAuthClient.swift
//  KiaMaps
//
//  Created by Codex on 06.03.2026.
//

import Foundation

struct PorscheAuthClient {
    let configuration: PorscheApiConfiguration

    func makeAuthorizeURL(state: String = UUID().uuidString) throws -> URL {
        let endpointUrl = try configuration.url(for: .authorize)
        guard var components = URLComponents(url: endpointUrl, resolvingAgainstBaseURL: true) else {
            throw PorscheAuthError.invalidRedirect
        }
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: configuration.authClientId),
            .init(name: "redirect_uri", value: configuration.redirectUri),
            .init(name: "audience", value: configuration.audience),
            .init(name: "scope", value: configuration.scope),
            .init(name: "state", value: state),
            .init(name: "ui_locales", value: configuration.locale),
        ]
        guard let url = components.url else {
            throw PorscheAuthError.invalidRedirect
        }
        return url
    }

    func parseAuthorizationCallback(_ callback: URL) throws -> PorscheAuthorizationCallback {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw PorscheAuthError.invalidRedirect
        }
        let queryItems = components.queryItems ?? []

        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            if error == "mfa_required" {
                let state = queryItems.first(where: { $0.name == "state" })?.value ?? ""
                let challenge = PorscheMFAChallenge(state: state, challengeType: "otp")
                return .mfaRequired(challenge)
            }
            throw PorscheAuthError.backendError(error)
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw PorscheAuthError.missingAuthorizationCode
        }
        return .authorizationCode(code)
    }

    func mapMFASubmitResult(_ result: PorscheMFASubmitResult) throws {
        switch result {
        case .success:
            return
        case .invalidCode:
            throw PorscheAuthError.invalidMFACode
        }
    }
}
