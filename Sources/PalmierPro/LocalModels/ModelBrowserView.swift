import SwiftUI

struct ModelBrowserView: View {
    @EnvironmentObject var registry: LocalModelRegistry
    @EnvironmentObject var downloadManager: ModelDownloadManager
    @EnvironmentObject var modelPool: ModelPool

    @State private var selectedCategory: ModelCategory = .tts
    @State private var searchText = ""
    @State private var sortBy: ModelSortOption = .downloads
    @State private var mlxOnly = true
    @State private var remoteModels: [HFModel] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Category", selection: $selectedCategory) {
                ForEach(ModelCategory.allCases, id: \.self) { cat in
                    Label(cat.displayName, systemImage: cat.icon).tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppTheme.Spacing.lgXl)
            .padding(.top, AppTheme.Spacing.md)

            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                TextField("Search models...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await search() } }
                Toggle("MLX Only", isOn: $mlxOnly)
                    .toggleStyle(.switch)
                    .fixedSize()
            }
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.Background.surfaceColor)

            HStack {
                Picker("Sort", selection: $sortBy) {
                    ForEach(ModelSortOption.allCases, id: \.self) { opt in
                        Text(opt.displayName).tag(opt)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
                Button("Search") { Task { await search() } }
                    .disabled(isLoading)
            }
            .padding(.horizontal, AppTheme.Spacing.lgXl)
            .padding(.vertical, AppTheme.Spacing.sm)

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Searching HuggingFace...")
                Spacer()
            } else if let errorMessage {
                Spacer()
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                Spacer()
            } else if remoteModels.isEmpty {
                Spacer()
                Text("Search for \(selectedCategory.displayName) models")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: AppTheme.Spacing.sm) {
                        ForEach(remoteModels) { model in
                            HFModelRow(
                                model: model,
                                registry: registry,
                                downloadManager: downloadManager,
                                modelPool: modelPool,
                                category: selectedCategory
                            )
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.lgXl)
                    .padding(.vertical, AppTheme.Spacing.md)
                }
            }
        }
        .navigationTitle("Model Browser")
        .task { await search() }
    }

    private func search() async {
        isLoading = true
        errorMessage = nil
        do {
            remoteModels = try await registry.searchModels(
                query: searchText,
                category: selectedCategory,
                sort: sortBy,
                mlxOnly: mlxOnly
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct HFModelRow: View {
    let model: HFModel
    @ObservedObject var registry: LocalModelRegistry
    @ObservedObject var downloadManager: ModelDownloadManager
    @ObservedObject var modelPool: ModelPool
    let category: ModelCategory

    private var isInstalled: Bool {
        registry.models.contains { $0.id == model.id && $0.installPath != nil }
    }

    private var localModel: LocalModel? {
        registry.models.first { $0.id == model.id }
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(model.displayName)
                        .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                    if model.isMLX {
                        Text("MLX")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.Accent.primary.opacity(0.2))
                            .foregroundStyle(AppTheme.Accent.primary)
                            .clipShape(Capsule())
                    }
                    if model.gated {
                        Text("Gated")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                Text(model.id)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                HStack(spacing: AppTheme.Spacing.md) {
                    Label(modelSizeDisplay, systemImage: "internaldrive")
                    Label("\(model.downloads.formatted()) downloads", systemImage: "arrow.down.circle")
                    Label("\(model.likes) likes", systemImage: "heart")
                }
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            }

            Spacer()

            if let local = localModel, local.state == .loading {
                ProgressView()
                    .controlSize(.small)
            } else if isInstalled, let local = localModel {
                VStack(spacing: AppTheme.Spacing.xxs) {
                    Button("Use") {
                        Task { try? await modelPool.loadModel(local) }
                    }
                    Button("Remove") {
                        Task {
                            await modelPool.evictModel(model.id)
                            registry.removeModel(model.id)
                        }
                    }
                    .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("Download") {
                    Task { await startDownload() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.gated)
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Background.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }

    private var modelSizeDisplay: String {
        let total = model.siblings?.compactMap(\.size).reduce(0, +) ?? 0
        guard total > 0 else { return "Unknown size" }
        let gb = Double(total) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(total) / 1_048_576)
    }

    private func startDownload() async {
        let size = downloadManager.modelSize(for: model)
        let localModel = LocalModel(
            id: model.id,
            repoId: model.id,
            category: category,
            displayName: model.displayName,
            state: .dormant,
            sizeBytes: size,
            quantization: nil,
            architecture: model.libraryName,
            installPath: nil,
            isGated: model.gated,
            license: nil
        )
        registry.addModel(localModel)

        let downloadExtensions = [".safetensors", ".json", ".txt", ".model"]
        let downloadNames = ["tokenizer.json", "config.json"]
        let files = model.siblings?.map(\.rfilename).filter { name in
            downloadExtensions.contains(where: { name.hasSuffix($0) }) || downloadNames.contains(name)
        } ?? ["config.json"]

        downloadManager.downloadModel(localModel, files: files)
    }
}
