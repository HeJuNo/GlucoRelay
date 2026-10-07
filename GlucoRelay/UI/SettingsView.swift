import SwiftUI

struct SettingsView: View {
    @Environment(HealthKitSync.self) private var healthKit
    @Environment(\.openURL) private var openURL
    @AppStorage(GlucoseUnit.storageKey) private var unitRaw = GlucoseUnit.mmolL.rawValue

    @State private var nsURL = ""
    @State private var nsToken = ""
    @State private var showToken = false
    @State private var testing = false
    @State private var testResult: ConnectionTestResult?
    @State private var showPairing = false

    private var credentialsChanged: Bool {
        NightscoutSync.normalizedBase(nsURL) != NightscoutSync.normalizedBase(KeychainManager.nightscoutURL ?? "")
            || nsToken.trimmingCharacters(in: .whitespacesAndNewlines) != (KeychainManager.accessToken ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                nightscoutSection
                unitSection
                healthKitSection
                DeviceListView(showPairing: $showPairing)
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .onAppear {
                nsURL = KeychainManager.nightscoutURL ?? ""
                nsToken = KeychainManager.accessToken ?? ""
                healthKit.refreshStatus()
            }
            .sheet(isPresented: $showPairing) { PairingView() }
        }
    }

    // MARK: Nightscout

    private var nightscoutSection: some View {
        Section {
            TextField("https://my-nightscout.example.com", text: $nsURL)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Group {
                    if showToken {
                        TextField("Access token", text: $nsToken)
                    } else {
                        SecureField("Access token", text: $nsToken)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                Button { showToken.toggle() } label: {
                    Image(systemName: showToken ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }

            Button("Save") { saveCredentials() }
                .disabled(!credentialsChanged)

            Button {
                Task { await runTest() }
            } label: {
                HStack {
                    Text("Test connection")
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing || nsURL.isEmpty || nsToken.isEmpty)

            if let result = testResult {
                VStack(alignment: .leading, spacing: 4) {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(result.ok ? Theme.connected : Theme.crimson)
                    if let info = result.serverInfo { Text(info).font(.caption).foregroundStyle(Theme.secondaryText) }
                    if let subject = result.subject { Text("Token subject: \(subject)").font(.caption).foregroundStyle(Theme.secondaryText) }
                }
                .font(.subheadline)
            }
        } header: {
            Text("Nightscout")
        } footer: {
            Text("Create an access token in Nightscout ▸ Admin Tools with the roles **readable** and **careportal**. URL and token are stored in the iOS Keychain. Readings are always uploaded in mg/dL.")
        }
    }

    private func saveCredentials() {
        KeychainManager.nightscoutURL = NightscoutSync.normalizedBase(nsURL)
        KeychainManager.accessToken = nsToken
        nsURL = KeychainManager.nightscoutURL ?? ""
        Task {
            await NightscoutSync.resetSession()
            await NightscoutSync.prefetchJWT()
            AppServices.shared.syncQueue.resetFailedAndRetry()
        }
    }

    private func runTest() async {
        testing = true
        testResult = nil
        let result = await NightscoutSync.testConnection(urlString: nsURL, token: nsToken)
        testResult = result
        testing = false
        if result.ok && credentialsChanged { saveCredentials() }
    }

    // MARK: Units

    private var unitSection: some View {
        Section {
            Picker("Display unit", selection: $unitRaw) {
                ForEach(GlucoseUnit.allCases) { unit in
                    Text(unit.label).tag(unit.rawValue)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Display unit")
        } footer: {
            Text("Only changes how values are shown. Apple Health and Nightscout always receive the exact meter value.")
        }
    }

    // MARK: HealthKit

    private var healthKitSection: some View {
        Section("Apple Health") {
            HStack {
                Image(systemName: "heart.fill").foregroundStyle(Theme.crimson)
                Text("Write access")
                Spacer()
                Text(healthKitStatusText).foregroundStyle(healthKit.status == .authorized ? Theme.connected : Theme.secondaryText)
            }
            switch healthKit.status {
            case .notDetermined:
                Button("Request access") { Task { await healthKit.requestAuthorization() } }
            case .denied:
                Button("Request access again") { Task { await healthKit.requestAuthorization() } }
                Button("Open Health settings") {
                    if let url = URL(string: "x-apple-health://") { openURL(url) }
                }
                Text("If access was denied, enable it in the Health app ▸ Sharing ▸ Apps ▸ GlucoRelay.")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            case .authorized, .unavailable:
                EmptyView()
            }
        }
    }

    private var healthKitStatusText: String {
        switch healthKit.status {
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .notDetermined: "Not requested"
        case .unavailable: "Unavailable"
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version",
                           value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
            Text("GlucoRelay is not a medical device. Accu-Chek and Accu-Chek Guide are trademarks of Roche.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }
}
