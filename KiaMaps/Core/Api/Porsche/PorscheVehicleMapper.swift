//
//  PorscheVehicleMapper.swift
//  KiaMaps
//
//  Created by Codex on 06.03.2026.
//

import Foundation

enum PorscheVehicleMapper {
    typealias JSONObject = [String: Any]

    static func map(summary: PorscheVehicleSummary) -> PorscheVehicleSnapshot {
        PorscheVehicleSnapshot(
            vin: summary.vin,
            batterySoc: summary.batterySoc ?? 0,
            rangeKm: summary.rangeKm ?? 0,
            charging: summary.charging ?? false,
            locked: summary.locked ?? false,
            latitude: summary.latitude,
            longitude: summary.longitude,
            odometerKm: summary.odometerKm ?? 0,
            climateActive: summary.climateActive ?? false,
            chargingPowerKw: summary.chargingPowerKw ?? 0,
            capabilities: .init(
                canLock: summary.capabilities?.canLock ?? false,
                canClimatise: summary.capabilities?.canClimatise ?? false,
                canCharge: summary.capabilities?.canCharge ?? false
            )
        )
    }

    static func mapVehicles(from payload: [JSONObject], now: Date = Date()) throws -> VehicleResponse {
        let vehicles = try payload.map { vehiclePayload in
            try decodeVehicle(json: [
                "vin": string("vin", from: vehiclePayload) ?? "",
                "type": vehicleTypeCode(from: vehiclePayload),
                "vehicleId": UUID.porscheVehicleID(for: string("vin", from: vehiclePayload) ?? "").uuidString,
                "vehicleName": vehicleName(from: vehiclePayload),
                "nickname": string("customName", from: vehiclePayload) ?? string("modelName", from: vehiclePayload) ?? "Porsche",
                "tmuNum": String((string("vin", from: vehiclePayload) ?? "").suffix(8)),
                "year": modelTypeValue("year", from: vehiclePayload) ?? String(Calendar.current.component(.year, from: now)),
                "regDate": MillisecondDateFormatter().string(from: now),
                "master": true,
                "carShare": 0,
                "personalFlag": "Y",
                "detailInfo": [
                    "bodyType": modelTypeValue("bodyType", from: vehiclePayload) ?? "Porsche",
                    "inColor": "",
                    "outColor": "",
                    "saleCarmdlCd": modelTypeValue("model", from: vehiclePayload) ?? "Porsche",
                    "saleCarmdlEnNm": string("modelName", from: vehiclePayload) ?? "Porsche",
                ],
                "protocolType": 1,
                "ccuCCS2ProtocolSupport": 1,
            ])
        }
        return VehicleResponse(vehicles: vehicles)
    }

