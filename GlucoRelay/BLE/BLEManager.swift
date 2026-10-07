import Foundation
@preconcurrency import CoreBluetooth
import Observation
import os.log

private let logger = Logger(subsystem: "glucorelay", category: "BLEManager")

enum MeterConnectionState: Equatable, Sendable {
    case disconnected, connecting, connected, syncing
}

struct DiscoveredMeter: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var rssi: Int
}

enum PairingState: Equatable, Sendable {
    case idle
    case connecting
    case readingSerial
    case ready(serial: String)
    case failed(String)
}

/// Central for all Accu-Chek Guide meters. Keeps every saved meter connected (or with a pending
/// connect, which iOS completes in the background as soon as the meter advertises after a
/// measurement) and survives app termination via CoreBluetooth state restoration.
@MainActor
@Observable
final class BLEManager: NSObject {
    static let restoreIdentifier = "com.glucorelay.central"

    private(set) var bluetoothState: CBManagerState = .unknown
    private(set) var connectionStates: [UUID: MeterConnectionState] = [:]
    private(set) var lastSyncAt: [UUID: Date] = [:]
    private(set) var discovered: [DiscoveredMeter] = []
    private(set) var isScanning = false
    private(set) var pairingState: PairingState = .idle
    private(set) var pairingPeripheralID: UUID?
    private(set) var lastError: String?

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var meters: [UUID: GlucosePeripheral] = [:]
    @ObservationIgnored private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var importHistoryOnPairing = false
    @ObservationIgnored private let devices: DeviceStore
    @ObservationIgnored private let readings: GlucoseReadingStore
    @ObservationIgnored private let syncQueue: SyncQueue

    init(devices: DeviceStore, readings: GlucoseReadingStore, syncQueue: SyncQueue) {
        self.devices = devices
        self.readings = readings
        self.syncQueue = syncQueue
        super.init()
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }

    func state(for id: UUID) -> MeterConnectionState { connectionStates[id] ?? .disconnected }

    var isPoweredOn: Bool { bluetoothState == .poweredOn }

    // MARK: Saved meters

    /// Connects to all saved peripherals directly by UUID (no scan needed).
    func connectSavedMeters() {
        guard isPoweredOn else { return }
        let ids = devices.savedIdentifiers
        guard !ids.isEmpty else {
            // No meter saved yet: look for Glucose Service advertisers (bounded, to save battery).
            startScan(timeout: .seconds(60))
            return
        }
        for peripheral in central.retrievePeripherals(withIdentifiers: ids) {
            let meter = register(peripheral)
            switch peripheral.state {
            case .connected:
                connectionStates[peripheral.identifier] = .connected
                meter.start()
            case .connecting:
                connectionStates[peripheral.identifier] = .connecting
            default:
                connect(peripheral)
            }
        }
    }

    /// Re-requests new records from every connected meter (pull-to-refresh).
    func syncAll() {
        for (id, meter) in meters where devices.device(id: id) != nil && meter.peripheral.state == .connected {
            requestNewRecords(meter)
        }
        if meters.isEmpty || meters.values.allSatisfy({ $0.peripheral.state != .connected }) {
            connectSavedMeters()
        }
        syncQueue.trigger()
    }

    func removeMeter(id: UUID) {
        devices.remove(id: id)
        if let p = peripherals[id] { central.cancelPeripheralConnection(p) }
        meters[id] = nil
        peripherals[id] = nil
        connectionStates[id] = nil
        lastSyncAt[id] = nil
    }

    // MARK: Scanning & pairing

    @ObservationIgnored private var scanGeneration = 0

    func startScan(timeout: Duration? = nil) {
        guard isPoweredOn else { return }
        scanGeneration += 1
        if let timeout {
            let generation = scanGeneration
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, self.scanGeneration == generation else { return }
                self.stopScan()
            }
        }
        discovered.removeAll()
        discoveredPeripherals.removeAll()
        // Meters already connected to iOS (e.g. paired in Settings) do not advertise.
        let saved = Set(devices.savedIdentifiers)
        for p in central.retrieveConnectedPeripherals(withServices: [GATT.glucoseService]) where !saved.contains(p.identifier) {
            addDiscovered(p, name: p.name, rssi: 0)
        }
        central.scanForPeripherals(withServices: [GATT.glucoseService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
    }

    func stopScan() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
    }

    func beginPairing(with id: UUID) {
        guard let peripheral = discoveredPeripherals[id] ?? peripherals[id] else { return }
        stopScan()
        pairingPeripheralID = id
        pairingState = .connecting
        let meter = register(peripheral)
        if peripheral.state == .connected {
            pairingState = .readingSerial
            meter.start()
        } else {
            connect(peripheral)
        }
    }

    /// Saves the meter. `importHistory` = transfer the meter's whole memory, otherwise only the latest record.
    func confirmPairing(nickname: String?, importHistory: Bool) {
        guard let id = pairingPeripheralID, case .ready(let serial) = pairingState, let meter = meters[id] else { return }
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        devices.add(id: id, serialNumber: serial, nickname: (trimmed?.isEmpty ?? true) ? nil : trimmed)
        pairingState = .idle
        pairingPeripheralID = nil
        connectionStates[id] = .syncing
        meter.requestRecords(importHistory ? RACP.reportAll() : RACP.reportLast())
    }

    func cancelPairing() {
        if let id = pairingPeripheralID, devices.device(id: id) == nil {
            if let p = peripherals[id] { central.cancelPeripheralConnection(p) }
            meters[id] = nil
            peripherals[id] = nil
            connectionStates[id] = nil
        }
        pairingState = .idle
        pairingPeripheralID = nil
        stopScan()
    }

    // MARK: Helpers

