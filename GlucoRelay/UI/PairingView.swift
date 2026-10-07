import SwiftUI

/// Scan → tap meter → (iOS PIN dialog) → serial shown → optional nickname → save.
struct PairingView: View {
    @Environment(BLEManager.self) private var ble
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var importHistory = false
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Add Meter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { ble.startScan() }
        .onDisappear { if !saved { ble.cancelPairing() } else { ble.stopScan() } }
    }

    @ViewBuilder
    private var content: some View {
        switch ble.pairingState {
        case .idle:
            scanList
        case .connecting, .readingSerial:
            connecting
        case .ready(let serial):
            confirm(serial: serial)
        case .failed(let message):
            failed(message)
        }
    }

    private var scanList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Put your Accu-Chek Guide in pairing mode", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.headline)
                    Text("On the meter: Settings ▸ Wireless ▸ Pairing – or, with the meter off, hold the OK button until the Bluetooth symbol flashes.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                .listRowBackground(Theme.card)
            }

            Section {
                if ble.discovered.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Searching for meters…").foregroundStyle(Theme.secondaryText)
                    }
                    .listRowBackground(Theme.card)
                }
                ForEach(ble.discovered) { meter in
                    Button {
                        ble.beginPairing(with: meter.id)
                    } label: {
                        HStack {
                            Image(systemName: "drop.fill").foregroundStyle(Theme.crimson)
                            VStack(alignment: .leading) {
                                Text(meter.name).foregroundStyle(.white)
                                if meter.rssi != 0 {
                                    Text("Signal \(meter.rssi) dBm").font(.caption).foregroundStyle(Theme.secondaryText)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .listRowBackground(Theme.card)
                }
            } header: {
                HStack {
                    Text("Discovered meters")
                    Spacer()
                    if ble.isScanning { ProgressView().controlSize(.mini) }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var connecting: some View {
        VStack(spacing: 20) {
            ProgressView().controlSize(.large).tint(Theme.electricBlue)
            Text(ble.pairingState == .connecting ? "Connecting…" : "Reading serial number…")
                .font(.title3.bold())
            Text("If iOS asks for a PIN, enter the 6-digit code shown on the meter display.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(32)
    }

    private func confirm(serial: String) -> some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.connected)
                    Text("Meter connected").font(.title3.bold())
                    Text("SN: \(serial)")
                        .font(.title2.monospaced().bold())
                        .foregroundStyle(Theme.electricBlue)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                TextField("Nickname (optional)", text: $nickname)
                Toggle("Import readings stored on the meter", isOn: $importHistory)
            } footer: {
                Text(importHistory
                     ? "All readings in the meter's memory are sent to Apple Health and Nightscout."
                     : "Only the most recent reading is imported; every new measurement is relayed from now on.")
            }
            Section {
                Button {
                    saved = true
                    ble.confirmPairing(nickname: nickname, importHistory: importHistory)
                    dismiss()
                } label: {
                    Text("Save Meter").frame(maxWidth: .infinity).font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.syncing)
            Text("Pairing failed").font(.title3.bold())
            Text(message).multilineTextAlignment(.center).foregroundStyle(Theme.secondaryText)
            Button("Try again") {
                ble.cancelPairing()
                ble.startScan()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