    static func mapVehicleState(from payload: JSONObject, now: Date = Date()) throws -> VehicleStateResponse {
        let summary = mapSummary(from: payload)
        let snapshot = map(summary: summary)
        var json = try responseJSONTemplate()

        set(value: TimeIntervalDateFormatter().string(from: now), at: ["lastUpdateTime"], in: &json)
        set(value: TimeIntervalDateFormatter().string(from: now), at: ["state", "Vehicle", "Date"], in: &json)
        set(value: snapshot.batterySoc, at: ["state", "Vehicle", "Green", "BatteryManagement", "BatteryRemain", "Ratio"], in: &json)
        set(value: max(snapshot.batterySoc, 1) * 2_300, at: ["state", "Vehicle", "Green", "BatteryManagement", "BatteryRemain", "Value"], in: &json)
        set(value: snapshot.charging ? ChargeDoorStatus.open.rawValue : ChargeDoorStatus.closed.rawValue, at: ["state", "Vehicle", "Green", "ChargingDoor", "State"], in: &json)
        set(value: snapshot.charging ? 1 : 0, at: ["state", "Vehicle", "Green", "ChargingInformation", "ConnectorFastening", "State"], in: &json)
        set(value: snapshot.chargingPowerKw * 1_000, at: ["state", "Vehicle", "Green", "Electric", "SmartGrid", "RealTimePower"], in: &json)
        set(value: snapshot.climateActive ? 1 : 0, at: ["state", "Vehicle", "Cabin", "HVAC", "Row1", "Driver", "Blower", "SpeedLevel"], in: &json)
        set(value: String(format: "%.0fC", climateTargetTemperature(from: payload) ?? 22), at: ["state", "Vehicle", "Cabin", "HVAC", "Row1", "Driver", "Temperature", "Value"], in: &json)
        set(value: snapshot.odometerKm, at: ["state", "Vehicle", "Drivetrain", "Odometer"], in: &json)
        set(value: snapshot.rangeKm > 0 ? Int(snapshot.rangeKm.rounded()) : 0, at: ["state", "Vehicle", "Drivetrain", "FuelSystem", "DTE", "Total"], in: &json)
        set(value: snapshot.locked, at: ["state", "Vehicle", "Cabin", "Door", "Row1", "Driver", "Lock"], in: &json)
        set(value: snapshot.locked, at: ["state", "Vehicle", "Cabin", "Door", "Row1", "Passenger", "Lock"], in: &json)
        set(value: snapshot.locked, at: ["state", "Vehicle", "Cabin", "Door", "Row2", "Left", "Lock"], in: &json)
        set(value: snapshot.locked, at: ["state", "Vehicle", "Cabin", "Door", "Row2", "Right", "Lock"], in: &json)
        set(value: measurementBool("OPEN_STATE_DOOR_FRONT_LEFT", payload: payload), at: ["state", "Vehicle", "Cabin", "Door", "Row1", "Driver", "Open"], in: &json)
        set(value: measurementBool("OPEN_STATE_DOOR_FRONT_RIGHT", payload: payload), at: ["state", "Vehicle", "Cabin", "Door", "Row1", "Passenger", "Open"], in: &json)
        set(value: measurementBool("OPEN_STATE_DOOR_REAR_LEFT", payload: payload), at: ["state", "Vehicle", "Cabin", "Door", "Row2", "Left", "Open"], in: &json)
        set(value: measurementBool("OPEN_STATE_DOOR_REAR_RIGHT", payload: payload), at: ["state", "Vehicle", "Cabin", "Door", "Row2", "Right", "Open"], in: &json)
        set(value: measurementBool("OPEN_STATE_LID_REAR", payload: payload), at: ["state", "Vehicle", "Body", "Trunk", "Open"], in: &json)
        set(value: measurementBool("OPEN_STATE_LID_FRONT", payload: payload), at: ["state", "Vehicle", "Body", "Hood", "Open"], in: &json)

        if let latitude = snapshot.latitude, let longitude = snapshot.longitude {
            set(value: latitude, at: ["state", "Vehicle", "Location", "GeoCoord", "Latitude"], in: &json)
            set(value: longitude, at: ["state", "Vehicle", "Location", "GeoCoord", "Longitude"], in: &json)
        }
        if let heading = locationHeading(from: payload) {
            set(value: heading, at: ["state", "Vehicle", "Location", "Heading"], in: &json)
        }
        let locationDate = locationDateString(from: payload) ?? TimeIntervalDateFormatter().string(from: now)
        set(value: locationDate, at: ["state", "Vehicle", "Location", "Date"], in: &json)

        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        do {
            return try JSONDecoder().decode(VehicleStateResponse.self, from: data)
        } catch {
            throw PorscheApiError.decodingFailed(error.localizedDescription)
        }
    }

    static func mapSummary(from payload: JSONObject) -> PorscheVehicleSummary {
        let measurements = measurementDictionary(from: payload)
        let location = locationComponents(from: measurements["GPS_LOCATION"])
        let capabilities = PorscheVehicleSummary.Capabilities(
            canLock: commandEnabled("LOCK", payload: payload),
            canClimatise: commandEnabled("REMOTE_CLIMATIZER_START", payload: payload),
            canCharge: commandEnabled("DIRECT_CHARGING_START", payload: payload)
        )

        return PorscheVehicleSummary(
            vin: string("vin", from: payload) ?? "",
            displayName: string("customName", from: payload) ?? string("modelName", from: payload) ?? "Porsche",
            model: string("modelName", from: payload) ?? "Porsche",
            modelYear: Int(modelTypeValue("year", from: payload) ?? ""),
            batterySoc: number(["BATTERY_LEVEL", "percent"], in: measurements),
            rangeKm: number(["E_RANGE", "distance"], in: measurements) ?? number(["RANGE", "distance"], in: measurements),
            charging: chargingState(from: measurements),
            locked: bool(["LOCK_STATE_VEHICLE", "isLocked"], in: measurements),
            latitude: location?.latitude,
            longitude: location?.longitude,
            odometerKm: number(["MILEAGE", "kilometers"], in: measurements),
            climateActive: bool(["CLIMATIZER_STATE", "isOn"], in: measurements),
            chargingPowerKw: (number(["CHARGING_RATE", "chargingPower"], in: measurements) ?? 0) / 1_000,
            capabilities: capabilities
        )
    }

    static func commandBody(for request: PorscheCommandRequest) -> Data {
        let payload: JSONObject
        switch request {
        case .lock:
            payload = ["key": request.commandKey, "payload": ["spin": NSNull()]]
        case let .climateOn(_, temperatureC):
            payload = [
                "key": request.commandKey,
                "payload": [
                    "climateZonesEnabled": [
                        "frontLeft": false,
                        "frontRight": false,
                        "rearLeft": false,
                        "rearRight": false,
                    ],
                    "targetTemperature": temperatureC + 273.15,
                ],
            ]
        case .climateOff:
            payload = ["key": request.commandKey, "payload": [:]]
        case .startCharging, .stopCharging:
            payload = ["key": request.commandKey, "payload": ["spin": NSNull()]]
        }

        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private static func responseJSONTemplate() throws -> JSONObject {
        let data = try JSONEncoder().encode(MockVehicleData.standardResponse)
        guard let json = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw PorscheApiError.decodingFailed("invalid response template")
        }
        return json
    }

