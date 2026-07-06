//
//  OBDTelemetry.swift
//  KiaMaps
//
//  Shared OBD snapshot cache for the app and Maps Intents extension.
//

import Foundation

struct OBDTelemetry: Codable, Equatable {
    let updatedAt: Date
    let adapterName: String
    let vin: String?
    let stateOfChargePercent: Double?
    let estimatedRangeKilometers: Double?
    let rawResponses: [String: String]

    var isFresh: Bool {
        updatedAt.addingTimeInterval(5 * 60) > Date()
    }
}
