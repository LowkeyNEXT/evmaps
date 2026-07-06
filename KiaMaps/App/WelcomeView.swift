//
//  WelcomeView.swift
//  KiaMaps
//
//  Created by Claude Code on 23.07.2025.
//  Login state view for MainView
//

import SwiftUI

/// Login view displayed when user is not authenticated
struct WelcomeView: View {
    let onLogin: () -> Void
    @State private var isShowingOBDLink = false
    @State private var isShowingDataSources = false
    @State private var preferences = VehicleDataSourcePreferencesCache.load()
    @State private var vehicleProfile = VehicleProfileStore.selected()
    @State private var snapshots = VehicleTelemetryCache.allLatest()
    @StateObject private var galaxyManager = GalaxyVehicleDataSourceManager()
    @StateObject private var obdManager = OBDLinkBLEManager.shared
    @AppStorage("vehicleProfile.measurementSystem") private var measurementSystemRaw = VehicleProfileMeasurementSystem.us.rawValue
    
    var body: some View {
        ScrollView {
            VStack(spacing: KiaDesign.Spacing.large) {
                headerView

                if let snapshot = displayedSnapshot {
                    connectedStatusView(snapshot)
                } else {
                    disconnectedStatusView
                }

                sourceSummaryView

                actionButtons
            }
            .padding(KiaDesign.Spacing.large)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KiaDesign.Colors.background)
        .navigationTitle("Kia")
        .sheet(isPresented: $isShowingOBDLink) {
            OBDLinkView()
                .onDisappear(perform: reloadHomeState)
        }
        .sheet(isPresented: $isShowingDataSources) {
            VehicleDataSourcesView()
                .onDisappear(perform: reloadHomeState)
        }
        .onAppear() {
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
            reloadHomeState()
            Task { await refreshGalaxyIfConfigured() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .galaxyVehicleCredentialsDidImport)) { _ in
            galaxyManager.credentials = GalaxyVehicleCredentialsCache.load()
            Task { await refreshGalaxyIfConfigured() }
        }
    }

