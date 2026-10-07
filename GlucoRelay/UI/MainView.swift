import SwiftUI
import SwiftData

struct MainView: View {
    @Environment(BLEManager.self) private var ble
    @AppStorage(GlucoseUnit.storageKey) private var unitRaw = GlucoseUnit.mmolL.rawValue
    @Query(sort: \DeviceRecord.addedAt) private var devices: [DeviceRecord]
    @Query(MainView.recentDescriptor) private var recent: [GlucoseReading]
    @State private var showPairing = false

    private static var recentDescriptor: FetchDescriptor<GlucoseReading> {
        var d = FetchDescriptor<GlucoseReading>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        d.fetchLimit = 200
        return d
    }

    private var unit: GlucoseUnit { GlucoseUnit(rawValue: unitRaw) ?? .mmolL }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !ble.isPoweredOn { bluetoothBanner }

                    if devices.isEmpty {
                        emptyState
                    } else {
                        if let latest = recent.first {
                            LatestReadingCard(reading: latest, unit: unit,
                                              deviceName: name(for: latest.peripheralUUID))
                        } else {
                            noReadingsCard
                        }
                        if devices.count > 1 { perMeterSection }
                        metersSection
                    }
                }
                .padding()
            }
            .refreshable { ble.syncAll() }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("GlucoRelay")
            .sheet(isPresented: $showPairing) { PairingView() }
        }
    }

    private func name(for id: UUID) -> String? { devices.first { $0.id == id }?.displayName }

    private var bluetoothBanner: some View {
        Label(ble.bluetoothState == .unauthorized
              ? "Bluetooth access denied – enable it in iOS Settings ▸ GlucoRelay."
              : "Bluetooth is off – readings cannot be received.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(Theme.syncing)
            .card()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(Theme.electricBlue)
            Text("No meter paired").font(.title2.bold())
            Text("Pair your Accu-Chek Guide to start relaying readings to Apple Health and Nightscout.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondaryText)
            Button("Add Meter") { showPairing = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 24)
        .card()
    }

    private var noReadingsCard: some View {
        VStack(spacing: 8) {
            Text("—").font(.system(size: 72, weight: .bold, design: .rounded)).foregroundStyle(Theme.crimson)
            Text("No readings yet. Take a measurement – it appears here automatically.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    /// Latest reading of every meter.
    private var perMeterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Per meter").font(.headline)
            ForEach(devices) { device in
                HStack {
                    StatusDot(state: ble.state(for: device.id))
                    VStack(alignment: .leading) {
                        Text(device.displayName).font(.subheadline.bold())
                        SerialBadge(serial: device.serialNumber)
                    }
                    Spacer()
                    if let r = recent.first(where: { $0.peripheralUUID == device.id }) {
                        VStack(alignment: .trailing) {
                            Text("\(unit.format(mgdL: r.value)) \(unit.label)")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(Theme.crimson)
                            Text(r.timestamp, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    } else {
                        Text("—").foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .card()
    }

    private var metersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(Theme.electricBlue)
                Text("Meters").font(.headline)
                Spacer()
                Button { showPairing = true } label: { Image(systemName: "plus.circle") }
            }
            ForEach(devices) { device in
                let state = ble.state(for: device.id)
                HStack {
                    StatusDot(state: state)
                    Text(device.displayName)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Theme.label(for: state)).font(.caption).foregroundStyle(Theme.color(for: state))
                        if let last = ble.lastSyncAt[device.id] {
                            Text("Synced \(last.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
            if let error = ble.lastError {
                Text(error).font(.caption).foregroundStyle(Theme.syncing)
            }
            Text("The meter only connects briefly after a measurement – “Waiting for meter” is normal.")
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
        }
        .card()
    }
}

struct LatestReadingCard: View {
    let reading: GlucoseReading
    let unit: GlucoseUnit
    let deviceName: String?

    var body: some View {
        VStack(spacing: 6) {
            Text("LAST READING")
                .font(.caption.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(unit.format(mgdL: reading.value))
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.crimson)
                    .shadow(color: Theme.crimson.opacity(0.5), radius: 16)
                    .contentTransition(.numericText())
                Text(unit.label)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            Text(reading.timestamp, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
                .font(.headline)
            Text(reading.timestamp, format: .relative(presentation: .named))
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 10) {
                if let deviceName { Text(deviceName).font(.caption) }
                SerialBadge(serial: reading.serialNumber)
                SyncIcons(healthKit: reading.healthKitSynced, nightscout: reading.nightscoutSynced,
                          nightscoutFailed: reading.nightscoutRetryCount >= SyncQueue.maxNightscoutRetries)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .card()
    }
}
