import SwiftUI
import SwiftData

struct HistoryView: View {
    @AppStorage(GlucoseUnit.storageKey) private var unitRaw = GlucoseUnit.mmolL.rawValue
    @Query(sort: \GlucoseReading.timestamp, order: .reverse) private var readings: [GlucoseReading]

    private var unit: GlucoseUnit { GlucoseUnit(rawValue: unitRaw) ?? .mmolL }

    private var hasFailedUploads: Bool {
        readings.contains { !$0.nightscoutSynced && $0.nightscoutRetryCount >= SyncQueue.maxNightscoutRetries }
    }

    /// Readings grouped by calendar day, newest first.
    private var sections: [(day: Date, items: [GlucoseReading])] {
        let cal = Calendar.current
        var result: [(day: Date, items: [GlucoseReading])] = []
        for r in readings {
            let day = cal.startOfDay(for: r.timestamp)
            if let last = result.last, last.day == day {
                result[result.count - 1].items.append(r)
            } else {
                result.append((day, [r]))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if readings.isEmpty {
                    ContentUnavailableView("No readings yet", systemImage: "drop",
                                           description: Text("Readings from your meter appear here."))
                } else {
                    List {
                        ForEach(sections, id: \.day) { section in
                            Section {
                                ForEach(section.items) { reading in
                                    HistoryRow(reading: reading, unit: unit)
                                        .listRowBackground(Theme.card)
                                }
                            } header: {
                                Text(section.day, format: .dateTime.weekday(.wide).day().month(.wide))
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("History")
            .toolbar {
                if hasFailedUploads {
                    Button {
                        AppServices.shared.syncQueue.resetFailedAndRetry()
                    } label: {
                        Label("Retry uploads", systemImage: "arrow.clockwise.icloud")
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    let reading: GlucoseReading
    let unit: GlucoseUnit

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(reading.timestamp, format: .dateTime.hour().minute())
                    .font(.headline.monospacedDigit())
                SerialBadge(serial: reading.serialNumber)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(unit.format(mgdL: reading.value))
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(Theme.crimson)
                Text(unit.label)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            SyncIcons(healthKit: reading.healthKitSynced, nightscout: reading.nightscoutSynced,
                      nightscoutFailed: reading.nightscoutRetryCount >= SyncQueue.maxNightscoutRetries)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
