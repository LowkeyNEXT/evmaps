//
//  VehicleDataSourcesView.swift
//  KiaMaps
//
//  Data-source selection and connection UI for Apple Maps telemetry.
//

import SwiftUI

struct VehicleDataSourcesView: View {
    @State private var preferences = VehicleDataSourcePreferencesCache.load()
    @State private var vehicleProfile = VehicleProfileStore.selected()
    @AppStorage("vehicleProfile.measurementSystem") private var measurementSystemRaw = VehicleProfileMeasurementSystem.us.rawValue
    @State private var isShowingOBDLink = false
    @StateObject private var kiaConnectManager = KiaConnectUSAManager()
    @StateObject private var galaxyManager = GalaxyVehicleDataSourceManager()
    @State private var mfaCode = ""
    @State private var didAutoRefreshGalaxy = false
    @State private var mapsDebugLogs = MapsIntentDebugLog.latest()

    var body: some View {
        NavigationStack {
            List {
                vehicleConfigurationSection
                sourceSelectionSection
                sourceRateLimitSection
                currentMapsSourceSection
                mapsIntentDebugSection
                obdSection
                kiaConnectSection
                galaxySection
            }
            .navigationTitle("Data Sources")
            .sheet(isPresented: $isShowingOBDLink) {
                OBDLinkView()
            }
            .onReceive(NotificationCenter.default.publisher(for: .galaxyVehicleCredentialsDidImport)) { _ in
                galaxyManager.credentials = GalaxyVehicleCredentialsCache.load()
                Task { await galaxyManager.refresh() }
            }
            .task {
                mapsDebugLogs = MapsIntentDebugLog.latest()
                await autoRefreshGalaxyIfConfigured()
            }
        }
    }

    private var vehicleConfigurationSection: some View {
        SwiftUI.Section {
            Picker("Vehicle", selection: vehicleProfileSelectionBinding) {
                ForEach(VehicleProfile.presets) { profile in
                    Text(profile.displayName).tag(profile.id)
                }
                Text("Custom").tag("custom")
            }

            Picker("Units", selection: $measurementSystemRaw) {
                ForEach(VehicleProfileMeasurementSystem.allCases) { system in
                    Text(system.displayName).tag(system.rawValue)
                }
            }
            .pickerStyle(.segmented)

            TextField("Display name", text: profileStringBinding(\.displayName))
            HStack {
                TextField("Year", text: profileStringBinding(\.year))
                    .keyboardType(.numberPad)
                TextField("Make", text: profileStringBinding(\.make))
                    .textInputAutocapitalization(.words)
            }
            TextField("Model", text: profileStringBinding(\.model))
            TextField("Trim", text: profileStringBinding(\.trim))

            LabeledContent("Battery") {
                unitTextField(
                    placeholder: "99.8",
                    value: profileDoubleBinding(\.maximumBatteryCapacityKilowattHours),
                    unit: "kWh"
                )
            }

            LabeledContent("Max Range") {
                unitTextField(
                    placeholder: measurementSystem == .us ? "280" : "450.6",
                    value: rangeBinding,
                    unit: measurementSystem.distanceUnitLabel
                )
            }

            ForEach(VehicleChargingConnector.allCases) { connector in
                Toggle(isOn: connectorEnabledBinding(connector)) {
                    HStack {
                        Text(connector.displayName)
                        Spacer()
                        if connectorEnabled(connector) {
                            unitTextField(
                                placeholder: "210",
                                value: connectorPowerBinding(connector),
                                unit: "kW",
                                width: 116
                            )
                        }
                    }
                }
            }
        } header: {
            Text("Vehicle")
        } footer: {
            Text("These values are advertised to Apple Maps for EV routing. The 2026 EV9 GT-Line USA preset uses a 99.8 kWh pack, 280 mi / 450.6 km EPA range, NACS, and adapter-compatible J1772/CCS1 charging.")
        }
    }

