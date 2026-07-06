//
//  OBDLinkBLEManager.swift
//  KiaMaps
//
//  Minimal OBDLink CX-style BLE UART client for ELM/STN commands.
//

import CoreBluetooth
import Foundation

final class OBDLinkBLEManager: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case scanning
        case connecting(String)
        case connected(String)
        case ready(String)
        case failed(String)

        var title: String {
            switch self {
            case .idle:
                return "Idle"
            case .scanning:
                return "Scanning"
            case let .connecting(name):
                return "Connecting to \(name)"
            case let .connected(name):
                return "Connected to \(name)"
            case let .ready(name):
                return "Ready: \(name)"
            case let .failed(message):
                return "Failed: \(message)"
            }
        }
    }

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var latestTelemetry: OBDTelemetry?
    @Published private(set) var logLines: [String] = []

    private let serviceUUID = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    private let notifyUUID = CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB")
    private let writeUUID = CBUUID(string: "0000FFF2-0000-1000-8000-00805F9B34FB")

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var responseBuffer = ""
    private var pendingContinuation: CheckedContinuation<String, Never>?
    private var pendingCommand: String?

    func start() {
        appendLog("Starting Bluetooth scan")
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func disconnect() {
        if let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        notifyCharacteristic = nil
        writeCharacteristic = nil
        state = .idle
    }

    private func scanIfReady() {
        guard centralManager?.state == .poweredOn else { return }
        state = .scanning
        centralManager?.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])
        appendLog("Scanning for OBDLink BLE adapters")
    }

    private func initializeAdapter() async {
        let commands = [
            "ATZ",
            "ATE0",
            "ATL0",
            "ATS0",
            "ATH0",
            "ATCAF1",
            "ATSP0",
        ]

        for command in commands {
            _ = await send(command)
        }

        let adapterName = peripheral?.name ?? "OBDLink"
        let vinResponse = await send("0902")
        let supported0100 = await send("0100")
        let supported0120 = await send("0120")
        let supported0140 = await send("0140")
        let supported0160 = await send("0160")
        let socResponse = await send("015B")
        let egmpResponses = await readEGMPBMSProbeResponses()

        let vin = parseVIN(from: vinResponse)
        let soc = parseStateOfCharge(from: socResponse) ?? parseEGMPStateOfCharge(from: egmpResponses)
        let vehicleParameters = VehicleProfileStore.selected()
        let range = soc.map { vehicleParameters.maximumDistance * ($0 / 100.0) }
        var rawResponses = [
            "0902": vinResponse,
            "0100": supported0100,
            "0120": supported0120,
            "0140": supported0140,
            "0160": supported0160,
            "015B": socResponse,
        ]
        egmpResponses.forEach { rawResponses[$0.key] = $0.value }

        let telemetry = OBDTelemetry(
            updatedAt: Date(),
            adapterName: adapterName,
            vin: vin,
            stateOfChargePercent: soc,
            estimatedRangeKilometers: range,
            rawResponses: rawResponses
        )

        latestTelemetry = telemetry
        VehicleTelemetryCache.store(
            VehicleTelemetrySnapshot(
                source: .obdLinkCX,
                updatedAt: telemetry.updatedAt,
                adapterName: telemetry.adapterName,
                vehicleName: vin.map { "EV9 \($0)" },
                vin: vin,
                stateOfChargePercent: soc,
                estimatedRangeKilometers: range,
                isCharging: nil,
                isPluggedIn: nil,
                chargingPowerKilowatts: nil,
                minutesToFull: nil,
                maximumBatteryCapacityKilowattHours: nil,
                activeConnector: nil,
                distanceToEmptyKilometers: range,
                plugPowerType: nil,
                chargeLimitPercent: nil,
                rawValues: rawResponses
            )
        )
        state = .ready(adapterName)
        appendLog("Cached OBD telemetry: VIN \(vin ?? "unknown"), SOC \(soc.map { "\(Int($0))%" } ?? "not available")")
    }

    private func readEGMPBMSProbeResponses() async -> [String: String] {
        _ = await send("ATSH7E4")
        let bms0101 = await send("220101")
        let bms0105 = await send("220105")
        _ = await send("ATSH7DF")

        return [
            "7E4 220101": bms0101,
            "7E4 220105": bms0105,
        ]
    }

    private func send(_ command: String) async -> String {
        guard let peripheral, let writeCharacteristic else {
            return ""
        }

        return await withCheckedContinuation { continuation in
            pendingCommand = command
            pendingContinuation = continuation
            responseBuffer = ""

            appendLog("> \(command)")
            let payload = Data((command + "\r").utf8)
            peripheral.writeValue(payload, for: writeCharacteristic, type: .withResponse)
        }
    }

    private func completePendingCommandIfNeeded() {
        guard responseBuffer.contains(">"), let continuation = pendingContinuation else {
            return
        }

        let response = responseBuffer
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        appendLog("< \(response.isEmpty ? "(empty)" : response)")
        pendingCommand = nil
        pendingContinuation = nil
        responseBuffer = ""
        continuation.resume(returning: response)
    }

    private func parseStateOfCharge(from response: String) -> Double? {
        let bytes = hexBytes(from: response)
        guard let index = bytes.firstIndex(where: { $0 == 0x41 }),
              index + 2 < bytes.count,
              bytes[index + 1] == 0x5B
        else {
            return nil
        }
        return Double(bytes[index + 2]) * 100.0 / 255.0
    }

    private func parseEGMPStateOfCharge(from responses: [String: String]) -> Double? {
        if let bmsBytes = bytesForUDSResponse(to: [0x01, 0x01], in: responses["7E4 220101"]),
           let socByte = torquePIDByte("E", in: bmsBytes) {
            return min(100.0, Double(socByte) / 2.0)
        }

        if let displayBytes = bytesForUDSResponse(to: [0x01, 0x05], in: responses["7E4 220105"]),
           let socByte = torquePIDByte("AF", in: displayBytes) {
            return min(100.0, Double(socByte) / 2.0)
        }

        return nil
    }

    private func bytesForUDSResponse(to identifier: [UInt8], in response: String?) -> [UInt8]? {
        guard let response else { return nil }
        let bytes = hexBytes(from: response)
        guard let index = bytes.firstIndex(where: { $0 == 0x62 }),
              index + identifier.count < bytes.count,
              Array(bytes[(index + 1)...(index + identifier.count)]) == identifier
        else {
            return nil
        }
        return Array(bytes[index...])
    }

    private func torquePIDByte(_ label: String, in bytes: [UInt8]) -> UInt8? {
        let scalars = Array(label.uppercased().unicodeScalars)
        var index = 0
        let a = UInt8(ascii: "A")
        let z = UInt8(ascii: "Z")
        for scalar in scalars {
            let value = UInt8(scalar.value)
            guard value >= a,
                  value <= z
            else {
                return nil
            }
            index = index * 26 + Int(value - a + 1)
        }
        index -= 1
        guard bytes.indices.contains(index) else { return nil }
        return bytes[index]
    }

    private func parseVIN(from response: String) -> String? {
        let lines = response
            .components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: "\r") }

        var vinBytes: [UInt8] = []
        for line in lines {
            let bytes = hexBytes(from: line)
            guard let index = bytes.firstIndex(where: { $0 == 0x49 }),
                  index + 3 < bytes.count,
                  bytes[index + 1] == 0x02
            else {
                continue
            }
            vinBytes.append(contentsOf: bytes.dropFirst(index + 3))
        }

        let ascii = vinBytes.filter { $0 >= 0x20 && $0 <= 0x7E }
        guard ascii.count >= 11 else { return nil }
        return String(bytes: ascii, encoding: .ascii)
    }

    private func hexBytes(from response: String) -> [UInt8] {
        response
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .compactMap { token in
                let cleaned = token.filter { $0.isHexDigit }
                guard cleaned.count == 2 else { return nil }
                return UInt8(cleaned, radix: 16)
            }
    }

    private func isOBDLink(_ peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = (peripheral.name ?? localName ?? "").uppercased()
        return name.contains("OBDLINK")
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 120 {
            logLines.removeFirst(logLines.count - 120)
        }
    }
}

