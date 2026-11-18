import QuotaCore
import SwiftUI

// Command Line Tools ship the State wrapper but not the Xcode 27 State macro plug-in.
private typealias ViewState<Value> = SwiftUI.State<Value>

private let paneTitleLeadingInset: CGFloat = 20

@MainActor
struct AccountsView: View {
    let store: UsageStore

    @ViewState private var selection: AccountSelection?
    @ViewState private var secrets: [ProviderID: String] = [:]
    @ViewState private var executables: [ProviderID: URL] = [:]
    @ViewState private var errors: [ProviderID: String] = [:]
    @ViewState private var busyProviders: Set<ProviderID> = []

    private var selectedTitle: String {
        if selection == .notifications { return "Notifications" }
        if case let .provider(id) = selection,
           let provider = store.providers.first(where: { $0.id == id }) {
            return provider.displayName
        }
        return "AI Usage"
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            AccountsSidebar(store: store, selection: $selection)
        } detail: {
            Group {
                if selection == .notifications {
                    NotificationsAccountPanel(store: store)
                } else if case let .provider(id) = selection,
                          let provider = store.providers.first(where: { $0.id == id }) {
                    ProviderAccountPanel(
                        store: store,
                        provider: provider,
                        state: store.states[id],
                        secret: secretBinding(for: id),
                        executable: executableBinding(for: id),
                        error: errorBinding(for: id),
                        isBusy: busyBinding(for: id)
                    )
                    .id(id)
                }
            }
            .overlay(alignment: .topLeading) { paneTitle }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(selectedTitle)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 460, idealHeight: 560)
        .onAppear(perform: selectInitialProvider)
        .onReceive(NotificationCenter.default.publisher(for: .showProviderAccount), perform: selectProvider)
        .onChange(of: selection) {
            secrets.removeAll()
        }
    }

    // The Settings scene hides the standard title, so the pane title is drawn in the title bar like System Settings.
    private var paneTitle: some View {
        GeometryReader { proxy in
            Text(selectedTitle)
                .font(.title2.bold())
                .frame(height: proxy.safeAreaInsets.top)
                .padding(.leading, paneTitleLeadingInset)
                .offset(y: -proxy.safeAreaInsets.top)
        }
        .allowsHitTesting(false)
    }

    private func selectInitialProvider() {
        if selection == nil {
            selection = store.providers.first.map { .provider($0.id) }
        }
    }

    private func selectProvider(from notification: Notification) {
        guard let id = notification.object as? ProviderID,
              store.providers.contains(where: { $0.id == id }) else { return }
        selection = .provider(id)
    }

    private func secretBinding(for id: ProviderID) -> Binding<String> {
        Binding(
            get: { secrets[id] ?? "" },
            set: { secrets[id] = $0 }
        )
    }

    private func executableBinding(for id: ProviderID) -> Binding<URL?> {
        Binding(
            get: { executables[id] },
            set: { executables[id] = $0 }
        )
    }

    private func errorBinding(for id: ProviderID) -> Binding<String?> {
        Binding(
            get: { errors[id] },
            set: { errors[id] = $0 }
        )
    }

    private func busyBinding(for id: ProviderID) -> Binding<Bool> {
        Binding(
            get: { busyProviders.contains(id) },
            set: { isBusy in
                if isBusy {
                    busyProviders.insert(id)
                } else {
                    busyProviders.remove(id)
                }
            }
        )
    }
}