    private var sourceSelectionSection: some View {
        SwiftUI.Section {
            Picker("Mode", selection: modeBinding) {
                ForEach(VehicleTelemetrySelectionMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Picker("Preferred", selection: preferredSourceBinding) {
                ForEach(VehicleTelemetrySourceKind.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }

            ForEach(VehicleTelemetrySourceKind.allCases) { source in
                Toggle(source.displayName, isOn: enabledBinding(for: source))
            }
        } header: {
            Text("Selection")
        } footer: {
            Text("Smart choose uses the preferred source first, then falls back to the next enabled source with fresh battery or range data.")
        }
    }

    private var sourceRateLimitSection: some View {
        SwiftUI.Section {
            ForEach(VehicleTelemetrySourceKind.allCases) { source in
                Stepper(value: refreshLimitMinutesBinding(for: source), in: 1...120, step: 1) {
                    LabeledContent(source.displayName) {
                        Text("\(Int(refreshLimitMinutes(for: source))) min")
                            .monospacedDigit()
                    }
                }
            }
        } header: {
            Text("Refresh Limits")
        } footer: {
            Text("Maps can ask for data while planning a route. These limits throttle active source refreshes; cached values are still returned with their original update time.")
        }
    }

    private var currentMapsSourceSection: some View {
        SwiftUI.Section {
            if let snapshot = VehicleTelemetryCache.bestAvailable(preferences: preferences) {
                LabeledContent("Source", value: snapshot.source.displayName)
                LabeledContent("Updated", value: snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Vehicle", value: snapshot.vehicleName ?? "EV9")
                LabeledContent("VIN", value: snapshot.vin ?? "Not available")
                LabeledContent("Battery") {
                    if let percent = snapshot.stateOfChargePercent {
                        Text("\(percent, specifier: "%.0f")%")
                    } else {
                        Text("Not available")
                    }
                }
                LabeledContent("Range") {
                    if let range = snapshot.estimatedRangeKilometers {
                        Text(measurementSystem.formattedDistance(kilometers: range))
                    } else {
                        Text("Not available")
                    }
                }
                LabeledContent("DTE") {
                    if let dte = snapshot.distanceToEmptyKilometers {
                        Text(measurementSystem.formattedDistance(kilometers: dte))
                    } else {
                        Text("Using range estimate")
                    }
                }
                LabeledContent("Plug") {
                    Text(snapshot.plugPowerType ?? snapshot.activeConnector ?? "Not available")
                }
                LabeledContent("Charge Limit") {
                    if let limit = snapshot.chargeLimitPercent {
                        Text("\(limit, specifier: "%.0f")%")
                    } else {
                        Text("Not available")
                    }
                }
            } else {
                Text("No fresh source is available yet.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Maps Data")
        }
    }

    private var mapsIntentDebugSection: some View {
        SwiftUI.Section {
            HStack {
                Button {
                    mapsDebugLogs = MapsIntentDebugLog.latest()
                } label: {
                    Label("Refresh Logs", systemImage: "arrow.clockwise")
                }

                Spacer()

                Button(role: .destructive) {
                    MapsIntentDebugLog.clear()
                    mapsDebugLogs = []
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }

            if mapsDebugLogs.isEmpty {
                Text("No Maps requests have been recorded yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mapsDebugLogs.suffix(12).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.event)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Maps Debug")
        } footer: {
            Text("Shows the last Apple Maps intent requests and the data source returned by the extension.")
        }
    }

    private var obdSection: some View {
        SwiftUI.Section {
            Button {
                isShowingOBDLink = true
            } label: {
                Label("Pair or Refresh OBDLink", systemImage: "dot.radiowaves.left.and.right")
            }

            if let telemetry = VehicleTelemetryCache.latest(for: .obdLinkCX) {
                LabeledContent("Last Adapter", value: telemetry.adapterName ?? "OBDLink CX")
                LabeledContent("Last OBD Read", value: telemetry.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
        } header: {
            Text("OBDLink CX")
        } footer: {
            Text("Use this with the OBDLink CX plugged into the EV9 OBD port. The app reads standard OBD SOC when available and probes Hyundai/Kia BMS PIDs for EV data.")
        }
    }

    private var kiaConnectSection: some View {
        SwiftUI.Section {
            HStack {
                Label(kiaConnectStatusTitle, systemImage: kiaConnectStatusSymbol)
                    .foregroundStyle(kiaConnectStatusColor)

                Spacer()

                if kiaConnectManager.isLoading {
                    ProgressView()
                }
            }

            if kiaConnectManager.credentials.hasStoredCredentials {
                LabeledContent("Account", value: kiaConnectManager.credentials.redactedUsername)
                if kiaConnectManager.credentials.authSession?.isValid == true {
                    LabeledContent("Session", value: "Active")
                } else if kiaConnectManager.credentials.hasStoredSession {
                    LabeledContent("Session", value: "Saved")
                }
            }

            TextField("Email", text: $kiaConnectManager.credentials.username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()

            SecureField("Password", text: $kiaConnectManager.credentials.password)
                .textContentType(.password)

            Button {
                kiaConnectManager.reloadSharedCredentials()
            } label: {
                Label("Use Shared Account", systemImage: "key.horizontal.fill")
            }
            .disabled(kiaConnectManager.isLoading)

            Button {
                Task { await kiaConnectManager.refresh(cached: true) }
            } label: {
                Label(kiaConnectManager.credentials.hasStoredCredentials ? "Refresh Status" : "Sign In", systemImage: "arrow.clockwise")
            }
            .disabled(kiaConnectManager.isLoading || !kiaConnectManager.credentials.isReadyForLogin)

            if kiaConnectManager.credentials.hasStoredCredentials {
                Button(role: .destructive) {
                    kiaConnectManager.clearCredentials()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(kiaConnectManager.isLoading)
            }

            if !kiaConnectManager.credentials.hasStoredCredentials {
                Text("Sign in here or use shared credentials from Galaxy Nav.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Kia Maps and Galaxy Nav can share this Kia Connect account through the local keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let challenge = kiaConnectManager.mfaChallenge {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Verification required")
                        .font(.headline)

                    HStack {
                        if challenge.hasEmail {
                            Button("Send Email") {
                                Task { await kiaConnectManager.sendMFACode(method: "email") }
                            }
                        }

                        if challenge.hasPhone {
                            Button("Send SMS") {
                                Task { await kiaConnectManager.sendMFACode(method: "sms") }
                            }
                        }
                    }

                    if let email = challenge.email {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let phone = challenge.phone {
                        Text(phone)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Verification code", text: $mfaCode)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)

                    Button("Verify Code") {
                        Task { await kiaConnectManager.verifyMFACode(mfaCode) }
                    }
                    .disabled(kiaConnectManager.isLoading)
                }
            }

            Text(kiaConnectManager.statusMessage)
                .foregroundStyle(.secondary)

            if !kiaConnectManager.vehicles.isEmpty {
                Picker("Vehicle", selection: selectedVINBinding) {
                    ForEach(kiaConnectManager.vehicles) { vehicle in
                        Text("\(vehicle.model) \(vehicle.vin.suffix(6))").tag(Optional(vehicle.vin))
                    }
                }
            }
        } header: {
            Text("Kia Connect US")
        } footer: {
            Text("Kia Connect uses BetterBlueKit and cached status by default. Real-time refresh can wake the car, so this app avoids polling it automatically.")
        }
    }

    private var kiaConnectStatusTitle: String {
        if kiaConnectManager.credentials.authSession?.isValid == true {
            return "Signed in"
        }
        if kiaConnectManager.credentials.hasStoredSession {
            return "Shared account available"
        }
        if kiaConnectManager.credentials.isReadyForLogin {
            return "Ready to sign in"
        }
        return "Not connected"
    }

    private var kiaConnectStatusSymbol: String {
        if kiaConnectManager.credentials.authSession?.isValid == true {
            return "checkmark.circle.fill"
        }
        if kiaConnectManager.credentials.hasStoredSession || kiaConnectManager.credentials.isReadyForLogin {
            return "key.fill"
        }
        return "exclamationmark.circle"
    }

    private var kiaConnectStatusColor: Color {
        if kiaConnectManager.credentials.authSession?.isValid == true {
            return .green
        }
        if kiaConnectManager.credentials.hasStoredSession || kiaConnectManager.credentials.isReadyForLogin {
            return .blue
        }
        return .secondary
    }

    private var galaxySection: some View {
        SwiftUI.Section {
            TextField("Portal URL", text: $galaxyManager.credentials.baseURLString)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()

            TextField("LAN URL", text: $galaxyManager.credentials.localBaseURLString)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()

            TextField("Cookie name", text: $galaxyManager.credentials.cookieName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("App key / session token", text: $galaxyManager.credentials.sessionToken)
                .textContentType(.password)

            HStack {
                Button {
                    Task { await galaxyManager.refresh() }
                } label: {
                    Label("Connect / Refresh", systemImage: "network")
                }
                .disabled(galaxyManager.isLoading)

                Spacer()

                if galaxyManager.isLoading {
                    ProgressView()
                }
            }

            Text(galaxyManager.statusMessage)
                .foregroundStyle(.secondary)

            if let telemetry = VehicleTelemetryCache.latest(for: .starPilotGalaxy) {
                LabeledContent("Last Galaxy Read", value: telemetry.updatedAt.formatted(date: .abbreviated, time: .shortened))
                if let percent = telemetry.stateOfChargePercent {
                    LabeledContent("Battery", value: "\(percent.formatted(.number.precision(.fractionLength(0))))%")
                }
                if let power = telemetry.chargingPowerKilowatts {
                    LabeledContent("Charge Power", value: "\(power.formatted(.number.precision(.fractionLength(1)))) kW")
                }
                if let minutes = telemetry.minutesToFull {
                    LabeledContent("Full In", value: "\(minutes) min")
                }
            }

            Button(role: .destructive) {
                galaxyManager.clearCredentials()
            } label: {
                Label("Remove Galaxy Settings", systemImage: "trash")
            }
        } header: {
            Text("StarPilot Galaxy")
        } footer: {
            Text("Use Open KiaMaps or the pairing code from the StarPilot Galaxy screen. If a LAN URL is set, KiaMaps tries it before the public Galaxy portal.")
        }
    }

    private var modeBinding: Binding<VehicleTelemetrySelectionMode> {
        Binding {
            preferences.selectionMode
        } set: { newValue in
            preferences.selectionMode = newValue
            savePreferences()
        }
    }

    private var preferredSourceBinding: Binding<VehicleTelemetrySourceKind> {
        Binding {
            preferences.preferredSource
        } set: { newValue in
            preferences.preferredSource = newValue
            savePreferences()
        }
    }

    private var selectedVINBinding: Binding<String?> {
        Binding {
            kiaConnectManager.credentials.selectedVIN
        } set: { newValue in
            kiaConnectManager.credentials.selectedVIN = newValue
            kiaConnectManager.saveCredentials()
        }
    }

    private func enabledBinding(for source: VehicleTelemetrySourceKind) -> Binding<Bool> {
        Binding {
            preferences.isEnabled(source)
        } set: { newValue in
            preferences.setEnabled(source, isEnabled: newValue)
            savePreferences()
        }
    }

    private func refreshLimitMinutes(for source: VehicleTelemetrySourceKind) -> Double {
        preferences.minimumRefreshInterval(for: source) / 60
    }

    private func refreshLimitMinutesBinding(for source: VehicleTelemetrySourceKind) -> Binding<Double> {
        Binding {
            refreshLimitMinutes(for: source)
        } set: { newValue in
            preferences.setMinimumRefreshInterval(newValue * 60, for: source)
            savePreferences()
        }
    }

    private func savePreferences() {
        VehicleDataSourcePreferencesCache.store(preferences)
    }

    private var vehicleProfileSelectionBinding: Binding<String> {
        Binding {
            VehicleProfile.presets.contains { $0.id == vehicleProfile.id } ? vehicleProfile.id : "custom"
        } set: { newValue in
            if let preset = VehicleProfile.presets.first(where: { $0.id == newValue }) {
                vehicleProfile = preset
            } else {
                vehicleProfile.id = "custom"
            }
            saveVehicleProfile()
        }
    }

    private func profileStringBinding(_ keyPath: WritableKeyPath<VehicleProfile, String>) -> Binding<String> {
        Binding {
            vehicleProfile[keyPath: keyPath]
        } set: { newValue in
            vehicleProfile[keyPath: keyPath] = newValue
            markVehicleProfileCustomIfNeeded()
            saveVehicleProfile()
        }
    }

    private func profileDoubleBinding(_ keyPath: WritableKeyPath<VehicleProfile, Double>) -> Binding<Double> {
        Binding {
            vehicleProfile[keyPath: keyPath]
        } set: { newValue in
            vehicleProfile[keyPath: keyPath] = newValue
            markVehicleProfileCustomIfNeeded()
            saveVehicleProfile()
        }
    }

    private func unitTextField(
        placeholder: String,
        value: Binding<Double>,
        unit: String,
        width: CGFloat = 132
    ) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, value: value, format: .number.precision(.fractionLength(1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
            Text(unit)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(width: width)
    }

    private var measurementSystem: VehicleProfileMeasurementSystem {
        VehicleProfileMeasurementSystem(rawValue: measurementSystemRaw) ?? .us
    }

    private var rangeBinding: Binding<Double> {
        Binding {
            measurementSystem.displayDistance(kilometers: vehicleProfile.maximumDistanceKilometers)
        } set: { newValue in
            vehicleProfile.maximumDistanceKilometers = measurementSystem.kilometers(displayDistance: newValue)
            markVehicleProfileCustomIfNeeded()
            saveVehicleProfile()
        }
    }

    private func connectorEnabled(_ connector: VehicleChargingConnector) -> Bool {
        vehicleProfile.connectors.contains { $0.connector == connector }
    }

    private func connectorEnabledBinding(_ connector: VehicleChargingConnector) -> Binding<Bool> {
        Binding {
            connectorEnabled(connector)
        } set: { isEnabled in
            if isEnabled {
                if !connectorEnabled(connector) {
                    vehicleProfile.connectors.append(
                        .init(connector: connector, maximumPowerKilowatts: defaultPower(for: connector))
                    )
                }
            } else {
                vehicleProfile.connectors.removeAll { $0.connector == connector }
            }
            markVehicleProfileCustomIfNeeded()
            saveVehicleProfile()
        }
    }

    private func connectorPowerBinding(_ connector: VehicleChargingConnector) -> Binding<Double> {
        Binding {
            vehicleProfile.connectors.first { $0.connector == connector }?.maximumPowerKilowatts ?? defaultPower(for: connector)
        } set: { newValue in
            if let index = vehicleProfile.connectors.firstIndex(where: { $0.connector == connector }) {
                vehicleProfile.connectors[index].maximumPowerKilowatts = newValue
            } else {
                vehicleProfile.connectors.append(.init(connector: connector, maximumPowerKilowatts: newValue))
            }
            markVehicleProfileCustomIfNeeded()
            saveVehicleProfile()
        }
    }

    private func defaultPower(for connector: VehicleChargingConnector) -> Double {
        switch connector {
        case .nacsAC, .j1772, .mennekes:
            return 10.9
        case .nacsDC, .ccs1, .ccs2:
            return 210
        case .chaDeMo:
            return 50
        }
    }

    private func markVehicleProfileCustomIfNeeded() {
        if VehicleProfile.presets.contains(where: { $0 == vehicleProfile }) {
            return
        }
        vehicleProfile.id = "custom"
    }

    private func saveVehicleProfile() {
        VehicleProfileStore.store(vehicleProfile)
    }

    private func autoRefreshGalaxyIfConfigured() async {
        guard !didAutoRefreshGalaxy, galaxyManager.credentials.isConfigured else {
            return
        }
        didAutoRefreshGalaxy = true
        guard VehicleTelemetryCache.shouldRefresh(.starPilotGalaxy, preferences: preferences) else {
            return
        }
        await galaxyManager.refresh()
    }
}

enum VehicleProfileMeasurementSystem: String, CaseIterable, Identifiable {
    case us
    case metric

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .us:
            return "US"
        case .metric:
            return "Metric"
        }
    }

    var distanceUnitLabel: String {
        switch self {
        case .us:
            return "mi"
        case .metric:
            return "km"
        }
    }

    func displayDistance(kilometers: Double) -> Double {
        switch self {
        case .us:
            return kilometers / 1.609344
        case .metric:
            return kilometers
        }
    }

    func kilometers(displayDistance: Double) -> Double {
        switch self {
        case .us:
            return displayDistance * 1.609344
        case .metric:
            return displayDistance
        }
    }

    func formattedDistance(kilometers: Double) -> String {
        let value = displayDistance(kilometers: kilometers)
        return "\(value.formatted(.number.precision(.fractionLength(0)))) \(distanceUnitLabel)"
    }
}
