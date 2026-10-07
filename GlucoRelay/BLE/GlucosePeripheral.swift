import Foundation
@preconcurrency import CoreBluetooth
import os.log

private let logger = Logger(subsystem: "glucorelay", category: "GlucosePeripheral")

/// Bluetooth SIG UUIDs used by the Glucose Profile.
enum GATT {
    nonisolated(unsafe) static let glucoseService = CBUUID(string: "1808")
    nonisolated(unsafe) static let deviceInformationService = CBUUID(string: "180A")
    nonisolated(unsafe) static let serialNumberString = CBUUID(string: "2A25")
    nonisolated(unsafe) static let glucoseMeasurement = CBUUID(string: "2A18")
    nonisolated(unsafe) static let recordAccessControlPoint = CBUUID(string: "2A52")
}

@MainActor
protocol GlucosePeripheralDelegate: AnyObject {
    func glucosePeripheral(_ meter: GlucosePeripheral, didReadSerial serial: String)
    /// Measurement notifications + RACP indications are enabled and the serial has been read (or is unavailable).
    func glucosePeripheralDidBecomeReady(_ meter: GlucosePeripheral)
    func glucosePeripheral(_ meter: GlucosePeripheral, didReceive measurement: GlucoseMeasurement)
    func glucosePeripheral(_ meter: GlucosePeripheral, didFinishTransfer success: Bool, detail: String)
    func glucosePeripheral(_ meter: GlucosePeripheral, didFail message: String)
}

/// Drives one connected Accu-Chek Guide: service discovery, serial number read,
/// notification setup and RACP record transfers. All callbacks run on the main queue.
@MainActor
final class GlucosePeripheral: NSObject {
    let peripheral: CBPeripheral
    weak var delegate: GlucosePeripheralDelegate?

    private(set) var serialNumber: String?
    private(set) var isReady = false
    private(set) var isTransferring = false

    private var measurementCharacteristic: CBCharacteristic?
    private var racpCharacteristic: CBCharacteristic?
    private var measurementNotifying = false
    private var racpNotifying = false
    private var serialAttempted = false
    private var pendingRequest: Data?
    private var notifyRetries = 0

    var id: UUID { peripheral.identifier }
    var name: String { peripheral.name ?? "Accu-Chek Guide" }

    init(peripheral: CBPeripheral, knownSerial: String?) {
        self.peripheral = peripheral
        self.serialNumber = knownSerial
        super.init()
        peripheral.delegate = self
    }

    /// Call after every (re)connect – notification subscriptions do not survive a disconnect.
    func start() {
        resetSession()
        peripheral.delegate = self
        // Serial is always re-read on connect, so a changed meter behind the same UUID is noticed.
        peripheral.discoverServices([GATT.glucoseService, GATT.deviceInformationService])
    }

    func resetSession() {
        isReady = false
        isTransferring = false
        measurementNotifying = false
        racpNotifying = false
        serialAttempted = false
        notifyRetries = 0
    }

    /// Writes a RACP command now, or as soon as the meter is ready.
    func requestRecords(_ command: Data) {
        guard isReady, let racp = racpCharacteristic, peripheral.state == .connected else {
            pendingRequest = command
            return
        }
        pendingRequest = nil
        isTransferring = true
        logger.info("RACP write \(command.map { String(format: "%02X", $0) }.joined(separator: " "))")
        peripheral.writeValue(command, for: racp, type: .withResponse)
    }

    private func checkReady() {
        guard !isReady, measurementNotifying, racpNotifying, serialAttempted else { return }
        isReady = true
        logger.info("Meter \(self.serialNumber ?? "?") ready")
        delegate?.glucosePeripheralDidBecomeReady(self)
        if let pending = pendingRequest { requestRecords(pending) }
    }

    private func subscribe(_ characteristic: CBCharacteristic) {
        peripheral.setNotifyValue(true, for: characteristic)
    }
}

extension GlucosePeripheral: @preconcurrency CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            delegate?.glucosePeripheral(self, didFail: "Service discovery failed: \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        if !services.contains(where: { $0.uuid == GATT.deviceInformationService }) {
            serialAttempted = true
        }
        for service in services {
            switch service.uuid {
            case GATT.glucoseService:
                peripheral.discoverCharacteristics([GATT.glucoseMeasurement, GATT.recordAccessControlPoint], for: service)
            case GATT.deviceInformationService:
                peripheral.discoverCharacteristics([GATT.serialNumberString], for: service)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        if let error {
            if service.uuid == GATT.deviceInformationService { serialAttempted = true; checkReady() }
            delegate?.glucosePeripheral(self, didFail: "Characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case GATT.serialNumberString:
                peripheral.readValue(for: c)
            case GATT.glucoseMeasurement:
                measurementCharacteristic = c
                subscribe(c)
            case GATT.recordAccessControlPoint:
                racpCharacteristic = c
                subscribe(c) // indications; first subscription triggers iOS bonding (PIN from the meter display)
            default:
                break
            }
        }
        if service.uuid == GATT.deviceInformationService,
           !(service.characteristics ?? []).contains(where: { $0.uuid == GATT.serialNumberString }) {
            serialAttempted = true
            checkReady()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            logger.error("Notify \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
            // Typical during first bonding (insufficient authentication) – retry a few times.
            if notifyRetries < 3 {
                notifyRetries += 1
                let isMeasurement = characteristic.uuid == GATT.glucoseMeasurement
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, self.peripheral.state == .connected,
                          let c = isMeasurement ? self.measurementCharacteristic : self.racpCharacteristic
                    else { return }
                    self.subscribe(c)
                }
            } else {
                delegate?.glucosePeripheral(self, didFail: "Could not subscribe to the meter. Remove the meter in iOS Bluetooth settings and pair again.")
            }
            return
        }
        switch characteristic.uuid {
        case GATT.glucoseMeasurement: measurementNotifying = characteristic.isNotifying
        case GATT.recordAccessControlPoint: racpNotifying = characteristic.isNotifying
        default: break
        }
        checkReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            if characteristic.uuid == GATT.serialNumberString {
                serialAttempted = true
                checkReady()
            }
            logger.error("Value update \(characteristic.uuid.uuidString) failed: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }

        switch characteristic.uuid {
        case GATT.serialNumberString:
            serialAttempted = true
            if let serial = GATTParser.parseSerial(data) {
                serialNumber = serial
                delegate?.glucosePeripheral(self, didReadSerial: serial)
            }
            checkReady()

        case GATT.glucoseMeasurement:
            do {
                let m = try GATTParser.parseMeasurement(data)
                delegate?.glucosePeripheral(self, didReceive: m)
            } catch {
                logger.error("Unparseable measurement \(data.map { String(format: "%02X", $0) }.joined()): \(String(describing: error))")
            }

        case GATT.recordAccessControlPoint:
            switch RACP.parse(data) {
            case .completed(let success, let noRecords, let code):
                isTransferring = false
                delegate?.glucosePeripheral(self, didFinishTransfer: success || noRecords,
                                            detail: noRecords ? "No new records" : (success ? "Transfer complete" : "RACP error \(code)"))
            case .numberOfRecords(let n):
                logger.info("Meter reports \(n) record(s)")
            case .unknown:
                break
            }

        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard characteristic.uuid == GATT.recordAccessControlPoint, let error else { return }
        isTransferring = false
        delegate?.glucosePeripheral(self, didFinishTransfer: false, detail: "RACP write failed: \(error.localizedDescription)")
    }
}
