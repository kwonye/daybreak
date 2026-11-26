import EvergreenKit
import SwiftUI

struct UpdatesView: View {
    private enum Confirmation {
        case individual(UpdateItem)
        case all([UpdateItem])

        var title: String {
            switch self {
            case .individual(let item): "Update \(item.name)?"
            case .all(let items): items.count == 1 ? "Update 1 app?" : "Update \(items.count) apps?"
            }
        }
    }

    let model: UpdatesModel
    @State private var search = ""
    @State private var confirm: Confirmation?

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
                let items = visible.filter { !$0.isMacAppStoreApp }
                let storeApps = visible.filter(\.isMacAppStoreApp)
                List {
                    section("Updates available", items: items.filter { $0.status == .available })
                    section("Newer releases", items: items.filter { $0.status == .newerRelease })
                    section("System", items: items.filter { $0.path == nil && $0.status != .available })
                    section("Mac App Store", items: storeApps.filter { $0.status == .available }
                            + storeApps.filter { $0.status == .newerRelease }
                            + storeApps.filter { $0.status != .available && $0.status != .newerRelease })
                    section("Other apps", items: items.filter {
                        $0.path != nil && $0.status != .available && $0.status != .newerRelease && $0.status != .current
                    })
                    section("Up to date", items: items.filter { $0.path != nil && $0.status == .current })
                }
                .listStyle(.inset)
                .accessibilityIdentifier("updates.list")
            }
        }
        .navigationTitle("Updates")
        .searchable(text: $search, placement: .toolbar, prompt: "Find software")
        .task { await model.load() }
        .onChange(of: model.canCheck) {
            if model.canCheck { Task { await model.load() } }
        }
        .confirmationDialog(confirm?.title ?? "Update apps?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { plan in
            switch plan {
            case .individual(let item):
                Button("Update") { Task { await model.install(item) } }
            case .all(let items):
                Button("Update All") { Task { await model.installAll(items) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            switch plan {
            case .individual(let item):
                Text(confirmationMessage(for: item))
            case .all(let items):
                let message = "Save your work first. Evergreen updates apps one at a time and may close and reopen running apps."
                Text(items.contains(where: \.isMacAppStoreApp)
                     ? message + " macOS may ask for administrator approval." : message)
            }
        }
        .alert("Updates", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            if model.offerAppStoreOnError {
                Button("Open App Store", action: model.openAppStore)
            }
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private func confirmationMessage(for item: UpdateItem) -> String {
        let message = item.isRunning
            ? "Save your work first. Evergreen may close and reopen this app to finish the update."
            : "Evergreen will update the installed app."
        return item.isMacAppStoreApp ? message + " macOS may ask for administrator approval." : message
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
                if let progress = model.batchProgress {
                    ProgressView(value: Double(progress.current - 1), total: Double(progress.total))
                        .controlSize(.small)
                        .accessibilityLabel("Update progress")
                } else if let checkedAt = model.checkedAt, !model.isChecking {
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
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!model.canCheck)
                .accessibilityIdentifier("updates.check")
            Button("Update All…") { confirm = .all(model.batchCandidates) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canCheck || model.batchCandidates.isEmpty)
                .accessibilityIdentifier("updates.updateAll")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 19)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String {
        if let progress = model.batchProgress { return "Updating \(progress.current) of \(progress.total)…" }
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
                        if item.action == .install { confirm = .individual(item) } else { model.open(item) }
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
            status
                .frame(width: 128, alignment: .leading)
            primaryAction
                .frame(width: 116)
        }
        .padding(.vertical, 6)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
    }

    private var status: some View {
        HStack(spacing: 6) {
            Group {
                if isInstalling {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: statusSymbol)
                }
            }
            .frame(width: 16)
            .accessibilityHidden(true)
            Text(isInstalling ? "Updating…" : statusTitle)
                .lineLimit(1)
        }
        .font(.callout)
        .foregroundStyle(isInstalling ? .secondary : statusColor)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let action = item.action, !isInstalling {
            Button(action: activate) {
                Text(action.title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(action == .install && !canInstall)
            .accessibilityLabel("\(action.title) for \(item.name)")
        } else {
            Color.clear.frame(height: 0).accessibilityHidden(true)
        }
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
        case .current: item.isMacAppStoreApp ? "Latest listed" : "Up to date"
        case .newerRelease: "Newer release"
        case .checkInApp: "Check manually"
        case .openUpdater: item.action == .install ? "Check and update" : "Check manually"
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
