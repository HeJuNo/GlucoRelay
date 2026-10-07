import SwiftUI
import SwiftData
import UIKit

/// Long-lived services. Created as early as possible (in the app delegate) so the
/// CBCentralManager with the restore identifier exists when iOS relaunches the app in the
/// background for a Bluetooth event.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let container: ModelContainer
    let devices: DeviceStore
    let readings: GlucoseReadingStore
    let healthKit: HealthKitSync
    let syncQueue: SyncQueue
    let ble: BLEManager

    private init() {
        do {
            container = try ModelContainer(for: DeviceRecord.self, GlucoseReading.self)
        } catch {
            fatalError("Could not open the GlucoRelay database: \(error)")
        }
        let context = container.mainContext
        context.autosaveEnabled = true
        devices = DeviceStore(context: context)
        readings = GlucoseReadingStore(context: context)
        healthKit = HealthKitSync()
        syncQueue = SyncQueue(readings: readings, healthKit: healthKit)
        ble = BLEManager(devices: devices, readings: readings, syncQueue: syncQueue)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Covers CoreBluetooth state restoration (launchOptions[.bluetoothCentrals]):
        // instantiating the services recreates the central with the same restore identifier.
        _ = AppServices.shared
        return true
    }
}

@main
struct GlucoRelayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(services.ble)
                .environment(services.healthKit)
                .modelContainer(services.container)
                .preferredColorScheme(.dark)
                .tint(Theme.electricBlue)
                .task {
                    await NightscoutSync.prefetchJWT()
                    services.syncQueue.trigger()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            services.healthKit.refreshStatus()
            services.ble.connectSavedMeters()
            services.syncQueue.trigger()
        }
    }
}
