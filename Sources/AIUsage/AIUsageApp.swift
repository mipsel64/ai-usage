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

private let menuBarSymbolPointSize: CGFloat = 18

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            QuotaMenu(store: delegate.store)
        } label: {
            Image(nsImage: menuBarSymbol)
                .accessibilityLabel("AI Usage")
        }.menuBarExtraStyle(.window)
        Settings {
            PreferencesView(store: delegate.store)
        }
        // Settings forces the preference toolbar style, which centres toolbar items; each pane draws its own header instead.
        .windowToolbarStyle(.unified(showsTitle: false))
    }

    // MenuBarExtra ignores SwiftUI font modifiers on its label, so the size is set on the NSImage.
    private var menuBarSymbol: NSImage {
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "AI Usage")!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: menuBarSymbolPointSize, weight: .regular))!
        image.isTemplate = true
        return image
    }
}