extension OBDLinkBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            scanIfReady()
        case .unauthorized:
            state = .failed("Bluetooth permission denied")
        case .unsupported:
            state = .failed("Bluetooth is not supported")
        case .poweredOff:
            state = .failed("Bluetooth is off")
        default:
            state = .idle
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi _: NSNumber
    ) {
        guard isOBDLink(peripheral, advertisementData: advertisementData) else {
            return
        }

        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting(peripheral.name ?? "OBDLink")
        appendLog("Found \(peripheral.name ?? "OBDLink")")
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connected(peripheral.name ?? "OBDLink")
        appendLog("Connected; discovering UART service")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .failed(error?.localizedDescription ?? "Could not connect to \(peripheral.name ?? "OBDLink")")
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral _: CBPeripheral, error: Error?) {
        if let error {
            state = .failed(error.localizedDescription)
        } else {
            state = .idle
        }
    }
}

extension OBDLinkBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            state = .failed(error.localizedDescription)
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            state = .failed("OBDLink UART service not found")
            return
        }

        peripheral.discoverCharacteristics([notifyUUID, writeUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            state = .failed(error.localizedDescription)
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == notifyUUID {
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == writeUUID {
                writeCharacteristic = characteristic
            }
        }

        guard notifyCharacteristic != nil, writeCharacteristic != nil else {
            state = .failed("OBDLink UART characteristics not found")
            return
        }

        appendLog("UART ready; initializing adapter")
        Task { await initializeAdapter() }
    }

    func peripheral(_: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            state = .failed(error.localizedDescription)
            return
        }

        guard characteristic.uuid == notifyUUID,
              let data = characteristic.value,
              let chunk = String(data: data, encoding: .utf8)
        else {
            return
        }

        responseBuffer += chunk
        completePendingCommandIfNeeded()
    }
}
