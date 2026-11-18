import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = UsageStore()
    private var monitor: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        monitor = Task { await store.monitor() }
    }

    func applicationWillTerminate(_ notification: Notification) { monitor?.cancel() }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            ZaiCallbackRouter.shared.receive(url)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            QuotaMenu(store: delegate.store)
        } label: {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .accessibilityLabel("AI Usage")
        }.menuBarExtraStyle(.window)
        Settings {
            AccountsView(store: delegate.store)
        }
    }
}
