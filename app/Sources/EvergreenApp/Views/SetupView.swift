import AppKit
import EvergreenKit
import SwiftUI

struct SetupView: View {
    private enum Step: Int, CaseIterable {
        case updates, appManagement, schedule, appearance

        var title: String {
            switch self {
            case .updates: "Welcome to Evergreen"
            case .appManagement: "Allow app updates"
            case .schedule: "Pick a good time"
            case .appearance: "Make Evergreen yours"
            }
        }

        var subtitle: String {
            switch self {
            case .updates: "Choose how you’d like to keep your apps up to date."
            case .appManagement: "Allow Evergreen to replace installed apps when you update them."
            case .schedule: "Choose what Evergreen updates and when."
            case .appearance: "Choose when Evergreen opens and where you’ll find it."
            }
        }

        var symbol: String {
            switch self {
            case .updates: "tree"
            case .appManagement: "lock.shield"
            case .schedule: "calendar.badge.clock"
            case .appearance: "menubar.rectangle"
            }
        }
    }

    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.updates
    @State private var draft: EngineSettings
    @State private var original: EngineSettings
    @State private var showMenuBar: Bool
    @State private var hideDockIcon: Bool
    @State private var startAtLogin: Bool
    @State private var originalStartAtLogin: Bool
    @State private var error: String?

