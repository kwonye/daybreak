import AppKit
import Combine
import EvergreenKit
import SwiftUI

struct UpdatesView: View {
    let model: UpdatesModel
    let config: ConfigModel
    let scope: UpdatesModel.Scope
    @Environment(\.undoManager) private var undoManager
    @State private var runningApps = Set<ApplicationIdentity>()
    @State private var search = ""
    @State private var batchConfirmation: [UpdateItem]?

    private var isBrew: Bool { scope == .brew }
    private var title: String { isBrew ? "Brew" : "Apps" }
    private var accessibilityPrefix: String { isBrew ? "brew" : "updates" }
    private var scopedItems: [UpdateItem] { model.items.filter(scope.includes) }

    private var duplicatePaths: Set<String> {
        let apps = model.items.filter { $0.path != nil }
        let groups = [Dictionary(grouping: apps, by: { $0.name.localizedLowercase }),
                      Dictionary(grouping: apps, by: { $0.bundleID ?? $0.id })]
        return Set(groups.flatMap { $0.values.filter { $0.count > 1 }.flatMap { $0.compactMap(\.path) } })
    }

    private var visible: [UpdateItem] {
        scopedItems.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || ($0.bundleID?.localizedCaseInsensitiveContains(search) ?? false)
                || ($0.path?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.state.errorMessage {
                ErrorStateView(title: isBrew ? "Couldn’t Load Brew" : "Couldn’t Load Updates", message: error) {
                    Task { await model.check() }
                }
            } else if (model.state.isLoading || model.isChecking) && scopedItems.isEmpty {
                LoadingView(message: isBrew ? "Finding Homebrew packages…" : "Finding apps…")
            } else if visible.isEmpty && !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if isBrew && visible.isEmpty {
                ContentUnavailableView("No Homebrew Packages", systemImage: "shippingbox",
                                       description: Text("Installed formulae and casks appear here."))
            } else {
                List {
                    if isBrew { brewSections } else { softwareSections }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("\(accessibilityPrefix).list")
            }
        }
        .navigationTitle(title)
        .searchable(text: $search, placement: .toolbar, prompt: isBrew ? "Find packages" : "Find software")
        .onAppear(perform: refreshRunningApps)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .receive(on: RunLoop.main)) { _ in refreshRunningApps() }
        .task { await model.load() }
        .onChange(of: config.patterns) { Task { await model.load() } }
        .onChange(of: model.canCheck) {
            if model.canCheck { Task { await model.load() } }
        }
        .confirmationDialog(batchTitle,
                            isPresented: Binding(get: { batchConfirmation != nil },
                                                 set: { if !$0 { batchConfirmation = nil } }),
                            titleVisibility: .visible, presenting: batchConfirmation) { items in
            Button("Update All") { Task { await model.installAll(items, in: scope) } }
            Button("Cancel", role: .cancel) {}
        } message: { items in
            if isBrew {
                Text(items.contains(where: \.isRunning)
                     ? "Evergreen updates packages one at a time and may close and reopen running apps."
                     : "Evergreen updates the selected Homebrew packages one at a time.")
            } else {
                let message = "Save your work first. Evergreen updates apps one at a time and may close and reopen running apps."
                Text(items.contains(where: \.isMacAppStoreApp)
                     ? message + " macOS may ask for administrator approval." : message)
            }
        }
        .alert(title, isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            if model.offerAppStoreOnError {
                Button("Open App Store", action: model.openAppStore)
            }
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    @ViewBuilder
    private var brewSections: some View {
        section("Updates available", items: visible.filter { $0.status == .available || $0.status == .newerRelease })
        section("Pinned and excluded", items: visible.filter { $0.status == .excluded })
        section("Other packages", items: visible.filter {
            $0.status != .available && $0.status != .newerRelease && $0.status != .excluded && $0.status != .current
        })
        section("Up to date", items: visible.filter { $0.status == .current })
    }

    @ViewBuilder
    private var softwareSections: some View {
        let items = visible.filter { !$0.isMacAppStoreApp }
        let storeApps = visible.filter(\.isMacAppStoreApp)
        section("Updates available", items: items.filter { $0.path != nil && $0.status == .available })
        section("Newer releases", items: items.filter { $0.status == .newerRelease })
        section("System", items: items.filter { $0.path == nil },
                headerAction: ("Open System Settings", model.openSystemSettings))
        section("Mac App Store", items: storeApps.filter { $0.status == .available }
                + storeApps.filter { $0.status == .newerRelease }
                + storeApps.filter { $0.status != .available && $0.status != .newerRelease },
                headerAction: ("Open App Store Updates", model.openAppStore))
        section("Other apps", items: items.filter {
            $0.path != nil && $0.status != .available && $0.status != .newerRelease && $0.status != .current
        })
        section("Up to date", items: items.filter { $0.path != nil && $0.status == .current })
    }

    private var batchTitle: String {
        let count = batchConfirmation?.count ?? 0
        let item = isBrew ? "package" : "app"
        return count == 1 ? "Update 1 \(item)?" : "Update \(count) \(item)s?"
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: isBrew ? "shippingbox.fill" : "arrow.down.app.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary).font(.title2.weight(.semibold))
                    .accessibilityIdentifier("\(accessibilityPrefix).summary")
                if let progress = model.batchProgress(in: scope) {
                    ProgressView(value: Double(progress.current - 1), total: Double(progress.total))
                        .controlSize(.small)
                        .accessibilityLabel("Update progress")
                } else if let active = model.installingScope, active != scope {
                    Text(active == .brew ? "Brew updates in progress" : "App updates in progress")
                        .foregroundStyle(.secondary)
                } else if let checkedAt = model.checkedAt, !model.isChecking {
                    Text("Last checked \(checkedAt, style: .relative) ago")
                        .foregroundStyle(.secondary)
                } else if !model.isChecking {
                    Text(isBrew ? "Check for updates to Homebrew formulae and casks." : "Check for updates to apps and macOS.")
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
                .accessibilityIdentifier("\(accessibilityPrefix).check")
            Button("Update All…") { batchConfirmation = model.batchCandidates(in: scope).map(withLiveRunningStatus) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canCheck || model.batchCandidates(in: scope).isEmpty)
                .accessibilityIdentifier("\(accessibilityPrefix).updateAll")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 19)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String {
        if let progress = model.batchProgress(in: scope) { return "Updating \(progress.current) of \(progress.total)…" }
        if model.installingScope == scope { return isBrew ? "Updating package…" : "Updating app…" }
        if model.isChecking { return "Checking for updates…" }
        if model.checkedAt != nil {
            let count = model.updateCount(in: scope)
            if count == 1 { return "1 update available" }
            if count > 1 { return "\(count) updates available" }
            return "Update check complete"
        }
        return isBrew ? "Homebrew Updates" : "Software Updates"
    }

    private func refreshRunningApps() {
        runningApps = Set(NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, app.activationPolicy != .prohibited,
                  let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
            return ApplicationIdentity(bundleID: id, path: url.path)
        })
    }

    private func withLiveRunningStatus(_ item: UpdateItem) -> UpdateItem {
        guard let path = item.path, let id = item.bundleID else { return item }
        let running = ApplicationIdentity(bundleID: id, path: path)
        return item.withRunningStatus(runningApps.contains(running))
    }

    @ViewBuilder
    private func appActions(for item: UpdateItem) -> some View {
        if let path = item.path, let id = item.bundleID {
            if let exact = config.exactEntry(for: id) {
                Button("Remove from Whitelist") { config.remove([exact.pattern], undoManager: undoManager) }
                    .disabled(!config.canEdit || !model.canCheck)
            } else if !Whitelist.matches(patterns: config.patterns, bundleID: id) {
                Button("Add to Whitelist") { config.add(id, undoManager: undoManager) }
                    .disabled(!config.canEdit || !model.canCheck)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button("Copy Bundle ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(id, forType: .string)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [UpdateItem],
                         headerAction: (title: String, run: () -> Void)? = nil) -> some View {
        if !items.isEmpty || (headerAction != nil && search.isEmpty) {
            let copies = duplicatePaths
            UpdateSection(title: title, hasRows: !items.isEmpty, expandsAutomatically: !search.isEmpty || items.contains {
                $0.status == .available || $0.status == .newerRelease
            }, headerAction: headerAction) {
                ForEach(items) { item in
                    let current = withLiveRunningStatus(item)
                    UpdateListRow(item: current, location: item.path.flatMap { copies.contains($0) ? $0 : nil },
                                  showsAction: headerAction == nil || item.action == .install,
                                  isInstalling: model.installingID == item.id,
                                  canInstall: model.canCheck, activate: {
                        if current.action == .install {
                            Task { await model.install(current) }
                        } else {
                            model.open(current)
                        }
                    })
                    .contextMenu { appActions(for: current) }
                    .accessibilityIdentifier("\(accessibilityPrefix).row.\(item.bundleID ?? (item.brewPackage == nil ? "macos" : item.id))")
                }
            }
        }
    }
}

private struct UpdateSection<Rows: View>: View {
    let title: String
    let hasRows: Bool
    let expandsAutomatically: Bool
    let headerAction: (title: String, run: () -> Void)?
    @ViewBuilder let rows: () -> Rows
    @State private var expansionOverride: Bool?

    private var isExpanded: Bool { expansionOverride ?? expandsAutomatically }

    var body: some View {
        Section(isExpanded: Binding(get: { isExpanded }, set: { expansionOverride = $0 })) {
            rows()
        } header: {
            HStack {
                if hasRows {
                    Button {
                        expansionOverride = !isExpanded
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .frame(width: 12)
                                .accessibilityHidden(true)
                            Text(title)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                } else {
                    Text(title)
                    Spacer()
                }
                if let headerAction {
                    Button(headerAction.title, action: headerAction.run)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .onChange(of: expandsAutomatically) { expansionOverride = nil }
        }
    }
}

private struct UpdateListRow: View {
    let item: UpdateItem
    let location: String?
    let showsAction: Bool
    let isInstalling: Bool
    let canInstall: Bool
    let activate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let path = item.path {
                AppIconView(path: path, size: 35)
            } else {
                Image(systemName: item.brewPackage == nil ? "laptopcomputer" : "shippingbox")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 35, height: 35)
                    .foregroundStyle(.secondary)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body.weight(.medium))
                    if item.path != nil && item.isRunning {
                        TagBadge(title: "Running", symbol: "circle.fill", tint: .green)
                    }
                }
                Text(item.path == nil && item.brewPackage != nil
                     ? (item.brewPackage?.kind == .formula ? "Formula · " : "Cask · ") + versions : versions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let location {
                    Text((location as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(location)
                }
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
        if showsAction, let action = item.action, !isInstalling {
            Button(action: activate) {
                Text(actionTitle(action))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(action == .install && !canInstall)
            .accessibilityLabel("\(actionTitle(action)) for \(item.name)")
        } else {
            Color.clear.frame(height: 0).accessibilityHidden(true)
        }
    }

    private func actionTitle(_ action: UpdateItem.Action) -> String {
        action == .openApp && item.status == .checkInApp ? "Check in App" : action.title
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
        case .checkInApp: "Unknown"
        case .openUpdater: item.isMacAppStoreApp ? "In App Store" : item.action == .install ? "Check and update" : "Check needed"
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
