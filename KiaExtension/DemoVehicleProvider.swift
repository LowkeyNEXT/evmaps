//
//  DemoVehicleProvider.swift
//  KiaMaps
//
//  Debug-only vehicle data for exercising Apple Maps integration without a
//  connected OEM account.
//

import Foundation
import Intents
import UIKit

#if DEBUG
enum DemoVehicleProvider {
    static let vehicleID = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!

    static func isDemoCar(_ id: UUID) -> Bool {
        id == vehicleID
    }

    static func car() -> INCar {
        let profile = VehicleProfileStore.selected()
        let vehicleParameters: VehicleParameters = profile

        let car = INCar(
            carIdentifier: vehicleID.uuidString,
            displayName: profile.displayName,
            year: profile.year,
            make: profile.make,
            model: profile.model,
            color: UIColor.systemGreen.cgColor,
            headUnit: INCar.HeadUnit(bluetoothIdentifier: nil, iAP2Identifier: nil),
            supportedChargingConnectors: vehicleParameters.supportedChargingConnectors
        )

        for connector in vehicleParameters.supportedChargingConnectors {
            guard let power = vehicleParameters.maximumPower(for: connector) else {
                continue
            }
            car.setMaximumPower(Measurement(value: power, unit: UnitPower.kilowatts), for: connector)
        }

        VehicleManager(id: vehicleID).store(type: "Kia-EV9")
        return car
    }

    static func powerLevelResponse() -> INGetCarPowerLevelStatusIntentResponse {
        if let telemetry = VehicleTelemetryCache.bestAvailable() {
            MapsIntentDebugLog.append(event: "Demo response from cache", detail: telemetry.mapsDebugSummary)
            return powerLevelResponse(from: telemetry)
        }

        MapsIntentDebugLog.append(event: "Demo response fallback", detail: "No fresh shared telemetry; returning chargingPreview")
        return VehicleStateResponse.chargingPreview.state.toIntentResponse(
            carId: vehicleID,
            vehicleParameters: VehicleProfileStore.selected(),
            lastUpdateDate: Date()
        )
    }

    static func refreshedPowerLevelResponse() async -> INGetCarPowerLevelStatusIntentResponse {
        let preferences = VehicleDataSourcePreferencesCache.load()
        if !VehicleTelemetryCache.shouldRefresh(.starPilotGalaxy, preferences: preferences),
           let telemetry = VehicleTelemetryCache.bestStored(preferences: preferences) {
            MapsIntentDebugLog.append(event: "Galaxy refresh throttled", detail: telemetry.mapsDebugSummary)
            return powerLevelResponse(from: telemetry)
        }

        do {
            let telemetry = try await SharedGalaxyTelemetryClient.refreshStoredTelemetry()
            MapsIntentDebugLog.append(event: "Demo response from Galaxy refresh", detail: telemetry.mapsDebugSummary)
            return powerLevelResponse(from: telemetry)
        } catch {
            MapsIntentDebugLog.append(event: "Galaxy refresh unavailable", detail: error.localizedDescription)
            return powerLevelResponse()
        }
    }

    private static func powerLevelResponse(from telemetry: OBDTelemetry) -> INGetCarPowerLevelStatusIntentResponse {
        let vehicleParameters = VehicleProfileStore.selected()
        let batteryPercent = telemetry.stateOfChargePercent ?? 65
        let range = telemetry.estimatedRangeKilometers ?? vehicleParameters.maximumDistance * (batteryPercent / 100.0)
        let maximumBatteryCapacity = Measurement(value: vehicleParameters.maximumBatteryCapacityKilowattHours, unit: UnitEnergy.kilowattHours)
        let currentBatteryCapacity = Measurement(value: maximumBatteryCapacity.value * batteryPercent / 100.0, unit: UnitEnergy.kilowattHours)
        let dateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: telemetry.updatedAt)