    init(model: AppModel) {
        self.model = model
        let settings = model.config.settings
        _draft = State(initialValue: settings)
        _original = State(initialValue: settings)
        _showMenuBar = State(initialValue: model.showMenuBar)
        _hideDockIcon = State(initialValue: model.hideDockIcon)
        _startAtLogin = State(initialValue: model.loginItem.isRegistered)
        _originalStartAtLogin = State(initialValue: model.loginItem.isRegistered)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                switch step {
                case .updates:
                    UpdateBehaviorFields(draft: $draft, context: .setup)
                case .appManagement:
                    AppManagementFields()
                case .schedule:
                    ScheduleFields(draft: $draft, hasHomebrew: model.hasHomebrew, context: .setup)
                case .appearance:
                    Section("When you sign in") {
                        Toggle("Open Evergreen at login", isOn: $startAtLogin)
                            .disabled(!model.loginItem.isAvailable)
                            .accessibilityIdentifier("setup.startAtLogin")
                    }
                    Section {
                        Toggle("Keep Evergreen in the menu bar", isOn: $showMenuBar)
                            .disabled(hideDockIcon)
                        Toggle("Hide the Dock icon", isOn: $hideDockIcon)
                            .onChange(of: hideDockIcon) { if hideDockIcon { showMenuBar = true } }
                    } header: {
                        Text("Where to find Evergreen")
                    } footer: {
                        Text("With the Dock icon hidden, you can open Evergreen from the menu bar.")
                    }
                }
            }
            .formStyle(.grouped)
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            Divider()
            footer
        }
        .frame(width: 550, height: 510)
        .interactiveDismissDisabled()
        .accessibilityIdentifier("setup.sheet")
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: step.symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(step.title).font(.title2.weight(.semibold))
                Text(step.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack {
            Button("Not Now") {
                model.completeSetup()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            if step != .updates {
                Button("Back") {
                    step = Step(rawValue: step.rawValue - 1) ?? .updates
                    error = nil
                }
            }
            Button(step == .appearance ? "Done" : "Continue") {
                if let next = Step(rawValue: step.rawValue + 1) {
                    step = next
                } else {
                    finish()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private func finish() {
        guard model.config.save(settings: draft, original: original) else {
            error = model.config.actionError
            model.config.actionError = nil
            return
        }
        if startAtLogin != originalStartAtLogin {
            do { try model.loginItem.setRegistered(startAtLogin) }
            catch {
                self.error = error.localizedDescription
                return
            }
        }
        model.showMenuBar = showMenuBar
        model.hideDockIcon = hideDockIcon
        model.completeSetup()
        dismiss()
        Task {
            if draft.automaticRuns { await ScheduleNotifications.requestPermission() }
            await model.scheduler.runScheduledIfDue()
        }
    }
}

enum SetupFieldContext {
    case settings, setup
}

struct UpdateBehaviorFields: View {
    @Binding var draft: EngineSettings
    var context: SetupFieldContext = .settings

    var body: some View {
        Section {
            Toggle(context == .setup ? "Install App Store updates here" : "Install Mac App Store updates in Evergreen",
                   isOn: $draft.directAppStoreUpdates)
        } header: {
            Text("Mac App Store")
        } footer: {
            if context == .setup {
                Text("Choose each App Store update from the Updates tab. Your Mac may ask you to approve the install.")
            } else {
                Text("macOS may ask for administrator approval. These installs are started individually from Apps.")
            }
        }
        Section {
            if context == .setup {
                DisclosureGroup("More restart options") {
                    restartOptions
                }
            } else {
                restartOptions
            }
        } header: {
            if context == .settings { Text("Restarts") }
        } footer: {
            Text(context == .setup
                 ? "Evergreen gives apps a chance to save your work before they close."
                 : "Evergreen asks apps to quit normally and respects your whitelist.")
        }
    }

    private var restartOptions: some View {
        Group {
            let timeoutTitle = context == .setup ? "Wait for apps to close" : "Quit timeout"
            LabeledContent(timeoutTitle) {
                HStack {
                    TextField(timeoutTitle, value: $draft.quitTimeoutSeconds, format: .number)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Stepper(timeoutTitle, value: $draft.quitTimeoutSeconds, in: 1...600, step: 5)
                        .labelsHidden()
                    Text("seconds (1–600)").foregroundStyle(.secondary)
                }
            }
            Toggle(context == .setup ? "Restart apps that are already up to date" : "Restart apps that are already current",
                   isOn: $draft.restartCurrent)
            Toggle(context == .setup ? "Restart apps Evergreen can’t update" : "Restart apps without a supported updater",
                   isOn: $draft.restartUnmanaged)
        }
    }
}

struct ScheduleFields: View {
    @Binding var draft: EngineSettings
    let hasHomebrew: Bool
    var context: SetupFieldContext = .settings
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    var body: some View {
        Section {
            Toggle("Run scheduled updates", isOn: $draft.automaticRuns)
            if context == .settings || draft.automaticRuns { timingOptions }
        } header: {
            Text("Schedule")
        } footer: {
            Text("Evergreen starts within 30 minutes of the scheduled time. If it misses that window, it reminds you when updates are ready.")
        }
    }

    @ViewBuilder
    private var timingOptions: some View {
        if hasHomebrew {
            Picker("Update", selection: $draft.scheduleScope) {
                ForEach(ScheduleScope.allCases) {
                    Text($0.title).tag($0)
                }
            }
        } else if draft.scheduleScope != .apps {
            Button("Switch Schedule to Apps") { draft.scheduleScope = .apps }
        }
        Picker("Repeat", selection: $draft.cadence) {
            ForEach(ScheduleCadence.allCases) { Text($0.title).tag($0) }
        }
        if draft.cadence == .weekly {
            Picker("Day", selection: $draft.weekday) {
                ForEach(ScheduleWeekday.allCases) { Text($0.title).tag($0) }
            }
        }
        LabeledContent("Time") {
            ScheduleTimePicker(date: time)
                .fixedSize()
                .accessibilityLabel("Time")
        }
        LabeledContent("Time zone") {
            TimeZonePicker(selection: $draft.timezone, keep: [draft.timezone])
        }
    }

    private var time: Binding<Date> {
        Binding {
            let hour = min(max(draft.hour, 0), 23)
            let minute = min(max(draft.minute, 0), 59)
            return Date(timeIntervalSince1970: Double(hour * 3600 + minute * 60))
        } set: { date in
            draft.hour = calendar.component(.hour, from: date)
            draft.minute = calendar.component(.minute, from: date)
        }
    }
}

private struct ScheduleTimePicker: NSViewRepresentable {
    @Binding var date: Date

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.hourMinute]
        // The binding encodes a wall-clock hour and minute using GMT as its reference.
        picker.timeZone = .gmt
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.didChange(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.date = $date
        if picker.dateValue != date { picker.dateValue = date }
    }

    @MainActor final class Coordinator: NSObject {
        var date: Binding<Date>
        init(date: Binding<Date>) { self.date = date }

        @objc func didChange(_ picker: NSDatePicker) {
            date.wrappedValue = picker.dateValue
        }
    }
}
