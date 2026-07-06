//
//  MapsIntentDebugLog.swift
//  KiaMaps
//
//  Shared debug trace for Apple Maps intent requests and responses.
//

import Foundation

private enum MapsIntentDebugLogKey: String {
    case entries = "mapsIntentDebugLog.entries"
}

struct MapsIntentDebugLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let event: String
    let detail: String

    init(event: String, detail: String) {
        id = UUID()
        timestamp = Date()
        self.event = event
        self.detail = detail
    }
}

enum MapsIntentDebugLog {
    private static let limit = 80

    static func append(event: String, detail: String) {
        var entries = latest()
        entries.append(MapsIntentDebugLogEntry(event: event, detail: detail))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        Keychain<MapsIntentDebugLogKey>.store(value: entries, path: .entries)
        logDebug("Maps intent: \(event) - \(detail)", category: .vehicle)
    }

    static func latest() -> [MapsIntentDebugLogEntry] {
        Keychain<MapsIntentDebugLogKey>.value(for: .entries) ?? []
    }

    static func clear() {
        Keychain<MapsIntentDebugLogKey>.store(value: Optional<[MapsIntentDebugLogEntry]>.none, path: .entries)
    }
}

