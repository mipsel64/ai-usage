import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = UsageStore()
    private var monitor: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NonCollapsingSidebar.forgetSavedLayout(in: .standard)
    }

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

let menuBarSymbolPointSize: CGFloat = 18

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            QuotaMenu(store: delegate.store)
        } label: {
            Image(nsImage: Self.menuBarSymbol)
                .accessibilityLabel("AI Usage")
        }.menuBarExtraStyle(.window)
        Settings {
            PreferencesView(store: delegate.store)
        }
        // Settings forces the preference toolbar style, which centres toolbar items; each pane draws its own header instead.
        .windowToolbarStyle(.unified(showsTitle: false))
    }

    // MenuBarExtra ignores SwiftUI font modifiers on its label, so the size is set on the NSImage.
    // The gauge is inverted: a filled disc with the dots and needle cut out.
    static var menuBarSymbol: NSImage {
        let gauge = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "AI Usage")!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: menuBarSymbolPointSize, weight: .regular))!
        let image = NSImage(size: gauge.size, flipped: false) { rect in
            // Radii are fractions of the symbol width: the ring spans 0.34–0.41 and the dots and needle end at 0.26.
            func disc(_ fraction: CGFloat) -> NSBezierPath {
                let r = rect.width * fraction
                return NSBezierPath(ovalIn: NSRect(x: rect.midX - r, y: rect.midY - r, width: 2 * r, height: 2 * r))
            }
            gauge.draw(in: rect)
            disc(0.38).fill()
            disc(0.30).addClip()
            gauge.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }
}