    @discardableResult
    private func register(_ peripheral: CBPeripheral) -> GlucosePeripheral {
        let id = peripheral.identifier
        peripherals[id] = peripheral
        if let meter = meters[id] {
            peripheral.delegate = meter
            return meter
        }
        let meter = GlucosePeripheral(peripheral: peripheral, knownSerial: devices.device(id: id)?.serialNumber)
        meter.delegate = self
        meters[id] = meter
        return meter
    }

    private func connect(_ peripheral: CBPeripheral) {
        connectionStates[peripheral.identifier] = .connecting
        // A pending connect never times out: iOS completes it (also in the background)
        // the next time the meter advertises, i.e. right after a measurement.
        central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: false])
    }

    private func addDiscovered(_ peripheral: CBPeripheral, name: String?, rssi: Int) {
        let id = peripheral.identifier
        discoveredPeripherals[id] = peripheral
        let display = name ?? peripheral.name ?? "Glucose meter"
        if let i = discovered.firstIndex(where: { $0.id == id }) {
            discovered[i].rssi = rssi
            discovered[i].name = display
        } else {
            discovered.append(DiscoveredMeter(id: id, name: display, rssi: rssi))
        }
    }

    private func requestNewRecords(_ meter: GlucosePeripheral) {
        guard let device = devices.device(id: meter.id) else { return }
        connectionStates[meter.id] = .syncing
        meter.requestRecords(RACP.reportAfter(sequence: device.lastSequenceNumber))
    }

    private func handle(_ m: GlucoseMeasurement, from meter: GlucosePeripheral) {
        // Records of meters that are not saved yet (pairing in progress) are ignored.
        guard let device = devices.device(id: meter.id) else { return }
        guard m.sequenceNumber > device.lastSequenceNumber,
              !readings.exists(peripheralUUID: meter.id, sequenceNumber: m.sequenceNumber) else {
            return
        }
        defer { devices.updateLastSequence(id: meter.id, sequence: m.sequenceNumber) }

        guard let mgdL = m.mgdL, !m.isControlSolution else {
            logger.info("Skipping record #\(m.sequenceNumber) (control solution or HI/LO)")
            return
        }
        let reading = GlucoseReading(peripheralUUID: meter.id,
                                     serialNumber: meter.serialNumber ?? device.serialNumber,
                                     sequenceNumber: m.sequenceNumber,
                                     valueMgdL: mgdL,
                                     unit: GlucoseUnit.current,
                                     timestamp: m.timestamp)
        readings.insert(reading)
        logger.info("New reading #\(m.sequenceNumber): \(mgdL) mg/dL")
        syncQueue.trigger()
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: @preconcurrency CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        logger.info("Bluetooth state \(central.state.rawValue)")
        if central.state == .poweredOn {
            connectSavedMeters()
        } else {
            isScanning = false
            for id in connectionStates.keys { connectionStates[id] = .disconnected }
            for meter in meters.values { meter.resetSession() }
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        logger.info("Restoring \(restored.count) peripheral(s)")
        for peripheral in restored {
            register(peripheral)
            connectionStates[peripheral.identifier] = peripheral.state == .connected ? .connected : .connecting
        }
        // Connections / re-subscriptions are completed in centralManagerDidUpdateState(.poweredOn).
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        if devices.device(id: id) != nil {
            // A saved meter showed up while scanning – just connect it.
            if peripheral.state == .disconnected { register(peripheral); connect(peripheral) }
            return
        }
        addDiscovered(peripheral, name: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                      rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        logger.info("Connected \(id)")
        connectionStates[id] = .connected
        lastError = nil
        if pairingPeripheralID == id { pairingState = .readingSerial }
        register(peripheral).start()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        let id = peripheral.identifier
        connectionStates[id] = .disconnected
        if pairingPeripheralID == id {
            pairingState = .failed(error?.localizedDescription ?? "Connection failed")
        } else if devices.device(id: id) != nil {
            connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        let id = peripheral.identifier
        logger.info("Disconnected \(id): \(error?.localizedDescription ?? "-")")
        meters[id]?.resetSession()
        connectionStates[id] = .disconnected
        if pairingPeripheralID == id {
            if case .ready = pairingState {} else {
                pairingState = .failed("The meter disconnected. Put it in pairing mode again and retry.")
            }
        }
        // Always-on: immediately queue a new pending connect for saved meters.
        if devices.device(id: id) != nil, central.state == .poweredOn {
            connect(peripheral)
        }
    }
}

// MARK: - GlucosePeripheralDelegate

extension BLEManager: GlucosePeripheralDelegate {

    func glucosePeripheral(_ meter: GlucosePeripheral, didReadSerial serial: String) {
        devices.updateSerial(id: meter.id, serialNumber: serial)
    }

    func glucosePeripheralDidBecomeReady(_ meter: GlucosePeripheral) {
        if pairingPeripheralID == meter.id {
            pairingState = .ready(serial: meter.serialNumber ?? String(meter.id.uuidString.prefix(8)))
            return
        }
        requestNewRecords(meter)
    }

    func glucosePeripheral(_ meter: GlucosePeripheral, didReceive measurement: GlucoseMeasurement) {
        handle(measurement, from: meter)
    }

    func glucosePeripheral(_ meter: GlucosePeripheral, didFinishTransfer success: Bool, detail: String) {
        logger.info("Transfer finished (\(success)): \(detail)")
        if meter.peripheral.state == .connected { connectionStates[meter.id] = .connected }
        if success { lastSyncAt[meter.id] = .now } else { lastError = detail }
        syncQueue.trigger()
    }

    func glucosePeripheral(_ meter: GlucosePeripheral, didFail message: String) {
        lastError = message
        if pairingPeripheralID == meter.id { pairingState = .failed(message) }
    }
}
