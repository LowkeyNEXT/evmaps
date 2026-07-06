//
//  OBDLinkView.swift
//  KiaMaps
//
//  Debug utility for connecting an OBDLink BLE adapter and caching telemetry.
//

import SwiftUI

struct OBDLinkView: View {
    @StateObject private var manager = OBDLinkBLEManager.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    Text(manager.state.title)
                    Button("Scan for OBDLink") {
                        manager.start()
                    }
                    Button("Disconnect", role: .destructive) {
                        manager.disconnect()
                    }
                }

                if let telemetry = manager.latestTelemetry {
                    Section("Latest Telemetry") {
                        LabeledContent("Adapter", value: telemetry.adapterName)
                        LabeledContent("Updated", value: telemetry.updatedAt.formatted(date: .omitted, time: .standard))
                        LabeledContent("VIN", value: telemetry.vin ?? "Not available")
                        LabeledContent("Battery") {
                            if let soc = telemetry.stateOfChargePercent {
                                Text("\(soc, specifier: "%.0f")%")
                            } else {
                                Text("PID 01 5B not available")
                            }
                        }
                        LabeledContent("Estimated Range") {
                            if let range = telemetry.estimatedRangeKilometers {
                                Text("\(range, specifier: "%.0f") km")
                            } else {
                                Text("Not available")
                            }
                        }
                    }

                    Section("Raw Responses") {
                        ForEach(telemetry.rawResponses.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(telemetry.rawResponses[key] ?? "")
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                }

                Section("Log") {
                    ForEach(Array(manager.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .navigationTitle("OBDLink")
        }
    }
}
