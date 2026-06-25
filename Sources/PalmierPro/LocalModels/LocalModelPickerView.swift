import SwiftUI

struct LocalModelPickerView: View {
    let category: ModelCategory
    @EnvironmentObject var registry: LocalModelRegistry
    @EnvironmentObject var modelPool: ModelPool
    @EnvironmentObject var downloadManager: ModelDownloadManager
    @Binding var selectedModelId: String?

    @State private var showingBrowser = false

    private var localModels: [LocalModel] {
        registry.localModels(for: category)
    }

    private var activeModel: LocalModel? {
        modelPool.activeModel(for: category)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Label(category.displayName, systemImage: category.icon)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                Spacer()
                Button {
                    showingBrowser = true
                } label: {
                    Label("Browse", systemImage: "plus.circle")
                        .font(.system(size: AppTheme.FontSize.xs))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Accent.primary)
            }

            if localModels.isEmpty {
                HStack {
                    Image(systemName: "arrow.down.circle.dashed")
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text("No local models installed")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Spacer()
                    Button("Browse HuggingFace") { showingBrowser = true }
                        .controlSize(.small)
                }
                .padding(AppTheme.Spacing.md)
                .background(AppTheme.Background.surfaceColor)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            } else {
                Picker("Model", selection: $selectedModelId) {
                    Text("None").tag(nil as String?)
                    ForEach(localModels) { model in
                        HStack {
                            Text(model.displayName)
                            Text(model.sizeDisplay)
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        .tag(model.id as String?)
                    }
                }
                .pickerStyle(.menu)

                if let active = activeModel {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Circle()
                            .fill(active.state == .pinned ? AppTheme.Accent.primary : .green)
                            .frame(width: 6, height: 6)
                        Text(active.displayName)
                            .font(.system(size: AppTheme.FontSize.xs))
                        Text(active.sizeDisplay)
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        Spacer()
                        Button {
                            modelPool.togglePin(active.id)
                        } label: {
                            Image(systemName: active.state == .pinned ? "pin.fill" : "pin")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help(active.state == .pinned ? "Unpin (allow eviction)" : "Pin (prevent eviction)")

                        Button {
                            Task { await modelPool.evictModel(active.id) }
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Unload from memory")
                    }
                }
            }
        }
        .sheet(isPresented: $showingBrowser) {
            NavigationStack {
                ModelBrowserView()
                    .environmentObject(registry)
                    .environmentObject(downloadManager)
                    .environmentObject(modelPool)
            }
        }
    }
}

struct LocalModelsPanelView: View {
    @EnvironmentObject var registry: LocalModelRegistry
    @EnvironmentObject var modelPool: ModelPool
    @EnvironmentObject var downloadManager: ModelDownloadManager

    @State private var selectedTTS: String?
    @State private var selectedImage: String?
    @State private var selectedMusic: String?
    @State private var selectedSFX: String?
    @State private var selectedVideo: String?
    @State private var selectedUpscale: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "cpu")
                    .foregroundStyle(AppTheme.Accent.primary)
                Text("Local Models")
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                Spacer()
                if modelPool.activeModelCount > 0 {
                    Text("\(modelPool.activeModelCount) loaded · \(modelPool.memoryUsageMB) MB")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }

            if PythonServerManager.findPython() == nil {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text("Python not found")
                            .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                        Text("Install Python to run local models. Recommended: brew install uv")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    Spacer()
                }
                .padding(AppTheme.Spacing.md)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            }

            Divider()

            LocalModelPickerView(category: .tts, selectedModelId: $selectedTTS)
            LocalModelPickerView(category: .image, selectedModelId: $selectedImage)
            LocalModelPickerView(category: .music, selectedModelId: $selectedMusic)
            LocalModelPickerView(category: .sfx, selectedModelId: $selectedSFX)
            LocalModelPickerView(category: .video, selectedModelId: $selectedVideo)
            LocalModelPickerView(category: .upscale, selectedModelId: $selectedUpscale)
        }
        .padding(AppTheme.Spacing.lgXl)
        .onAppear {
            syncSelections()
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerConfigChanged)) { _ in
            syncSelections()
        }
        .onChange(of: selectedTTS) { _, newValue in
            ProviderConfig.setSelectedLocalModel(newValue, for: .tts)
        }
        .onChange(of: selectedImage) { _, newValue in
            ProviderConfig.setSelectedLocalModel(newValue, for: .image)
        }
        .onChange(of: selectedMusic) { _, newValue in
            ProviderConfig.setSelectedLocalModel(newValue, for: .music)
        }
        .onChange(of: selectedSFX) { _, newValue in
            ProviderConfig.setSelectedLocalModel(newValue, for: .sfx)
        }
        .onChange(of: selectedVideo) { _, newValue in
            ProviderConfig.setSelectedLocalModel(newValue, for: .video)
        }
        .onChange(of: selectedUpscale) { _, newValue in
            ProviderConfig.setSelectedLocalModel(newValue, for: .upscale)
        }
    }

    private func syncSelections() {
        selectedTTS = ProviderConfig.selectedLocalModel(for: .tts)
        selectedImage = ProviderConfig.selectedLocalModel(for: .image)
        selectedMusic = ProviderConfig.selectedLocalModel(for: .music)
        selectedSFX = ProviderConfig.selectedLocalModel(for: .sfx)
        selectedVideo = ProviderConfig.selectedLocalModel(for: .video)
        selectedUpscale = ProviderConfig.selectedLocalModel(for: .upscale)
    }
}
