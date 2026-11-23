import QuotaCore
import SwiftUI

// Command Line Tools ship the State wrapper but not the Xcode 27 State macro plug-in.
private typealias ViewState<Value> = SwiftUI.State<Value>

/// Sets the Claude Code version that AI Usage reports to Claude. The next Claude reading uses it.
@MainActor
struct ClaudeCodeVersionSection: View {
    var defaults: UserDefaults = .standard

    @ViewState private var draft = ""

    private var draftIsValid: Bool { ClaudeCodeVersion.isValid(draft) }

    var body: some View {
        Section {
            LabeledContent("Version sent to Claude") {
                HStack(spacing: 8) {
                    TextField("Version sent to Claude", text: $draft, prompt: Text(ClaudeCodeVersion.defaultValue))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .monospacedDigit()
                        .frame(width: 110)
                    Button("Restore Default", action: restoreDefault)
                        .disabled(draft == ClaudeCodeVersion.defaultValue)
                }
            }
            if !draftIsValid {
                Label("Enter three numbers with dots, for example \(ClaudeCodeVersion.defaultValue).", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Claude Code version")
        } footer: {
            Text("Claude lists limit resets only for a recent Claude Code version. Increase this value when the resets disappear. Default: \(ClaudeCodeVersion.defaultValue).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { draft = ClaudeCodeVersion.current(in: defaults) }
        .onChange(of: draft) { save() }
    }

    /// Stores each valid value as you type; an invalid value is not stored, so the last valid one stays in use.
    private func save() {
        ClaudeCodeVersion.store(draft, in: defaults)
    }

    private func restoreDefault() {
        draft = ClaudeCodeVersion.defaultValue
    }
}
