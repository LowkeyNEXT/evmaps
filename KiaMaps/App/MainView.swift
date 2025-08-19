//
//  MainView.swift
//  KiaMaps
//
//  Created by Lukas Foldyna on 29.05.2024.
//  Copyright © 2024 Lukas Foldyna. All rights reserved.
//

import SwiftUI
import os.log
import Combine

struct MainView: View {
    let configuration: AppConfiguration.Type
    var api: Api
    
    @Environment(\.dismiss) private var dismiss

    enum ViewState {
        case loading
        case authorized
        case error(Error)
    }

    enum ViewError: Error {
        case noVehicles
        case vehicleNotFound(String)

        var description: String {
            switch self {
            case .noVehicles:
                return "No vehicles in account."
            case let .vehicleNotFound(vin):
                return "Vehicle with VIN \"\(vin)\" not found."
            }
        }
    }

    @State var state: ViewState
    @State var vehicles: [Vehicle] = []
    @State var selectedVehicle: Vehicle? = nil
    @State var selectedVehicleStatus: VehicleStatusResponse? = nil
    @State var isSelectedVahicleExpanded = true
    @State var lastUpdateDate: Date?
    @State var showingProfile = false
    @State var loginRetry = false
    
    // MQTT Integration State
    @StateObject private var mqttManager: MQTTManager
    @State private var currentVehicleStatus: VehicleStatus?
    @State private var mqttConnectionStatus: MQTTConnectionStatus = .disconnected
    @State private var receivedMQTTUpdate = false

    init(configuration: AppConfiguration.Type) {
        self.configuration = configuration
        let api = Api(configuration: configuration.apiConfiguration, rsaService: .init())
        self.api = api
        state = .loading

        self._mqttManager = StateObject(wrappedValue: MQTTManager(api: api))
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                MainLoadingView()
                    .task {
                        await loadData()
                    }
            case .authorized:
                contentView
                    .toolbar(content: {
                        ToolbarItem(id: "profile", placement: .topBarLeading) {
                            Button(action: {
                                showingProfile = true
                            }) {
                                Image(systemName: "person.circle")
                                    .font(.title2)
                                    .foregroundStyle(KiaDesign.Colors.primary)
                            }
                        }
                        
                        // Enhanced vehicle status in toolbar when vehicle is selected
                        if selectedVehicle != nil, let selectedVehicleStatus = selectedVehicleStatus {
                            ToolbarItem(placement: .topBarTrailing) {
                                vehicleStatusIcons(status: selectedVehicleStatus)
                            }
                        }
                    })
            case let .error(error):
                MainErrorView(
                    error: error,
                    onRetry: {
                        Task {
                            state = .loading
                            await loadData()
                        }
                    },
                    onLogout: {
                        Task {
                            await logout()
                        }
                    }
                )
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(KiaDesign.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showingProfile) {
            UserProfileView(api: api, selectedVehicle: selectedVehicle)
        }
        .onAppear {
            setupMQTTIntegration()
        }
        .onChange(of: selectedVehicleStatus?.state.vehicle.isCharging) { _, isCharging in
            handleChargingStateChange(isCharging ?? false)
        }
        .onChange(of: mqttManager.connectionStatus) { _, connectionStatus in
            mqttConnectionStatus = connectionStatus
        }
        .onReceive(mqttManager.$vehicleStatus) { vehicleStatus in
            handleMQTTDataUpdate(vehicleStatus)
        }
    }


    // MARK: - Modern Tesla-Inspired Content View
    
    @ViewBuilder
    var contentView: some View {
        if let selectedVehicle = selectedVehicle, let selectedVehicleStatus = selectedVehicleStatus {
            // Use MQTT-updated status if available, otherwise use API status
            let currentStatus = currentVehicleStatus ?? selectedVehicleStatus.state.vehicle
            
            OverviewPageView(
                brandName: api.configuration.brandName,
                vehicle: selectedVehicle,
                status: currentStatus,
                lastUpdateTime: selectedVehicleStatus.lastUpdateTime,
                isActive: true,
                mqttConnectionStatus: mqttConnectionStatus,
                receivedMQTTUpdate: receivedMQTTUpdate
            ) {
                await refreshData()
            }
        } else {
            // Vehicle Selection (Pre-Authorization)
            VehicleSelectionView(vehicles: vehicles) {
                await refreshData()
            }
        }
    }
    
