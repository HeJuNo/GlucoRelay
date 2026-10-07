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
                testRow("Server reachable", ok: result.serverReachable, detail: result.serverReachableDetail)
                if let info = result.serverInfo {
                    testRow("Server", ok: nil, detail: info)
                }
                testRow("Access token", ok: result.serverReachable ? result.tokenValid : nil,
                        detail: result.tokenSubject ?? (result.tokenValid ? "Valid" : (result.serverReachable ? "Invalid" : "Not tested")))
                testRow("Read access", ok: result.tokenValid ? result.canRead : nil,
                        detail: result.canReadDetail.isEmpty ? "Not tested" : result.canReadDetail)
                testRow("Write access", ok: result.tokenValid ? result.canWrite : nil,
                        detail: result.canWriteDetail.isEmpty ? "Not tested" : result.canWriteDetail)
            }
        } header: {
            Text("Nightscout")
        } footer: {
            Text("Create an access token in Nightscout ▸ Admin Tools with the roles **readable** and **careportal**. URL and token are stored in the iOS Keychain. Readings are always uploaded in mg/dL.")
        }
    }

    /// One row of the connection test: status icon + label, detail on the right.
    /// `ok == nil` = not tested / informational.
    private func testRow(_ label: String, ok: Bool?, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok == nil ? "questionmark.circle.fill" : (ok! ? "checkmark.circle.fill" : "xmark.circle.fill"))
                .foregroundStyle(ok == nil ? Theme.idle : (ok! ? Theme.connected : Theme.crimson))
            Text(label)
            Spacer(minLength: 12)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
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
