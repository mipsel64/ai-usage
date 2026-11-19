import AppKit
import SwiftUI

/// A divider drag can still collapse a fixed-width sidebar, and showing it again widens the window, so the split view item refuses to collapse.
struct NonCollapsingSidebar: NSViewRepresentable {
    /// Earlier builds let the sidebar resize and collapse; AppKit restores that saved state, and a collapsed sidebar widens the window.
    static func forgetSavedLayout(in defaults: UserDefaults) {
        defaults.removeObject(forKey: "NSSplitView Subview Frames com_apple_SwiftUI_Settings_window, SidebarNavigationSplitView")
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {}

    final class Anchor: NSView {
        private weak var sidebar: NSSplitViewItem?
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let splitView = sequence(first: self, next: \.superview).lazy.compactMap { $0 as? NSSplitView }.first
            sidebar = (splitView?.delegate as? NSSplitViewController)?.splitViewItems.first
            lock()
            // SwiftUI sets canCollapse again when it updates the split view.
            observation = sidebar?.observe(\.canCollapse) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.lock() }
            }
        }

        private func lock() {
            if sidebar?.canCollapse == true { sidebar?.canCollapse = false }
        }
    }
}