    private var headerView: some View {
        HStack(spacing: KiaDesign.Spacing.medium) {
            Image(systemName: "bolt.car")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(KiaDesign.Colors.primary)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: KiaDesign.Spacing.xs) {
                Text(vehicleTitle)
                    .font(KiaDesign.Typography.title1)
                    .foregroundStyle(KiaDesign.Colors.textPrimary)

                Text(headerSubtitle)
                    .font(KiaDesign.Typography.bodySmall)
                    .foregroundStyle(KiaDesign.Colors.textSecondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func connectedStatusView(_ snapshot: VehicleTelemetrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: KiaDesign.Spacing.medium) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: KiaDesign.Spacing.xs) {
                    Text(snapshot.isFresh ? "Live vehicle data" : "Last known vehicle data")
                        .font(KiaDesign.Typography.title2)
                        .foregroundStyle(KiaDesign.Colors.textPrimary)

                    Text("Maps is using \(snapshot.source.displayName)")
                        .font(KiaDesign.Typography.bodySmall)
                        .foregroundStyle(KiaDesign.Colors.textSecondary)
                }

                Spacer()

                statusBadge(snapshot.isFresh ? "Live" : "Stale", color: snapshot.isFresh ? KiaDesign.Colors.success : KiaDesign.Colors.warning)
            }

            HStack(alignment: .firstTextBaseline, spacing: KiaDesign.Spacing.medium) {
                metricBlock(
                    title: "Battery",
                    value: snapshot.stateOfChargePercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "--"
                )

                metricBlock(
                    title: "Range",
                    value: rangeSummary(for: snapshot)
                )

                metricBlock(
                    title: "Charging",
                    value: chargingSummary(for: snapshot)
                )
            }

            Divider()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: KiaDesign.Spacing.medium) {
                detailItem("Vehicle", snapshot.vehicleName ?? vehicleProfile.displayName)
                detailItem("Updated", snapshot.updatedAt.formatted(date: .omitted, time: .shortened))
                detailItem("Plug", snapshot.plugPowerType?.uppercased() ?? snapshot.activeConnector ?? "Not available")
                detailItem("Charge Limit", snapshot.chargeLimitPercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "Not available")
                detailItem("Capacity", snapshot.maximumBatteryCapacityKilowattHours.map { "\($0.formatted(.number.precision(.fractionLength(1)))) kWh" } ?? "\(vehicleProfile.maximumBatteryCapacityKilowattHours.formatted(.number.precision(.fractionLength(1)))) kWh")
                detailItem("VIN", snapshot.vin?.isEmpty == false ? String(snapshot.vin!.suffix(8)) : "Not available")
            }
        }
        .padding(KiaDesign.Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KiaDesign.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: KiaDesign.CornerRadius.small))
    }

    private var disconnectedStatusView: some View {
        VStack(alignment: .leading, spacing: KiaDesign.Spacing.medium) {
            HStack {
                VStack(alignment: .leading, spacing: KiaDesign.Spacing.xs) {
                    Text("No live vehicle data")
                        .font(KiaDesign.Typography.title2)
                        .foregroundStyle(KiaDesign.Colors.textPrimary)

                    Text("Connect Galaxy, OBDLink, or Kia Connect so Maps can get battery and range.")
                        .font(KiaDesign.Typography.bodySmall)
                        .foregroundStyle(KiaDesign.Colors.textSecondary)
                }

                Spacer()

                statusBadge("Setup", color: KiaDesign.Colors.warning)
            }
        }
        .padding(KiaDesign.Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KiaDesign.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: KiaDesign.CornerRadius.small))
    }

    private var sourceSummaryView: some View {
        VStack(alignment: .leading, spacing: KiaDesign.Spacing.medium) {
            Text("Data Sources")
                .font(KiaDesign.Typography.title3)
                .foregroundStyle(KiaDesign.Colors.textPrimary)

            VStack(spacing: KiaDesign.Spacing.small) {
                ForEach(VehicleTelemetrySourceKind.allCases) { source in
                    sourceRow(source)
                }
            }
        }
        .padding(KiaDesign.Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KiaDesign.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: KiaDesign.CornerRadius.small))
    }

    private var actionButtons: some View {
        VStack(spacing: KiaDesign.Spacing.medium) {
            KiaButton(
                displayedSnapshot == nil ? "Connect Vehicle" : "Manage Data Sources",
                icon: displayedSnapshot == nil ? "car.circle" : "switch.2",
                style: .primary,
                size: .large
            ) {
                isShowingDataSources = true
            }
            .accessibilityLabel(displayedSnapshot == nil ? "Connect your vehicle" : "Manage vehicle data sources")
            .accessibilityHint("Tap to sign in with Kia Connect US or configure another vehicle data source")

            HStack(spacing: KiaDesign.Spacing.medium) {
                KiaButton(
                    "Refresh",
                    icon: "arrow.clockwise",
                    style: .secondary,
                    size: .medium
                ) {
                    reloadHomeState()
                    Task { await refreshGalaxyIfConfigured() }
                }

                KiaButton(
                    "OBDLink",
                    icon: "dot.radiowaves.left.and.right",
                    style: .secondary,
                    size: .medium
                ) {
                    isShowingOBDLink = true
                }
            }
        }
    }

    private func sourceRow(_ source: VehicleTelemetrySourceKind) -> some View {
        let snapshot = snapshots[source]
        let isSelected = displayedSnapshot?.source == source

        return HStack(spacing: KiaDesign.Spacing.medium) {
            Image(systemName: sourceIcon(source))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(source.isEnabled(in: preferences) ? KiaDesign.Colors.primary : KiaDesign.Colors.textTertiary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .font(KiaDesign.Typography.bodySmall)
                    .foregroundStyle(KiaDesign.Colors.textPrimary)

                Text(sourceDetail(source, snapshot))
                    .font(KiaDesign.Typography.caption)
                    .foregroundStyle(KiaDesign.Colors.textSecondary)
            }

            Spacer()

            if source == .obdLinkCX, let badge = obdConnectionBadge {
                statusBadge(badge.text, color: badge.color)
            } else if isSelected {
                statusBadge("Using", color: KiaDesign.Colors.success)
            } else if snapshot?.isFresh == true {
                statusBadge("Ready", color: KiaDesign.Colors.primary)
            } else if snapshot != nil {
                statusBadge("Stale", color: KiaDesign.Colors.warning)
            }
        }
        .padding(.vertical, KiaDesign.Spacing.xs)
    }

    private func metricBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: KiaDesign.Spacing.xs) {
            Text(title)
                .font(KiaDesign.Typography.caption)
                .foregroundStyle(KiaDesign.Colors.textSecondary)
            Text(value)
                .font(KiaDesign.Typography.title2)
                .foregroundStyle(KiaDesign.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: KiaDesign.Spacing.xs) {
            Text(title)
                .font(KiaDesign.Typography.caption)
                .foregroundStyle(KiaDesign.Colors.textSecondary)
            Text(value)
                .font(KiaDesign.Typography.bodySmall)
                .foregroundStyle(KiaDesign.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(KiaDesign.Typography.caption)
            .foregroundStyle(color)
            .padding(.horizontal, KiaDesign.Spacing.small)
            .padding(.vertical, KiaDesign.Spacing.xs)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var displayedSnapshot: VehicleTelemetrySnapshot? {
        VehicleTelemetryCache.bestAvailable(preferences: preferences) ?? snapshots.values
            .filter { $0.hasVisibleTelemetry }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    private var measurementSystem: VehicleProfileMeasurementSystem {
        VehicleProfileMeasurementSystem(rawValue: measurementSystemRaw) ?? .us
    }

    private var vehicleTitle: String {
        displayedSnapshot?.vehicleName ?? vehicleProfile.displayName
    }

    private var headerSubtitle: String {
        if let snapshot = displayedSnapshot {
            return snapshot.isFresh ? "Connected through \(snapshot.source.displayName)" : "Last updated \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Ready for Apple Maps EV routing setup"
    }

    private func chargingSummary(for snapshot: VehicleTelemetrySnapshot) -> String {
        if let power = snapshot.chargingPowerKilowatts, power > 0 {
            return "\(power.formatted(.number.precision(.fractionLength(1)))) kW"
        }
        if snapshot.isCharging == true {
            return "Charging"
        }
        if snapshot.isPluggedIn == true {
            return "Plugged in"
        }
        return "Idle"
    }

    private func sourceDetail(_ source: VehicleTelemetrySourceKind, _ snapshot: VehicleTelemetrySnapshot?) -> String {
        if source == .obdLinkCX {
            let connection = obdManager.state.title
            guard let snapshot else {
                return connection
            }
            let telemetry = sourceTelemetryDetail(snapshot)
            return telemetry.isEmpty ? connection : "\(connection) · \(telemetry)"
        }

        return sourceTelemetryDetail(snapshot)
    }

    private func sourceTelemetryDetail(_ snapshot: VehicleTelemetrySnapshot?) -> String {
        guard let snapshot else {
            return "No cached data"
        }

        let battery = snapshot.stateOfChargePercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" }
        let range = rangeSummary(for: snapshot)
        let updated = snapshot.updatedAt.formatted(date: .omitted, time: .shortened)

        return [battery, range == "--" ? nil : range, updated].compactMap { $0 }.joined(separator: " · ")
    }

    private var obdConnectionBadge: (text: String, color: Color)? {
        switch obdManager.state {
        case .idle:
            return nil
        case .scanning:
            return ("Scanning", KiaDesign.Colors.primary)
        case .connecting:
            return ("Connecting", KiaDesign.Colors.primary)
        case .connected, .ready:
            return ("Connected", KiaDesign.Colors.success)
        case .failed:
            return ("Error", KiaDesign.Colors.warning)
        }
    }

    private func rangeSummary(for snapshot: VehicleTelemetrySnapshot) -> String {
        guard let kilometers = snapshot.distanceToEmptyKilometers ?? snapshot.estimatedRangeKilometers else {
            return "--"
        }
        return measurementSystem.formattedDistance(kilometers: kilometers)
    }

    private func sourceIcon(_ source: VehicleTelemetrySourceKind) -> String {
        switch source {
        case .obdLinkCX:
            return "dot.radiowaves.left.and.right"
        case .kiaConnectUSA:
            return "cloud"
        case .starPilotGalaxy:
            return "antenna.radiowaves.left.and.right"
        case .demo:
            return "testtube.2"
        }
    }

    private func reloadHomeState() {
        KiaConnectUSACredentialsCache.importStatusCache()
        preferences = VehicleDataSourcePreferencesCache.load()
        vehicleProfile = VehicleProfileStore.selected()
        snapshots = VehicleTelemetryCache.allLatest()
    }

    private func refreshGalaxyIfConfigured() async {
        if galaxyManager.credentials.isConfigured {
            await galaxyManager.refresh()
        } else {
            await galaxyManager.discoverAndConnectLocalGalaxy()
        }
        reloadHomeState()
    }
}

private extension VehicleTelemetrySourceKind {
    func isEnabled(in preferences: VehicleDataSourcePreferences) -> Bool {
        preferences.isEnabled(self)
    }
}

private extension VehicleTelemetrySnapshot {
    var hasVisibleTelemetry: Bool {
        stateOfChargePercent != nil || estimatedRangeKilometers != nil || distanceToEmptyKilometers != nil
    }
}

// MARK: - Preview

#Preview("Main Login View") {
    WelcomeView(onLogin: {
        print("Login tapped")
    })
}
