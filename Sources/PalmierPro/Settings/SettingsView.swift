import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case models
    case localModels
    case agent
    case storage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .models: return "Models"
        case .localModels: return "Local AI"
        case .agent: return "Agent"
        case .storage: return "Storage"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "square.stack.3d.up"
        case .localModels: return "cpu"
        case .agent: return "paperplane"
        case .storage: return "internaldrive"
        }
    }
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab

    init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    private var visibleTabs: [SettingsTab] { SettingsTab.allCases }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selectedTab: $selectedTab, visibleTabs: visibleTabs)
                .frame(width: 220)

            SettingsDetail(tab: selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(AppTheme.Opacity.medium))
        }
        .frame(minWidth: 760, idealWidth: 980, minHeight: 480, idealHeight: 640)
        .background(.ultraThinMaterial)
        .focusEffectDisabled()
        .onAppear {
            if !visibleTabs.contains(selectedTab) {
                selectedTab = visibleTabs.first ?? .general
            }
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selectedTab: SettingsTab
    let visibleTabs: [SettingsTab]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabList
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var tabList: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            ForEach(visibleTabs) { tab in
                SidebarRowButton(
                    label: tab.label,
                    systemImage: tab.systemImage,
                    isSelected: selectedTab == tab,
                    action: { selectedTab = tab }
                )
            }
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.md)
    }
}

private struct SettingsDetail: View {
    let tab: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tab.label)
                    .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
            }
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.top, AppTheme.Spacing.xxl)
            .padding(.bottom, AppTheme.Spacing.lgXl)

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    switch tab {
                    case .general:
                        NotificationsPane()
                        PrivacyPane()
                    case .models:
                        ModelsPane()
                    case .localModels:
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                            SettingsToggleRow(
                                title: "Enable Local AI",
                                subtitle: "Run AI models locally on your Mac using MLX",
                                isOn: Binding(
                                    get: { ProviderConfig.isLocalAIEnabled },
                                    set: { newValue in
                                        ProviderConfig.isLocalAIEnabled = newValue
                                        if !newValue {
                                            // Clear all local model selections when disabling
                                            for cat in ModelCategory.allCases {
                                                ProviderConfig.setSelectedLocalModel(nil, for: cat)
                                            }
                                        }
                                        Task {
                                            if newValue {
                                                await AppState.shared.startLocalServer()
                                            } else {
                                                AppState.shared.pythonServer.stop()
                                            }
                                        }
                                    }
                                )
                            )

                            if ProviderConfig.isLocalAIEnabled {
                                LocalServerStatusView()
                            }

                            Divider()

                            LocalModelsPanelView()
                        }
                    case .agent:
                        AgentPane()
                    case .storage:
                        StoragePane()
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.xlXxl)
                .padding(.bottom, AppTheme.Spacing.xlXxl)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(subtitle)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AppTheme.Spacing.lg)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, AppTheme.Spacing.xxs)
        }
    }
}

private struct LocalServerStatusView: View {
    @ObservedObject private var server: PythonServerManager = AppState.shared.pythonServer

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Circle()
                .fill(server.isRunning ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(server.isRunning
                 ? "Server running on port \(server.port)"
                 : "Starting server...")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            Button("Stop") {
                server.stop()
            }
            .controlSize(.small)
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Background.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var hosting: NSHostingController<AnyView>?

    private init() {
        let state = AppState.shared
        let initialView = SettingsView()
            .environmentObject(state.modelRegistry)
            .environmentObject(state.modelPool)
            .environmentObject(state.modelDownloadManager)
            .tint(AppTheme.Accent.primary)
        let hosting = NSHostingController(rootView: AnyView(initialView))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 980, height: 640))
        window.minSize = NSSize(width: 760, height: 480)
        window.title = "Settings"
        window.setFrameAutosaveName("PalmierProSettings-v2")
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AppTheme.Background.base.withAlphaComponent(0.4)
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.center()
        self.hosting = hosting
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(tab: SettingsTab? = nil) {
        if let tab {
            let state = AppState.shared
            hosting?.rootView = AnyView(
                SettingsView(initialTab: tab)
                    .environmentObject(state.modelRegistry)
                    .environmentObject(state.modelPool)
                    .environmentObject(state.modelDownloadManager)
                    .id(UUID())
                    .tint(AppTheme.Accent.primary)
            )
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
