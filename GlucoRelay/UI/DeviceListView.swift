import SwiftUI
import SwiftData

/// "Devices" section of the settings: paired meters with status, rename, swipe-to-delete and "Add Meter".
struct DeviceListView: View {
    @Environment(BLEManager.self) private var ble
    @Query(sort: \DeviceRecord.addedAt) private var devices: [DeviceRecord]
    @Binding var showPairing: Bool
    @State private var renaming: DeviceRecord?
    @State private var newName = ""

    var body: some View {
        Section {
            ForEach(devices) { device in
                let state = ble.state(for: device.id)
                HStack(spacing: 12) {
                    StatusDot(state: state)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.displayName).font(.body.weight(.medium))
                        SerialBadge(serial: device.serialNumber)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Theme.label(for: state)).font(.caption).foregroundStyle(Theme.color(for: state))
                        if device.lastSequenceNumber >= 0 {
                            Text("Record #\(device.lastSequenceNumber)").font(.caption2).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Rename", systemImage: "pencil") {
                        newName = device.nickname ?? ""
                        renaming = device
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets { ble.removeMeter(id: devices[index].id) }
            }

            Button {
                showPairing = true
            } label: {
                Label("Add Meter", systemImage: "plus.circle.fill")
            }
            .disabled(!ble.isPoweredOn)
        } header: {
            Text("Meters")
        } footer: {
            Text("Swipe left to remove a meter. To pair it again later, also remove it in iOS Settings ▸ Bluetooth. Long-press to rename.")
        }
        .alert("Rename meter", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nickname", text: $newName)
            Button("Save") {
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                renaming?.nickname = trimmed.isEmpty ? nil : trimmed
                AppServices.shared.devices.save()
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}