        let result = INGetCarPowerLevelStatusIntentResponse(code: .success, userActivity: nil)
        result.carIdentifier = vehicleID.uuidString
        result.dateOfLastStateUpdate = dateComponents
        result.consumptionFormulaArguments = vehicleParameters.consumptionFormulaArguments()
        result.chargingFormulaArguments = vehicleParameters.chargingFormulaArguments(maximumBatteryCapacity: maximumBatteryCapacity.value, unit: .kilowattHours)
        result.maximumDistance = Measurement(value: vehicleParameters.maximumDistance, unit: UnitLength.kilometers)
        result.distanceRemaining = Measurement(value: range, unit: UnitLength.kilometers)
        result.maximumDistanceElectric = Measurement(value: vehicleParameters.maximumDistance, unit: UnitLength.kilometers)
        result.distanceRemainingElectric = Measurement(value: range, unit: UnitLength.kilometers)
        result.minimumBatteryCapacity = Measurement(value: 0, unit: UnitEnergy.kilowattHours)
        result.currentBatteryCapacity = currentBatteryCapacity
        result.maximumBatteryCapacity = maximumBatteryCapacity
        result.chargePercentRemaining = Float(batteryPercent / 100.0)
        result.charging = false
        result.activeConnector = nil
        result.minutesToFull = nil
        return result
    }

    private static func powerLevelResponse(from telemetry: VehicleTelemetrySnapshot) -> INGetCarPowerLevelStatusIntentResponse {
        let vehicleParameters = VehicleProfileStore.selected()
        let batteryPercent = telemetry.stateOfChargePercent ?? 65
        let range = telemetry.estimatedRangeKilometers ?? vehicleParameters.maximumDistance * (batteryPercent / 100.0)
        let maximumBatteryCapacity = Measurement(value: telemetry.maximumBatteryCapacityKilowattHours ?? vehicleParameters.maximumBatteryCapacityKilowattHours, unit: UnitEnergy.kilowattHours)
        let currentBatteryCapacity = Measurement(value: maximumBatteryCapacity.value * batteryPercent / 100.0, unit: UnitEnergy.kilowattHours)
        let dateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: telemetry.updatedAt)

        let result = INGetCarPowerLevelStatusIntentResponse(code: .success, userActivity: nil)
        result.carIdentifier = vehicleID.uuidString
        result.dateOfLastStateUpdate = dateComponents
        result.consumptionFormulaArguments = vehicleParameters.consumptionFormulaArguments()
        result.chargingFormulaArguments = vehicleParameters.chargingFormulaArguments(maximumBatteryCapacity: maximumBatteryCapacity.value, unit: .kilowattHours)
        result.maximumDistance = Measurement(value: vehicleParameters.maximumDistance, unit: UnitLength.kilometers)
        result.distanceRemaining = Measurement(value: range, unit: UnitLength.kilometers)
        result.maximumDistanceElectric = Measurement(value: vehicleParameters.maximumDistance, unit: UnitLength.kilometers)
        result.distanceRemainingElectric = Measurement(value: range, unit: UnitLength.kilometers)
        result.minimumBatteryCapacity = Measurement(value: 0, unit: UnitEnergy.kilowattHours)
        result.currentBatteryCapacity = currentBatteryCapacity
        result.maximumBatteryCapacity = maximumBatteryCapacity
        result.chargePercentRemaining = Float(batteryPercent / 100.0)
        result.charging = telemetry.isCharging ?? false
        result.activeConnector = activeConnector(from: telemetry, vehicleParameters: vehicleParameters)
        result.minutesToFull = telemetry.minutesToFull ?? estimatedMinutesToFull(
            batteryPercent: batteryPercent,
            maximumBatteryCapacityKilowattHours: maximumBatteryCapacity.value,
            chargingPowerKilowatts: telemetry.chargingPowerKilowatts
        )
        MapsIntentDebugLog.append(event: "Maps power response", detail: responseSummary(result, source: telemetry.source.displayName))
        return result
    }

    private static func estimatedMinutesToFull(
        batteryPercent: Double,
        maximumBatteryCapacityKilowattHours: Double,
        chargingPowerKilowatts: Double?
    ) -> Int? {
        guard let chargingPowerKilowatts, chargingPowerKilowatts > 0.1 else {
            return nil
        }
        let remainingKilowattHours = max(0, maximumBatteryCapacityKilowattHours * (100 - batteryPercent) / 100)
        return Int((remainingKilowattHours / chargingPowerKilowatts * 60).rounded())
    }

    private static func activeConnector(
        from telemetry: VehicleTelemetrySnapshot,
        vehicleParameters: VehicleParameters
    ) -> INCar.ChargingConnectorType? {
        guard telemetry.isCharging == true else {
            return nil
        }

        if let activeConnector = telemetry.activeConnector?.lowercased() {
            if #available(iOS 17.4, *) {
                if activeConnector.contains("nacsdc") || activeConnector.contains("nacs-dc") {
                    return .nacsDC
                }
                if activeConnector.contains("nacsac") || activeConnector.contains("nacs-ac") {
                    return .nacsAC
                }
            }
            if activeConnector.contains("ccs1") {
                return .ccs1
            }
            if activeConnector.contains("ccs2") {
                return .ccs2
            }
            if activeConnector.contains("j1772") {
                return .j1772
            }
        }

        if let power = telemetry.chargingPowerKilowatts, power > 25 {
            if #available(iOS 17.4, *), vehicleParameters.supportedChargingConnectors.contains(.nacsDC) {
                return .nacsDC
            }
            return vehicleParameters.supportedChargingConnectors.first { $0 == .ccs1 || $0 == .ccs2 }
        }

        if #available(iOS 17.4, *), vehicleParameters.supportedChargingConnectors.contains(.nacsAC) {
            return .nacsAC
        }
        return vehicleParameters.supportedChargingConnectors.first { $0 == .j1772 || $0 == .mennekes }
    }

    private static func responseSummary(_ response: INGetCarPowerLevelStatusIntentResponse, source: String) -> String {
        let percent = response.chargePercentRemaining.map { "\(Int(($0 * 100).rounded()))%" } ?? "nil"
        let range = response.distanceRemainingElectric?.converted(to: .kilometers).value
        let rangeText = range.map { "\(($0).formatted(.number.precision(.fractionLength(1)))) km" } ?? "nil"
        let charging = response.charging.map { String($0) } ?? "nil"
        let connector = response.activeConnector.map { String(describing: $0) } ?? "nil"
        let minutes = response.minutesToFull.map(String.init) ?? "nil"
        return "source=\(source), soc=\(percent), range=\(rangeText), charging=\(charging), connector=\(connector), minutesToFull=\(minutes)"
    }
}
#endif

extension VehicleTelemetrySnapshot {
    var mapsDebugSummary: String {
        let soc = stateOfChargePercent.map { "\($0.formatted(.number.precision(.fractionLength(1))))%" } ?? "nil"
        let range = estimatedRangeKilometers.map { "\($0.formatted(.number.precision(.fractionLength(1)))) km" } ?? "nil"
        let dte = distanceToEmptyKilometers.map { "\($0.formatted(.number.precision(.fractionLength(1)))) km" } ?? "nil"
        let charging = isCharging.map(String.init) ?? "nil"
        let plugged = isPluggedIn.map(String.init) ?? "nil"
        let power = chargingPowerKilowatts.map { "\($0.formatted(.number.precision(.fractionLength(1)))) kW" } ?? "nil"
        let connector = activeConnector ?? "nil"
        let plug = plugPowerType ?? "nil"
        let limit = chargeLimitPercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "nil"
        return "source=\(source.displayName), updated=\(updatedAt), soc=\(soc), range=\(range), dte=\(dte), charging=\(charging), plugged=\(plugged), power=\(power), connector=\(connector), plugPowerType=\(plug), chargeLimit=\(limit)"
    }
}
