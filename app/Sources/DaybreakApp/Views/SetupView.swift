import DaybreakKit
import SwiftUI

struct SetupView: View {
    private enum Step: Int, CaseIterable {
        case updates, schedule, appearance

        var title: String {
            switch self {
            case .updates: "Choose how apps update"
            case .schedule: "Set a restart schedule"
            case .appearance: "Keep Daybreak within reach"
            }
        }

        var symbol: String {
            switch self {
            case .updates: "arrow.down.app"
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
    @State private var hideProtected: Bool
    @State private var error: String?

    init(model: AppModel) {
        self.model = model
        let settings = model.config.settings
        _draft = State(initialValue: settings)
        _original = State(initialValue: settings)
        _showMenuBar = State(initialValue: model.showMenuBar)
        _hideDockIcon = State(initialValue: model.hideDockIcon)
        _hideProtected = State(initialValue: model.inventory.hideProtected)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                switch step {
                case .updates:
                    UpdateBehaviorFields(draft: $draft)
                case .schedule:
                    ScheduleFields(draft: $draft)
                case .appearance:
                    Section("Menu Bar and Dock") {
                        Toggle("Show Daybreak in the menu bar", isOn: $showMenuBar)
                            .disabled(hideDockIcon)
                        Toggle("Hide the Dock icon", isOn: $hideDockIcon)
                            .onChange(of: hideDockIcon) { if hideDockIcon { showMenuBar = true } }
                    }
                    Section("Running Apps") {
                        Toggle("Hide protected system apps", isOn: $hideProtected)
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
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title).font(.title2.weight(.semibold))
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(.subheadline)
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
            Button("Set Up Later") {
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
            Button(step == .appearance ? "Finish Setup" : "Continue") {
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
        model.showMenuBar = showMenuBar
        model.hideDockIcon = hideDockIcon
        model.inventory.hideProtected = hideProtected
        model.completeSetup()
        dismiss()
        Task { await model.runner.runScheduledIfDue() }
    }
}

struct UpdateBehaviorFields: View {
    @Binding var draft: EngineSettings

    var body: some View {
        Section {
            Toggle("Install Mac App Store updates in Daybreak", isOn: $draft.directAppStoreUpdates)
        } header: {
            Text("Mac App Store")
        } footer: {
            Text("macOS may ask for administrator approval. These installs are started individually from Updates.")
        }
        Section {
            LabeledContent("Quit timeout") {
                HStack {
                    TextField("Quit timeout", value: $draft.quitTimeoutSeconds, format: .number)
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
        } header: {
            Text("Restarts")
        } footer: {
            Text("Daybreak asks apps to quit normally and respects your whitelist.")
        }
    }
}

struct ScheduleFields: View {
    @Binding var draft: EngineSettings
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    var body: some View {
        Section {
            Toggle("Run automatically while Daybreak is open", isOn: $draft.automaticRuns)
            Picker("Repeat", selection: $draft.cadence) {
                ForEach(ScheduleCadence.allCases) { Text($0.title).tag($0) }
            }
            if draft.cadence == .weekly {
                Picker("Day", selection: $draft.weekday) {
                    ForEach(ScheduleWeekday.allCases) { Text($0.title).tag($0) }
                }
            }
            DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                .environment(\.calendar, calendar)
                .environment(\.timeZone, .gmt)
            LabeledContent("Time zone") {
                TimeZonePicker(selection: $draft.timezone, keep: [draft.timezone])
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text("A missed run can start later on the same day. The schedule also applies to CLI runs using --due.")
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
