import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared
    @State private var directory = ModelDirectory.shared

    @State private var baseURLDraft: String = ""
    @State private var keyDraft: String = ""
    @State private var hasKey: Bool = false
    @State private var maskedKey: String = ""
    @State private var selectedModel: String = ProviderConfig.chatModel
    @State private var configVersion: Int = 0
    @State private var serviceDrafts: [AIService: ServiceDraft] = [:]

    private struct ServiceDraft {
        var baseURL: String = ""
        var keyDraft: String = ""
        var hasKey: Bool = false
        var maskedKey: String = ""
        var isExpanded: Bool = false
    }

    private let generationServices: [AIService] = [.tts, .image, .video, .music, .sfx, .upscale]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            providerSection
            Divider().overlay(AppTheme.Border.subtleColor)
            endpointsSection
            Divider().overlay(AppTheme.Border.subtleColor)
            mcpSection
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .providerConfigChanged)) { _ in
            configVersion &+= 1
            selectedModel = ProviderConfig.chatModel
        }
    }

    // MARK: - Provider

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            providerHeader
            baseURLField
            keyField
            modelRow
        }
    }

    private var providerHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("AI Provider")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Text("Connect any OpenAI-compatible endpoint — OpenAI, OpenRouter, or a local server. Used for chat, voiceover, and generation. Keys are stored in your macOS Keychain.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var baseURLField: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Base URL")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            HStack(spacing: AppTheme.Spacing.sm) {
                textBox(text: $baseURLDraft, placeholder: ProviderConfig.defaultBaseURL, secure: false, onSubmit: saveBaseURL)
                Button("Save", action: saveBaseURL)
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.large)
                    .disabled(baseURLDraft.trimmingCharacters(in: .whitespaces).isEmpty || baseURLDraft == ProviderConfig.baseURL)
            }
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("API Key")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            HStack(spacing: AppTheme.Spacing.sm) {
                textBox(text: $keyDraft, placeholder: hasKey ? maskedKey : "sk-...", secure: true, onSubmit: saveKey)
                keyTrailingControl
            }
        }
    }

    @ViewBuilder
    private var keyTrailingControl: some View {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save", action: saveKey)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasKey {
            Button(action: removeKey) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help("Remove API key")
        }
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Chat Model")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer()
                Button(action: fetchModels) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        if directory.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                        }
                        Text(directory.isLoading ? "Fetching…" : "Fetch models")
                            .font(.system(size: AppTheme.FontSize.sm))
                    }
                    .foregroundStyle(AppTheme.Accent.primary)
                }
                .buttonStyle(.plain)
                .disabled(!ProviderConfig.isConfigured || directory.isLoading)
            }

            modelPicker

            if let err = directory.lastError {
                Text(err)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if directory.hasLoaded {
                Text("\(directory.chatModels.count) chat models available.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        let chat = directory.chatModels
        Menu {
            if chat.isEmpty {
                Text("Fetch models to populate this list")
            }
            ForEach(chat) { m in
                Button(m.id) { selectModel(m.id) }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(selectedModel.isEmpty ? "Select a model" : selectedModel)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(selectedModel.isEmpty ? AppTheme.Text.tertiaryColor : AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.black.opacity(AppTheme.Opacity.muted))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private func textBox(text: Binding<String>, placeholder: String, secure: Bool, onSubmit: @escaping () -> Void) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text).onSubmit(onSubmit)
            } else {
                TextField(placeholder, text: text).onSubmit(onSubmit)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
        .foregroundStyle(AppTheme.Text.primaryColor)
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.black.opacity(AppTheme.Opacity.muted))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    // MARK: - Generation Endpoints

    private var endpointsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Generation Endpoints")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text("Override the base URL and API key per generation type. Empty fields use the main provider.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(generationServices) { service in
                serviceEndpointRow(service)
            }
        }
    }

    private func serviceEndpointRow(_ service: AIService) -> some View {
        let draft = Binding(
            get: { serviceDrafts[service, default: ServiceDraft()] },
            set: { serviceDrafts[service] = $0 }
        )
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                Image(systemName: service.icon)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(ProviderConfig.baseURL(for: service).isEmpty ? AppTheme.Text.mutedColor : AppTheme.Accent.primary)
                    .frame(width: AppTheme.IconSize.sm)
                Text(service.displayName)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer()
                if !ProviderConfig.baseURL(for: service).isEmpty {
                    Text("custom")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Accent.primary)
                } else {
                    Text("using main")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                Button(action: { withAnimation { draft.wrappedValue.isExpanded.toggle() } }) {
                    Image(systemName: draft.wrappedValue.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { draft.wrappedValue.isExpanded.toggle() } }
            if draft.wrappedValue.isExpanded {
                endpointFields(draft: draft, service: service)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(Color.black.opacity(AppTheme.Opacity.muted)))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin))
    }

    @ViewBuilder
    private func endpointFields(draft: Binding<ServiceDraft>, service: AIService) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                textBox(text: Binding(get: { draft.wrappedValue.baseURL }, set: { draft.wrappedValue.baseURL = $0 }), placeholder: ProviderConfig.defaultBaseURL, secure: false, onSubmit: {
                    ProviderConfig.setBaseURL(draft.wrappedValue.baseURL, for: service)
                    refresh()
                })
                Button("Save") {
                    ProviderConfig.setBaseURL(draft.wrappedValue.baseURL, for: service)
                    refresh()
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.large)
                .disabled(draft.wrappedValue.baseURL.trimmingCharacters(in: .whitespaces).isEmpty || draft.wrappedValue.baseURL == ProviderConfig.baseURL(for: service))
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                textBox(text: Binding(get: { draft.wrappedValue.keyDraft }, set: { draft.wrappedValue.keyDraft = $0 }), placeholder: draft.wrappedValue.hasKey ? draft.wrappedValue.maskedKey : "sk-...", secure: true, onSubmit: {
                    if !draft.wrappedValue.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                        ProviderConfig.setAPIKey(draft.wrappedValue.keyDraft, for: service)
                        draft.wrappedValue.keyDraft = ""
                        refresh()
                    }
                })
                if !draft.wrappedValue.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Save") {
                        ProviderConfig.setAPIKey(draft.wrappedValue.keyDraft, for: service)
                        draft.wrappedValue.keyDraft = ""
                        refresh()
                    }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .controlSize(.large)
                } else if draft.wrappedValue.hasKey {
                    Button(action: {
                        ProviderConfig.deleteAPIKey(for: service)
                        draft.wrappedValue.keyDraft = ""
                        refresh()
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: AppTheme.FontSize.md))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.large)
                    .help("Remove API key for \(service.displayName)")
                }
            }
        }
        .padding(.leading, AppTheme.Spacing.md)
    }

    private func refresh() {
        baseURLDraft = ProviderConfig.baseURL
        let key = ProviderConfig.apiKey
        hasKey = !key.isEmpty
        maskedKey = mask(key)
        selectedModel = ProviderConfig.chatModel
        directory.refreshIfNeeded()
        for service in AIService.allCases where service != .chat {
            serviceDrafts[service, default: ServiceDraft()].baseURL = ProviderConfig.baseURL(for: service)
            let sKey = ProviderConfig.apiKey(for: service)
            serviceDrafts[service, default: ServiceDraft()].hasKey = !sKey.isEmpty
            serviceDrafts[service, default: ServiceDraft()].maskedKey = mask(sKey)
        }
    }

    private func saveBaseURL() {
        let value = baseURLDraft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        ProviderConfig.setBaseURL(value)
        baseURLDraft = ProviderConfig.baseURL
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        ProviderConfig.setAPIKey(key)
        keyDraft = ""
        refresh()
    }

    private func removeKey() {
        ProviderConfig.deleteAPIKey()
        keyDraft = ""
        refresh()
    }

    private func fetchModels() {
        Task {
            let ok = await directory.refresh()
            if ok, selectedModel.isEmpty, let first = directory.chatModels.first {
                selectModel(first.id)
            }
        }
    }

    private func selectModel(_ id: String) {
        selectedModel = id
        ProviderConfig.setChatModel(id)
    }

    private func mask(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "\u{2022}", count: 32) }
        return String(repeating: "\u{2022}", count: 36) + key.suffix(4)
    }

    // MARK: - MCP server

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            mcpHeader
            mcpStatusRow
        }
    }

    private var mcpHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("MCP Server")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Lets external clients like Cursor, Claude Desktop, Claude Code, and Codex edit your timeline.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: openInstructions) {
                    HStack(spacing: 2) {
                        Text("Setup instructions")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.primary)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
    }

    private var mcpStatusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill((appState.mcpService?.isRunning ?? false) ? Color.green : AppTheme.Text.mutedColor)
                    .frame(width: 8, height: 8)

                if appState.mcpService?.isRunning ?? false {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("Running on ")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Text("127.0.0.1:\(String(MCPService.port))")
                            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                    }
                } else {
                    Text("Stopped")
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .font(.system(size: AppTheme.FontSize.sm))

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { (appState.mcpService?.isRunning ?? false) },
                    set: { appState.setMCPEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.black.opacity(AppTheme.Opacity.muted))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func openInstructions() {
        HelpWindowController.shared.show(tab: .mcp)
    }
}
