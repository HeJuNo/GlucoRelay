import SwiftUI

/// Palette taken from the app icon: deep navy background, crimson blood drop, electric-blue signal.
enum Theme {
    static let background = Color(red: 0.031, green: 0.071, blue: 0.165)      // #08122A
    static let backgroundTop = Color(red: 0.047, green: 0.133, blue: 0.333)   // #0C2255
    static let card = Color(red: 0.067, green: 0.118, blue: 0.251)            // #111E40
    static let cardStroke = Color.white.opacity(0.08)
    static let crimson = Color(red: 0.902, green: 0.137, blue: 0.188)         // #E62330
    static let electricBlue = Color(red: 0.184, green: 0.616, blue: 1.0)      // #2F9DFF
    static let connected = Color(red: 0.204, green: 0.827, blue: 0.459)       // green
    static let syncing = Color(red: 1.0, green: 0.792, blue: 0.157)           // yellow
    static let idle = Color.gray
    static let secondaryText = Color.white.opacity(0.6)

    static var backgroundGradient: LinearGradient {
        LinearGradient(colors: [backgroundTop, background], startPoint: .top, endPoint: .center)
    }

    static func color(for state: MeterConnectionState) -> Color {
        switch state {
        case .connected: connected
        case .connecting, .syncing: syncing
        case .disconnected: idle
        }
    }

    static func label(for state: MeterConnectionState) -> String {
        switch state {
        case .connected: "Connected"
        case .connecting: "Waiting for meter"
        case .syncing: "Syncing"
        case .disconnected: "Disconnected"
        }
    }
}

struct StatusDot: View {
    let state: MeterConnectionState
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(Theme.color(for: state))
            .frame(width: size, height: size)
            .shadow(color: Theme.color(for: state).opacity(state == .disconnected ? 0 : 0.8), radius: 4)
            .accessibilityLabel(Theme.label(for: state))
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.cardStroke))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// Small capsule badge for serial numbers.
struct SerialBadge: View {
    let serial: String

    var body: some View {
        Text("SN \(serial)")
            .font(.caption2.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.electricBlue.opacity(0.15), in: Capsule())
            .foregroundStyle(Theme.electricBlue)
    }
}

/// HealthKit + Nightscout sync indicators.
struct SyncIcons: View {
    let healthKit: Bool
    let nightscout: Bool
    var nightscoutFailed = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: healthKit ? "heart.fill" : "heart")
                .foregroundStyle(healthKit ? Theme.crimson : Theme.idle)
                .accessibilityLabel(healthKit ? "Saved to Health" : "Not yet in Health")
            Image(systemName: nightscout ? "checkmark.icloud.fill"
                  : (nightscoutFailed ? "exclamationmark.icloud" : "icloud"))
                .foregroundStyle(nightscout ? Theme.electricBlue : (nightscoutFailed ? Theme.syncing : Theme.idle))
                .accessibilityLabel(nightscout ? "Uploaded to Nightscout" : "Not yet uploaded to Nightscout")
        }
        .font(.subheadline)
    }
}
