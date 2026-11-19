import QuotaCore
import SwiftUI

// Command Line Tools ship the State wrapper but not the Xcode 27 State macro plug-in.
private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
struct PreferencesView: View {
    let store: UsageStore

    @ViewState private var selection: PreferencesSelection?
    @ViewState private var secrets: [ProviderID: String] = [:]
    @ViewState private var executables: [ProviderID: URL] = [:]
    @ViewState private var errors: [ProviderID: String] = [:]
    @ViewState private var busyProviders: Set<ProviderID> = []

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            PreferencesSidebar(store: store, selection: $selection)
        } detail: {
            Group {
                switch selection {
                case .general:
                    GeneralPanel()
                case .notifications:
                    NotificationsAccountPanel(store: store)
                case .about:
                    AboutPanel()
                case let .provider(id):
                    if let provider = store.providers.first(where: { $0.id == id }) {
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
                case nil:
                    EmptyView()
                }
            }
            // The pane header takes the title bar band, as in System Settings.
            .ignoresSafeArea(.container, edges: .top)
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Preferences")
        .frame(minWidth: 720, idealWidth: 780, minHeight: 460, idealHeight: 560)
        .onAppear(perform: selectInitialProvider)
        .onReceive(NotificationCenter.default.publisher(for: .showProviderAccount), perform: selectProvider)
        .onChange(of: selection) {
            secrets.removeAll()
        }
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
