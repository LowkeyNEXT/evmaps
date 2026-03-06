//
//  PorscheAuthClientTests.swift
//  KiaTests
//
//  Created by Codex on 06.03.2026.
//

import XCTest
@testable import KiaMaps

final class PorscheAuthClientTests: XCTestCase {
    func testAuthorizeURLContainsExpectedQueryForEU() throws {
        let client = PorscheAuthClient(configuration: .europe)
        let url = try client.makeAuthorizeURL(state: "state-eu")

        XCTAssertEqual(url.host, "identity.porsche.com")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["client_id"], PorscheApiConfiguration.europe.authClientId)
        XCTAssertEqual(items["redirect_uri"], PorscheApiConfiguration.europe.redirectUri)
        XCTAssertEqual(items["audience"], PorscheApiConfiguration.europe.audience)
        XCTAssertEqual(items["scope"], PorscheApiConfiguration.europe.scope)
        XCTAssertEqual(items["state"], "state-eu")
        XCTAssertEqual(items["ui_locales"], "de_DE")
    }

    func testAuthorizeURLContainsExpectedQueryForUS() throws {
        let client = PorscheAuthClient(configuration: .usa)
        let url = try client.makeAuthorizeURL(state: "state-us")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["ui_locales"], "en_US")
        XCTAssertEqual(items["state"], "state-us")
    }

    func testParseAuthorizationCallbackCode() throws {
        let client = PorscheAuthClient(configuration: .europe)
        let callback = try XCTUnwrap(URL(string: "my-porsche-app://auth0/callback?code=abc123&state=s1"))
        let result = try client.parseAuthorizationCallback(callback)
        XCTAssertEqual(result, .authorizationCode("abc123"))
    }

    func testParseAuthorizationCallbackMFA() throws {
        let client = PorscheAuthClient(configuration: .europe)
        let callback = try XCTUnwrap(URL(string: "my-porsche-app://auth0/callback?error=mfa_required&state=s-mfa"))
        let result = try client.parseAuthorizationCallback(callback)
        XCTAssertEqual(result, .mfaRequired(.init(state: "s-mfa", challengeType: "otp")))
    }

    func testTokenExpiryHandling() {
        let token = PorscheTokenSet(
            accessToken: "a",
            refreshToken: "r",
            tokenType: "Bearer",
            expiresIn: 3600,
            scope: nil,
            obtainedAt: Date().addingTimeInterval(-3500)
        )
        XCTAssertTrue(token.isExpired(leeway: 120))
        XCTAssertFalse(token.isExpired(leeway: 10))
    }

    func testMFAResultMapping() throws {
        let client = PorscheAuthClient(configuration: .europe)
        XCTAssertNoThrow(try client.mapMFASubmitResult(.success))
        XCTAssertThrowsError(try client.mapMFASubmitResult(.invalidCode)) { error in
            XCTAssertEqual(error as? PorscheAuthError, .invalidMFACode)
        }
    }
}
