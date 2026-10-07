# GlucoRelay

Native SwiftUI iOS app (iOS 17+) that keeps your **Roche Accu-Chek Guide** meter(s) connected over
Bluetooth LE and relays every new blood glucose reading to **Apple Health** and **Nightscout**.

- Standard Bluetooth Glucose Profile (service `0x1808`): Glucose Measurement `0x2A18`
  notifications + Record Access Control Point `0x2A52` ("records after last sequence number")
- Serial number from Device Information `0x180A` / `0x2A25` – used as HealthKit
  `HKDevice.localIdentifier` and Nightscout note `SN:<serial>`
- Multiple meters at once, always-on in the background (`bluetooth-central` + state restoration)
- HealthKit `bloodGlucose` samples with sync identifier `<serial>-<sequence>` (no duplicates)
- Nightscout `mbg` entries (always mg/dL) via JWT from the access token – same auth as
  [nightscout-remote](https://github.com/HeJuNo/nightscout-remote); token needs **readable + careportal**
- Display unit selectable (mg/dL / mmol/L), history list, per-meter connection status

## Build in the browser (GitHub Actions → TestFlight)

Identical setup to nightscout-remote and the Loop browser build – the same repository secrets work:

| Secret | |
|---|---|
| `TEAMID` | Apple Developer Team ID |
| `FASTLANE_ISSUER_ID`, `FASTLANE_KEY_ID`, `FASTLANE_KEY` | App Store Connect API key |
| `GH_PAT` | GitHub token (repo, workflow) |
| `MATCH_PASSWORD` | Password of your `Match-Secrets` repository |

Run the workflows in order: **1. Secrets pruefen → 2. Bundle-ID anlegen (+ HealthKit) →
3. Zertifikate erstellen → 4. GlucoRelay bauen**. Before the first upload create the app in
App Store Connect with bundle ID `com.<TEAMID>.glucorelay`. Build 4 also runs monthly
(1st, 06:17 UTC) so TestFlight never expires.

`0. Compile check` builds for the simulator and runs the parser unit tests on every push (no secrets needed).

## Pairing

1. Meter: *Settings ▸ Wireless ▸ Pairing* (or hold OK while off until the BT symbol flashes)
2. App: *Settings ▸ Add Meter*, tap the meter, enter the PIN shown on the meter
3. Serial number appears → optional nickname → **Save Meter**

Local development: `brew install xcodegen && xcodegen generate && open GlucoRelay.xcodeproj`.

> GlucoRelay is not a medical device.
