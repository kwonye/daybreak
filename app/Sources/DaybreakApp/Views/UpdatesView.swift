import DaybreakKit
import SwiftUI

struct UpdatesView: View {
    let model: UpdatesModel
    @State private var search = ""
    @State private var confirm: UpdateItem?
    @State private var editingRepository: UpdateItem?

    private var visible: [UpdateItem] {
        model.items.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || ($0.bundleID?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.state.errorMessage {
                ErrorStateView(title: "Couldn’t Load Updates", message: error) {
                    Task { await model.check() }
                }
            } else if model.state.isLoading && model.items.isEmpty {
                LoadingView(message: "Finding apps…")
            } else if visible.isEmpty && !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List {
                    section("Updates available", items: visible.filter { $0.status == .available })
                    section("Newer releases", items: visible.filter { $0.status == .newerRelease })
                    section("Other software", items: visible.filter { $0.status != .available && $0.status != .newerRelease && $0.status != .current })
                    section("Up to date", items: visible.filter { $0.status == .current })
                }
                .listStyle(.inset)
                .accessibilityIdentifier("updates.list")
            }
        }
        .navigationTitle("Updates")
        .searchable(text: $search, placement: .toolbar, prompt: "Find software")
        .task { await model.load() }
        .sheet(item: $editingRepository) { item in
            ReleaseRepositorySheet(item: item, model: model)
        }
        .confirmationDialog("Update \(confirm?.name ?? "app")?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { item in
            Button("Update") { Task { await model.install(item) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.isRunning
                 ? "Save your work first. Daybreak may close and reopen this app to finish the update."
                 : "Daybreak will update the installed app.")
        }
        .alert("Updates", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary).font(.title2.weight(.semibold))
                    .accessibilityIdentifier("updates.summary")
                if let checkedAt = model.checkedAt, !model.isChecking {
                    Text("Last checked \(checkedAt, style: .relative) ago")
                        .foregroundStyle(.secondary)
                } else if !model.isChecking {
                    Text("Check for updates to apps and macOS.")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if model.isChecking {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Checking for updates")
            }
            Button("Check for Updates") { Task { await model.check() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canCheck)
                .accessibilityIdentifier("updates.check")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 19)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String {
        if model.isChecking { return "Checking for updates…" }
        if model.checkedAt != nil {
            let count = model.hasUpdates
            if count == 1 { return "1 update available" }
            if count > 1 { return "\(count) updates available" }
            return "Update check complete"
        }
        return "Software Updates"
    }

    @ViewBuilder
    private func section(_ title: String, items: [UpdateItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    UpdateListRow(item: item, isInstalling: model.installingID == item.id,
                                  canInstall: model.canCheck, activate: {
                        if item.action == .install { confirm = item } else { model.open(item) }
                    }, editRepository: {
                        editingRepository = item
                    })
                    .accessibilityIdentifier("updates.row.\(item.bundleID ?? "macos")")
                }
            }
        }
    }
}

private struct UpdateListRow: View {
    let item: UpdateItem
    let isInstalling: Bool
    let canInstall: Bool
    let activate: () -> Void
    let editRepository: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let path = item.path {
                AppIconView(path: path, size: 35)
            } else {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 35, height: 35)
                    .foregroundStyle(.secondary)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium))
                Text(versions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if isInstalling {
                Text("Updating…").font(.callout).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            } else {
                Label(statusTitle, systemImage: statusSymbol)
                    .font(.callout)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: true, vertical: false)
                if let action = item.action {
                    Button(action.title, action: activate)
                        .buttonStyle(.bordered)
                        .disabled(action == .install && !canInstall)
                        .accessibilityLabel("\(action.title) for \(item.name)")
                }
            }
            if item.bundleID != nil, item.status == .checkInApp || item.status == .failed || item.repository != nil {
                Menu {
                    Button(item.repository == nil ? "Track Release Page…" : "Edit Release Page…", action: editRepository)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!canInstall)
                .accessibilityLabel("More actions for \(item.name)")
            }
        }
        .padding(.vertical, 6)
    }

    private var versions: String {
        let installed = item.installedVersion.isEmpty ? "Version unavailable" : item.installedVersion
        if item.status == .available || item.status == .newerRelease,
           !item.offeredVersion.isEmpty, item.offeredVersion != installed {
            return "\(installed) → \(item.offeredVersion)"
        }
        return installed
    }

    private var statusTitle: String {
        switch item.status {
        case .readyToCheck: "Ready to check"
        case .available: "Update available"
        case .current: "Up to date"
        case .newerRelease: "Newer release"
        case .checkInApp, .openUpdater: "Check manually"
        case .excluded: "Excluded"
        case .inconclusive: "Check needed"
        case .failed: "Check failed"
        }
    }

    private var statusSymbol: String {
        switch item.status {
        case .available, .newerRelease: "arrow.down.circle.fill"
        case .current: "checkmark.circle"
        case .checkInApp, .openUpdater: "arrow.up.right.circle"
        case .failed: "exclamationmark.circle"
        case .excluded: "minus.circle"
        case .readyToCheck, .inconclusive: "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .available, .newerRelease: .accentColor
        case .failed: .orange
        default: .secondary
        }
    }
}

private struct ReleaseRepositorySheet: View {
    let item: UpdateItem
    let model: UpdatesModel
    @Environment(\.dismiss) private var dismiss
    @State private var input: String
    @State private var isSaving = false

    init(item: UpdateItem, model: UpdatesModel) {
        self.item = item
        self.model = model
        _input = State(initialValue: item.repository?.releasesURL.absoluteString ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Track Releases for \(item.name)").font(.headline)
            Text("Paste the developer’s public release page to see when a newer version is published.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://github.com/owner/project/releases", text: $input)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Release page URL")
            HStack {
                if item.repository != nil {
                    Button("Remove", role: .destructive) { save(nil) }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    if let repository = ReleaseRepository(input) { save(repository) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ReleaseRepository(input) == nil)
            }
        }
        .disabled(isSaving)
        .padding(22)
        .frame(width: 430)
    }

    private func save(_ repository: ReleaseRepository?) {
        isSaving = true
        Task {
            if await model.saveRepository(repository, for: item) { dismiss() }
            isSaving = false
        }
    }
}
