import SwiftUI

struct SettingsView: View {
    @Environment(HealthKitSync.self) private var healthKit
    @Environment(\.openURL) private var openURL
    @AppStorage(GlucoseUnit.storageKey) private var unitRaw = GlucoseUnit.mmolL.rawValue

    // Nightscout fields
    @State private var nsURL: String = ""
    @State private var nsToken: String = ""
    @State private var showToken = false
    @State private var saved = false
    @State private var validationError: String? = nil

    // Connection test
    @State private var testing = false
    @State private var testResult: ConnectionTestResult? = nil

    // Device pairing sheet
    @State private var showPairing = false

    @FocusState private var urlFocused: Bool
    @FocusState private var tokenFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                nightscoutConnectionSection
                saveSection
                connectionTestSection
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

    // MARK: - Nightscout Connection

    private var nightscoutConnectionSection: some View {
        Section(header: Text("Nightscout Connection")) {
            // URL
            VStack(alignment: .leading, spacing: 4) {
                Text("URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://my-nightscout.example.com", text: $nsURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($urlFocused)
            }

            // Access Token
            VStack(alignment: .leading, spacing: 4) {
                Text("Access Token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Group {
                        if showToken {
                            TextField("e.g. name-1a2b3c4d5e6f7a8b", text: $nsToken)
                        } else {
                            SecureField("e.g. name-1a2b3c4d5e6f7a8b", text: $nsToken)
                        }
                    }
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.body.monospaced())
                    .focused($tokenFocused)

                    Button {
                        showToken.toggle()
                    } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showToken ? "Hide token" : "Show token")
                }

                if !nsToken.isEmpty && !NightscoutSync.looksLikeAccessToken(nsToken) {
                    Label("Doesn't look like a Nightscout access token (format: name-1a2b3c4d5e6f7a8b). API secrets don't work here.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Save

    private var saveSection: some View {
        Section {
            if let error = validationError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.subheadline)
            }

            Button {
                saveCredentials()
            } label: {
                HStack {
                    Spacer()
                    Text("Save")
                        .font(.headline)
                    Spacer()
                }
            }

            if saved {
                Label("Settings saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private func saveCredentials() {
        validationError = nil
        saved = false

        let trimmedURL = nsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            validationError = "Please enter a Nightscout URL."
            return
        }
        let lc = trimmedURL.lowercased()
        guard lc.hasPrefix("https://") || lc.hasPrefix("http://") else {
            validationError = "URL must start with https://"
            return
        }
        let trimmedToken = nsToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            validationError = "Please enter an access token."
            return
        }

        KeychainManager.nightscoutURL = NightscoutSync.normalizedBase(trimmedURL)
        KeychainManager.accessToken = trimmedToken
        nsURL = KeychainManager.nightscoutURL ?? trimmedURL
        saved = true

        Task {
            await NightscoutSync.resetSession()
            await NightscoutSync.prefetchJWT()
            AppServices.shared.syncQueue.resetFailedAndRetry()
        }
    }

    // MARK: - Connection Test

    private var connectionTestSection: some View {
        Section {
            Button {
                runConnectionTest()
            } label: {
                HStack {
                    Label("Test connection", systemImage: "network")
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing)

            if let result = testResult {
                if let info = result.serverInfo {
                    LabeledContent("Server", value: info)
                        .font(.subheadline)
                }
                if let subject = result.subject {
                    LabeledContent("Token", value: subject)
                        .font(.subheadline)
                }
                testRow("Connection", status: result.reachable, detail: result.reachableDetail)
                if result.reachable == .ok {
                    testRow("Read", status: result.canRead, detail: result.readDetail)
                    testRow("Write", status: result.canWrite, detail: result.writeDetail)
                }
            }
        } header: {
            Text("Connection Test")
        } footer: {
            Text("Tests the URL and access token (also before saving). Nothing is written to Nightscout during the test.")
        }
    }

    private func testRow(_ title: String,
                         status: ConnectionTestResult.Status,
                         detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: status))
                .foregroundStyle(color(for: status))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func icon(for status: ConnectionTestResult.Status) -> String {
        switch status {
        case .ok:      return "checkmark.circle.fill"
        case .failed:  return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private func color(for status: ConnectionTestResult.Status) -> Color {
        switch status {
        case .ok:      return .green
        case .failed:  return .red
        case .unknown: return .orange
        }
    }

    private func runConnectionTest() {
        let url = nsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !nsToken.isEmpty else {
            validationError = "Enter URL and access token before testing."
            return
        }
        validationError = nil
        testing = true
        testResult = nil
        let token = nsToken
        Task {
            let result = await NightscoutSync.testConnection(urlString: url, token: token)
            testResult = result
            testing = false
        }
    }

    // MARK: - Units

    private var unitSection: some View {
        Section {
            Picker("Display unit", selection: $unitRaw) {
                ForEach(GlucoseUnit.allCases) { unit in
                    Text(unit.label).tag(unit.rawValue)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Display Unit")
        } footer: {
            Text("Only changes how values are shown. Apple Health and Nightscout always receive the exact meter value in mg/dL.")
        }
    }

    // MARK: - HealthKit

    private var healthKitSection: some View {
        Section("Apple Health") {
            HStack {
                Image(systemName: "heart.fill").foregroundStyle(Theme.crimson)
                Text("Write access")
                Spacer()
                Text(healthKitStatusText)
                    .foregroundStyle(healthKit.status == .authorized ? Theme.connected : Theme.secondaryText)
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
        case .authorized:    return "Allowed"
        case .denied:        return "Denied"
        case .notDetermined: return "Not requested"
        case .unavailable:   return "Unavailable"
        }
    }

    // MARK: - About

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
