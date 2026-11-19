import AppKit
import ServiceManagement
import SwiftUI

// Command Line Tools ship the State wrapper but not the Xcode 27 State macro plug-in.
private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
struct GeneralPanel: View {
    @ViewState private var status: SMAppService.Status = .notRegistered
    @ViewState private var changeFailed = false

    // An item that waits for approval is registered, so the toggle stays on and the hint explains the rest.
    nonisolated static func loginItem(for status: SMAppService.Status) -> (isOn: Bool, needsApproval: Bool) {
        switch status {
        case .enabled: (true, false)
        case .requiresApproval: (true, true)
        default: (false, false)
        }
    }

    private var openAtLogin: Binding<Bool> {
        Binding(
            get: { Self.loginItem(for: status).isOn },
            // A method reference here crashes the Swift 6.3.2 compiler of Xcode 26.5 during IR generation.
            set: { setOpenAtLogin($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            PreferencesPaneHeader(
                title: "General",
                subtitle: "Choose how AI Usage starts."
            ) {
                PreferencesSymbol(systemImage: "gearshape")
            }

            Form {
                Section {
                    Toggle("Open AI Usage at login", isOn: openAtLogin)
                        .toggleStyle(.switch)
                    if Self.loginItem(for: status).needsApproval {
                        LabeledContent {
                            Button("Open Login Items…", action: SMAppService.openSystemSettingsLoginItems)
                        } label: {
                            Label("macOS needs your approval in System Settings > General > Login Items.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if changeFailed {
                        Label("macOS could not change the login item. Try again.", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: readStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readStatus()
        }
    }

    private func readStatus() {
        status = SMAppService.mainApp.status
    }

    private func setOpenAtLogin(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            changeFailed = false
        } catch {
            changeFailed = true
        }
        readStatus()
    }
}