    private static func decodeVehicle(json: JSONObject) throws -> Vehicle {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return try JSONDecoder().decode(Vehicle.self, from: data)
    }

    private static func vehicleTypeCode(from payload: JSONObject) -> String {
        switch modelTypeValue("engine", from: payload) {
        case "PHEV":
            VehicleType.plugInHybrid.rawValue
        case "BEV":
            VehicleType.electric.rawValue
        default:
            VehicleType.internalCombustionEngine.rawValue
        }
    }

    private static func vehicleName(from payload: JSONObject) -> String {
        let modelName = string("modelName", from: payload) ?? "Porsche"
        if let modelVariant = modelTypeValue("model", from: payload), !modelVariant.isEmpty {
            return "\(modelName) \(modelVariant)"
        }
        return modelName
    }

    private static func climateTargetTemperature(from payload: JSONObject) -> Double? {
        let kelvin = number(["CLIMATIZER_STATE", "targetTemperature"], in: measurementDictionary(from: payload))
        guard let kelvin else { return nil }
        return kelvin - 273.15
    }

    private static func chargingState(from measurements: JSONObject) -> Bool {
        if let mode = string(["CHARGING_SUMMARY", "mode"], in: measurements), mode == "DIRECT" {
            return true
        }
        if let status = string(["BATTERY_CHARGING_STATE", "status"], in: measurements) {
            return ["CHARGING", "ON"].contains(status.uppercased())
        }
        return false
    }

    private static func locationDateString(from payload: JSONObject) -> String? {
        guard let value = string(["GPS_LOCATION", "lastModified"], in: measurementDictionary(from: payload)),
              let date = ISO8601DateFormatter().date(from: value)
        else {
            return nil
        }
        return TimeIntervalDateFormatter().string(from: date)
    }

    private static func locationHeading(from payload: JSONObject) -> Double? {
        number(["GPS_LOCATION", "direction"], in: measurementDictionary(from: payload))
    }

    private static func locationComponents(from value: Any?) -> (latitude: Double, longitude: Double)? {
        guard let dictionary = value as? JSONObject,
              let location = dictionary["location"] as? String
        else {
            return nil
        }
        let components = location.split(separator: ",").compactMap { Double($0) }
        guard components.count == 2 else {
            return nil
        }
        return (components[0], components[1])
    }

    private static func measurementDictionary(from payload: JSONObject) -> JSONObject {
        guard let measurements = payload["measurements"] as? [JSONObject] else {
            return [:]
        }

        var result: JSONObject = [:]
        for measurement in measurements {
            guard let key = measurement["key"] as? String else { continue }
            if let status = measurement["status"] as? JSONObject,
               let isEnabled = status["isEnabled"] as? Bool,
               !isEnabled {
                continue
            }
            result[key] = measurement["value"] ?? [:]
        }
        return result
    }

    private static func commandEnabled(_ key: String, payload: JSONObject) -> Bool? {
        guard let commands = payload["commands"] as? [JSONObject] else {
            return nil
        }
        return commands.first(where: { ($0["key"] as? String) == key })?["isEnabled"] as? Bool
    }

    private static func measurementBool(_ key: String, payload: JSONObject) -> Bool {
        bool([key, "isOpen"], in: measurementDictionary(from: payload)) ?? false
    }

    private static func modelTypeValue(_ key: String, from payload: JSONObject) -> String? {
        (payload["modelType"] as? JSONObject)?[key] as? String
    }

    private static func string(_ key: String, from payload: JSONObject) -> String? {
        payload[key] as? String
    }

    private static func string(_ path: [String], in payload: JSONObject) -> String? {
        value(at: path, in: payload) as? String
    }

    private static func number(_ path: [String], in payload: JSONObject) -> Double? {
        if let number = value(at: path, in: payload) as? Double {
            return number
        }
        if let number = value(at: path, in: payload) as? Int {
            return Double(number)
        }
        if let number = value(at: path, in: payload) as? NSNumber {
            return number.doubleValue
        }
        return nil
    }

    private static func bool(_ path: [String], in payload: JSONObject) -> Bool? {
        if let value = value(at: path, in: payload) as? Bool {
            return value
        }
        if let value = value(at: path, in: payload) as? Int {
            return value == 1
        }
        return nil
    }

    private static func value(at path: [String], in payload: JSONObject) -> Any? {
        var current: Any? = payload
        for key in path {
            current = (current as? JSONObject)?[key]
        }
        return current
    }

    private static func set(value: Any, at path: [String], in payload: inout JSONObject) {
        guard let first = path.first else { return }
        if path.count == 1 {
            payload[first] = value
            return
        }

        var child = payload[first] as? JSONObject ?? [:]
        set(value: value, at: Array(path.dropFirst()), in: &child)
        payload[first] = child
    }
}
