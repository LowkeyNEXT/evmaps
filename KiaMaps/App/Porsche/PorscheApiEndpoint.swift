//
//  PorscheApiEndpoint.swift
//  KiaMaps
//
//  Created by Codex on 06.03.2026.
//

import Foundation

enum PorscheApiEndpoint {
    case authorize
    case token
    case vehicles
    case summary(String)
    case lock(String)
    case unlock(String)
    case climateOn(String)
    case climateOff(String)
    case chargeStart(String)
    case chargeStop(String)

    var path: String {
        switch self {
        case .authorize:
            "authorize"
        case .token:
            "oauth/token"
        case .vehicles:
            "vehicles"
        case let .summary(vin):
            "vehicles/\(vin)/summary"
        case let .lock(vin):
            "vehicles/\(vin)/commands/lock"
        case let .unlock(vin):
            "vehicles/\(vin)/commands/unlock"
        case let .climateOn(vin):
            "vehicles/\(vin)/commands/climate/on"
        case let .climateOff(vin):
            "vehicles/\(vin)/commands/climate/off"
        case let .chargeStart(vin):
            "vehicles/\(vin)/commands/charging/start"
        case let .chargeStop(vin):
            "vehicles/\(vin)/commands/charging/stop"
        }
    }
}

extension PorscheApiConfiguration {
    func url(for endpoint: PorscheApiEndpoint) throws -> URL {
        let base: String
        switch endpoint {
        case .authorize, .token:
            base = "https://identity.porsche.com/"
        default:
            base = appApiBaseURL.hasSuffix("/") ? appApiBaseURL : appApiBaseURL + "/"
        }
        guard let url = URL(string: endpoint.path, relativeTo: URL(string: base)) else {
            throw URLError(.badURL)
        }
        return url
    }
}
