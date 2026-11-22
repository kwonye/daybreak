import AppKit
import DaybreakKit
import SwiftUI

struct SettingsView: View {
    enum Tab: String { case general, behavior }

    let model: AppModel
    @State private var tab: Tab

    init(model: AppModel) {
        self.model = model
        _tab = State(initialValue: model.launchOptions.settingsTab.flatMap(Tab.init(rawValue:)) ?? .general)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            BehaviorSettingsView(model: model)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Tab.behavior)
        }
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Edits the engine's own configuration keys; everything else in the file is preserved.
private struct BehaviorSettingsView: View {
    let model: AppModel
    @State private var draft = EngineSettings()
    @State private var saved = false
    @State private var saveError: String?

    private var config: ConfigModel { model.config }
    private var problems: [String] { draft.validationErrors() }
    private var isDirty: Bool { draft != config.settings }

    var body: some View {
        Form {
            if let error = config.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    HStack {
                        Button("Reveal in Finder", action: model.revealConfigInFinder)
                        Button("Reload") { config.reload(); draft = config.settings }
                    }
                }
            }
            Section {
                Picker("Hour", selection: $draft.hour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(String(format: "%02d:00", hour)).tag(hour)
                    }
                }
                LabeledContent("Time zone") {
                    TimeZonePicker(selection: $draft.timezone, keep: [config.settings.timezone])
                }
            } header: {
                Text("Daily Window")
            } footer: {
                Text(verbatim: "Used only by externally scheduled “run --due” invocations: at most one run per local date, at or after this hour. Daybreak does not create schedules.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Restarts") {
                LabeledContent("Quit timeout") {
                    HStack {
                        TextField("Quit timeout in seconds", value: $draft.quitTimeoutSeconds, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        Stepper("Quit timeout", value: $draft.quitTimeoutSeconds, in: 1...600, step: 5)
                            .labelsHidden()
                        Text("seconds (1–600)").foregroundStyle(.secondary)
                    }
                }
                Toggle("Restart apps that are already current", isOn: $draft.restartCurrent)
                Toggle("Restart apps without a supported updater", isOn: $draft.restartUnmanaged)
            }
            Section {
                Toggle("Install Mac App Store updates in Daybreak", isOn: $draft.directAppStoreUpdates)
            } header: {
                Text("Mac App Store")
            } footer: {
                Text("macOS may ask for administrator approval. Check for updates again after changing this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !problems.isEmpty {
                Section {
                    ForEach(problems, id: \.self) {
                        Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    }
                }
            }
            Section {
                LabeledContent("Config file") {
                    HStack {
                        Text(config.store.url.path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(config.store.url.path)
                            .textSelection(.enabled)
                        Button("Reveal in Finder", action: model.revealConfigInFinder)
                    }
                }
                HStack {
                    if saved && !isDirty {
                        Label("Saved", systemImage: "checkmark").foregroundStyle(.green).font(.callout)
                    }
                    Spacer()
                    Button("Revert") { draft = config.settings }
                        .disabled(!isDirty)
                    Button("Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!isDirty || !problems.isEmpty || !config.canEdit)
                }
            } footer: {
                Text(verbatim: "Daybreak saves these settings to your configuration file.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            config.reload()
            draft = config.settings
        }
        .onChange(of: draft) { saved = false }
        .alert("Couldn’t Save", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save() {
        saved = config.save(settings: draft)
        if saved {
            draft = config.settings
        } else {
            // Shown here rather than in the main window's whitelist alert.
            saveError = config.actionError ?? "Unknown error"
            config.actionError = nil
        }
    }
}

/// Button showing the selected zone; opens a searchable list grouped by region.
private struct TimeZonePicker: View {
    @Binding var selection: String
    /// Identifiers to keep in the list even if unknown to Foundation's list (e.g. from the config).
    let keep: [String]
    @State private var showing = false

    var body: some View {
        HStack {
            Button {
                showing = true
            } label: {
                HStack {
                    if let zone = TimeZone(identifier: selection) {
                        Text(selection.replacingOccurrences(of: "_", with: " "))
                        Text(TimeZoneCatalog.formatOffset(zone.secondsFromGMT()))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Label(selection.isEmpty ? "Choose…" : "\(selection) (invalid)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Time zone: \(selection)")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                TimeZoneList(keep: keep + [selection], selection: $selection) { showing = false }
            }
            Button("Use Current") { selection = TimeZone.current.identifier }
                .help("Use this Mac’s time zone (\(TimeZone.current.identifier))")
        }
    }
}

private struct TimeZoneList: View {
    @Binding var selection: String
    let done: () -> Void
    /// Built once per popover presentation (about 600 zones).
    @State private var catalog: TimeZoneCatalog
    @State private var query = ""

    init(keep: [String], selection: Binding<String>, done: @escaping () -> Void) {
        _selection = selection
        self.done = done
        _catalog = State(initialValue: TimeZoneCatalog(including: keep))
    }
    @FocusState private var searchFocused: Bool

    var body: some View {
        let regions = catalog.filtered(query)
        VStack(spacing: 0) {
            TextField("Search", text: $query, prompt: Text("Search city, region or GMT offset"))
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(10)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(regions) { region in
                        Section(region.name.replacingOccurrences(of: "_", with: " ")) {
                            ForEach(region.zones) { zone in
                                Button {
                                    selection = zone.identifier
                                    done()
                                } label: {
                                    HStack {
                                        Image(systemName: "checkmark")
                                            .opacity(zone.identifier == selection ? 1 : 0)
                                            .foregroundStyle(Color.accentColor)
                                            .accessibilityHidden(true)
                                        Text(zone.city)
                                        Spacer()
                                        Text(zone.offset).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(zone.identifier)
                                .help(zone.identifier)
                                .accessibilityLabel("\(zone.identifier), \(zone.offset)")
                                .accessibilityAddTraits(zone.identifier == selection ? .isSelected : [])
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if regions.isEmpty { ContentUnavailableView.search(text: query) }
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .frame(width: 360, height: 420)
        .onAppear { searchFocused = true }
    }
}

/// App-level preferences (stored in UserDefaults, never in the engine config).
private struct GeneralSettingsView: View {
    @Bindable var model: AppModel
    @State private var draftStateFolder = ""

    var body: some View {
        Form {
            Section {
                Toggle("Show Daybreak in the menu bar", isOn: $model.showMenuBar)
                    .disabled(model.hideDockIcon)
                Toggle("Hide the Dock icon", isOn: $model.hideDockIcon)
            } header: {
                Text("Menu Bar and Dock")
            } footer: {
                Text("With the Dock icon hidden, open Daybreak from the menu bar.")
            }
            Section {
                PathField(title: "State folder", prompt: "Default",
                          path: $draftStateFolder)
            } header: {
                Text("Local State")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "The state folder holds reports, the daily gate and the run lock. Default: \(HistoryStore.defaultStateDirectory.path). Use the same folder as your scheduled job so History and the daily gate agree.")
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                HStack {
                    if model.runner.isBusy {
                        Text("Available when the current run finishes.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Apply State Folder") {
                        model.stateDirectoryPath = draftStateFolder
                        Task { await model.bootstrap() }
                    }
                        .disabled(model.engineState == .loading || model.runner.isBusy || model.runner.pendingPlan != nil
                                  || draftStateFolder == model.stateDirectoryPath)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draftStateFolder = model.stateDirectoryPath }
    }
}

private struct PathField: View {
    let title: String
    let prompt: String
    @Binding var path: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: $path, prompt: Text(prompt))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .help(path.isEmpty ? prompt : path)
                Button("Choose…", action: choose)
                Button {
                    path = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Reset to default")
                .accessibilityLabel("Reset \(title) to default")
                .opacity(path.isEmpty ? 0 : 1)
                .disabled(path.isEmpty)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        }
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}
