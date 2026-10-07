import SwiftUI

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding {
            TabView {
                MainView()
                    .tabItem { Label("Glucose", systemImage: "drop.fill") }
                HistoryView()
                    .tabItem { Label("History", systemImage: "list.bullet.rectangle") }
            }
        } else {
            OnboardingView { hasCompletedOnboarding = true }
        }
    }
}

/// First-launch "How to pair" guide.
struct OnboardingView: View {
    @Environment(HealthKitSync.self) private var healthKit
    let onFinish: () -> Void

    private let steps: [(icon: String, title: String, text: String)] = [
        ("drop.fill", "Measure as usual",
         "GlucoRelay picks up every reading from your Accu-Chek Guide and forwards it to Apple Health and Nightscout – no tapping required."),
        ("antenna.radiowaves.left.and.right", "Put the meter in pairing mode",
         "On the meter open Settings ▸ Wireless ▸ Pairing (or, with the meter switched off, hold the OK button until the Bluetooth symbol flashes)."),
        ("number.square", "Enter the PIN",
         "Tap the gear icon ▸ Add Meter, then tap your meter. iOS asks for a PIN – type the 6-digit code shown on the meter display."),
        ("bolt.horizontal.circle", "Stay connected",
         "Keep GlucoRelay installed and Bluetooth on. After each measurement the meter connects in the background and the reading is relayed within seconds.")
    ]

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.crimson)
                            .shadow(color: Theme.crimson.opacity(0.6), radius: 12)
                        Text("Welcome to GlucoRelay")
                            .font(.largeTitle.bold())
                        Text("Your Accu-Chek Guide, relayed to Apple Health and Nightscout.")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.top, 40)

                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 16) {
                            ZStack {
                                Circle().fill(Theme.electricBlue.opacity(0.15)).frame(width: 44, height: 44)
                                Image(systemName: step.icon).foregroundStyle(Theme.electricBlue)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1). \(step.title)").font(.headline)
                                Text(step.text).font(.subheadline).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }

                    Button {
                        Task {
                            await healthKit.requestAuthorization()
                            onFinish()
                        }
                    } label: {
                        Text("Get Started")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.crimson)
                    .padding(.top, 8)

                    Text("GlucoRelay is not a medical device. Always confirm treatment decisions with your meter.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(24)
            }
        }
    }
}