    // MARK: - Vehicle Status Icons (for toolbar)
    
    private func vehicleStatusIcons(status: VehicleStatusResponse) -> some View {
        HStack(spacing: KiaDesign.Spacing.small) {
            // Last update indicator
            VStack(spacing: 2) {
                Image(systemName: "clock.fill")
                    .font(.caption2)
                    .foregroundStyle(KiaDesign.Colors.textTertiary)
                
                Text(timeAgoString(from: status.lastUpdateTime))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(KiaDesign.Colors.textTertiary)
            }
            
            // Battery status
            let batteryLevel = status.state.vehicle.green.batteryManagement.batteryRemain.ratio
            VStack(spacing: 2) {
                if batteryLevel > 80 {
                    Image(systemName: "battery.100percent")
                        .font(.caption)
                        .foregroundStyle(KiaDesign.Colors.success)
                } else if batteryLevel < 20 {
                    Image(systemName: "battery.25")
                        .font(.caption)
                        .foregroundStyle(KiaDesign.Colors.warning)
                } else {
                    Image(systemName: "battery.75")
                        .font(.caption)
                        .foregroundStyle(KiaDesign.Colors.textSecondary)
                }
                
                Text("\(Int(batteryLevel))%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(KiaDesign.Colors.textSecondary)
            }
            
            // Charging status (if applicable)
            if status.state.vehicle.isCharging {
                VStack(spacing: 2) {
                    Image(systemName: "bolt.circle.fill")
                        .font(.caption)
                        .foregroundStyle(KiaDesign.Colors.charging)
                    
                    Text("Charging")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(KiaDesign.Colors.charging)
                }
            }
        }
        .padding(.horizontal, KiaDesign.Spacing.small)
        .padding(.vertical, 4)
        .background(
            Group {
                if #available(iOS 26.0, *) {
                    EmptyView()
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(KiaDesign.Colors.cardBackground)
                        .opacity(0.7)
                }
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Vehicle status: \(Int(status.state.vehicle.green.batteryManagement.batteryRemain.ratio))% battery, \(status.state.vehicle.drivingReady ? "ready" : "not ready"), updated \(timeAgoString(from: status.lastUpdateTime))")
    }
    
    // MARK: - Helper Views
    
    private func timeAgoString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    private var navigationTitle: String {
        switch state {
        case .authorized:
            if let vehicle = selectedVehicle {
                return vehicle.nickname
            }
            return api.configuration.name
        default:
            return api.configuration.name
        }
    }

    private func loadData() async {
        do {
            if let authorization = Authorization.authorization {
                api.authorization = authorization
            } else {
                // Try to restore login with stored credentials first
                if let storedCredentials = LoginCredentialManager.retrieveCredentials() {
                    let authorization = try await api.login(username: storedCredentials.username, password: storedCredentials.password)
                    Authorization.store(data: authorization)
                } else {
                    logoutAfterError()
                    return
                }
            }

            // let profile = try await api.profile()
            vehicles = try await api.vehiclesWithAutoRefresh().vehicles
            let selectedVehicle = vehicles.vehicle(with: configuration.vehicleVin) ?? vehicles.first

            guard !vehicles.isEmpty else {
                state = .error(ViewError.noVehicles)
                return
            }
            guard let vehicle = selectedVehicle else {
                state = .error(ViewError.vehicleNotFound(configuration.vehicleVin ?? "none"))
                return
            }
            self.selectedVehicle = vehicle
            SharedVehicleManager.shared.selectedVehicleVIN = vehicle.vin
            let manager = SharedVehicleManager.shared.manager(for: vehicle.vehicleId)
            manager.store(type: configuration.apiConfiguration.name + "-" + vehicle.detailInfo.saleCarmdlEnName)

            if let cachedVehicle = try? manager.vehicleStatus {
                selectedVehicleStatus = cachedVehicle
            } else {
                let vehicleStatus = try await api.vehicleCachedStatusWithAutoRefresh(vehicle.vehicleId)
                try manager.store(status: vehicleStatus)
                selectedVehicleStatus = vehicleStatus
            }

            state = .authorized
        } catch let error {
            if let error = error as? ApiError {
                switch (error, loginRetry) {
                case (.unauthorized, false):
                    guard let storedCredentials = LoginCredentialManager.retrieveCredentials() else {
                        logoutAfterError()
                        return
                    }
                    loginRetry = true

                    do {
                        let authorization = try await api.login(username: storedCredentials.username, password: storedCredentials.password)
                        Authorization.store(data: authorization)
                        
                        await loadData()
                    } catch {
                        logoutAfterError()
                        return
                    }
                case (.unauthorized, true):
                    logoutAfterError()
                case (.unexpectedStatusCode(400), false):
                    state = .authorized
                default:
                    state = .error(error)
                }
            } else {
                state = .error(error)
            }
        }
    }

    private func refreshData() async {
        do {
            guard let selectedVehicle = selectedVehicle, let selectedVehicleStatus = selectedVehicleStatus else { return }

            if let lastUpdateDate = lastUpdateDate {
                await loadData()
                if lastUpdateDate < selectedVehicleStatus.lastUpdateTime {
                    self.lastUpdateDate = nil
                    logDebug("Vehicle status updated", category: .ui)
                }
            } else {
                _ = try await api.refreshVehicleWithAutoRefresh(selectedVehicle.vehicleId)
                lastUpdateDate = selectedVehicleStatus.lastUpdateTime
            }
            let manager = SharedVehicleManager.shared.manager(for: selectedVehicle.vehicleId)
            manager.removeLastUpdateDate()
        } catch {
            state = .error(error)
        }
    }

    private func logout() async {
        try? await api.logoutWithAutoRefresh()
        Authorization.remove()
        
        // Clear stored login credentials
        LoginCredentialManager.clearCredentials()
        
        // Dismiss to return to root (login screen)
        dismiss()
    }

    private func logoutAfterError() {
        Authorization.remove()

        // Dismiss to return to root (login screen)
        dismiss()
    }
    
    // MARK: - MQTT Integration
    
    private func setupMQTTIntegration() {
        // Set up MQTT status monitoring
        mqttConnectionStatus = mqttManager.connectionStatus
        
        // Start MQTT if car is already charging
        if selectedVehicleStatus?.state.vehicle.isCharging == true {
            startMQTTCommunication()
        }
    }
    
    private func handleMQTTDataUpdate(_ vehicleStatus: VehicleMQTTStatusResponse?) {
        // Handle MQTT data updates here
        guard let vehicleStatus = vehicleStatus else { return }
        receivedMQTTUpdate = true

        if let status = selectedVehicleStatus {
            selectedVehicleStatus = .init(
                resultCode: status.resultCode,
                serviceNumber: status.serviceNumber,
                returnCode: status.returnCode,
                lastUpdateTime: vehicleStatus.lastUpdateTime,
                state: .init(vehicle: vehicleStatus.state.vehicle)
            )
        } else {
            selectedVehicleStatus = .init(
                resultCode: "S",
                serviceNumber: "0",
                returnCode: "0",
                lastUpdateTime: vehicleStatus.lastUpdateTime,
                state: .init(vehicle: vehicleStatus.state.vehicle)
            )
        }
    }
    
    private func handleChargingStateChange(_ isCharging: Bool) {
        if isCharging {
            startMQTTCommunication()
        } else {
            stopMQTTCommunication()
        }
    }
    
    private func startMQTTCommunication() {
        guard let selectedVehicle = selectedVehicle, mqttConnectionStatus == .disconnected else { return }
        
        Task {
            do {
                try await mqttManager.activateMQTTCommunication(for: selectedVehicle.vehicleId)
                await MainActor.run {
                    mqttConnectionStatus = mqttManager.connectionStatus
                }
            } catch {
                logError("Failed to start MQTT communication: \(error.localizedDescription)", category: .mqtt)
                await MainActor.run {
                    mqttConnectionStatus = .error
                }
            }
        }
    }
    
    private func stopMQTTCommunication() {
        mqttManager.disconnect()
        mqttConnectionStatus = .disconnected
        receivedMQTTUpdate = false
        currentVehicleStatus = nil // Reset to use API data
    }
}
