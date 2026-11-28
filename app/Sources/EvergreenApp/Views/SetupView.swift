import AppKit
import EvergreenKit
import SwiftUI

struct SetupView: View {
    private enum Step: Int, CaseIterable {
        case welcome, routine, permission

        var title: String {
            switch self {
            case .welcome: "Welcome to \(AppInfo.displayName)"
            case .routine: "Your update routine"
            case .permission: "Allow app updates in macOS"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome: "Evergreen checks your Mac apps for updates, installs supported updates, and reopens apps it closed."
            case .routine: "Choose when Evergreen checks for updates and installs them while you’re signed in."
            case .permission: "macOS needs your permission before \(AppInfo.displayName) can replace apps in your Applications folder."
            }
        }
    }

    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.welcome
    @State private var draft: EngineSettings
    @State private var original: EngineSettings
    @State private var startAtLogin: Bool
    @State private var editingSchedule = false
    @State private var error: String?

    init(model: AppModel) {
        self.model = model
        let settings = model.config.settings
        let firstSetup = !model.hasCompletedSetup
        let suggested = firstSetup ? try? model.config.store.load().onboardingSettings(hasHomebrew: model.hasHomebrew) : nil
        _draft = State(initialValue: suggested ?? settings)
        _original = State(initialValue: settings)
        _startAtLogin = State(initialValue: model.loginItem.isRegistered || (firstSetup && model.loginItem.isAvailable))
    }

    private var headerColors: [Color] {
        AppInfo.isDevelopmentBuild
            ? [Color(red: 0.19, green: 0.12, blue: 0.29), Color(red: 0.37, green: 0.25, blue: 0.49)]
            : [Color(red: 0.07, green: 0.20, blue: 0.17), Color(red: 0.15, green: 0.31, blue: 0.25)]
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable().frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(Step.allCases, id: \.self) { item in
                            Capsule()
                                .fill(.white.opacity(item == step ? 0.95 : 0.35))
                                .frame(width: item == step ? 23 : 8, height: 4)
                        }
                    }
                    .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                }
                Text(step.title)
                    .font(.system(size: 30, weight: .regular, design: .serif))
                    .accessibilityAddTraits(.isHeader)
                Text(step.subtitle)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack(alignment: .trailing) {
                    LinearGradient(colors: headerColors, startPoint: .leading, endPoint: .trailing)
                    GrowthRings()
                        .frame(width: 185)
                        .mask(LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing))
                }
                .clipped()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case .welcome:
                        choice("Install App Store updates here", detail: "You choose each install. macOS may ask for administrator approval.",
                               icon: "bag", value: $draft.directAppStoreUpdates)
                        Divider()
                        choice("Restart apps that are already up to date", detail: "Leave this off to keep current apps running.",
                               icon: "arrow.clockwise", value: $draft.restartCurrent)
                    case .routine:
                        choice("Run scheduled updates", detail: "Evergreen checks at the time you choose while it’s running.",
                               icon: "calendar", value: $draft.automaticRuns)
                        if draft.automaticRuns {
                            DisclosureGroup(isExpanded: $editingSchedule) {
                                VStack(alignment: .leading, spacing: 10) {
                                    ScheduleTimingFields(draft: $draft, hasHomebrew: model.hasHomebrew)
                                }
                                .padding(.top, 8)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Edit schedule").fontWeight(.medium)
                                    Text(scheduleSummary).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.leading, 36)
                        }
                        Divider()
                        choice("Open \(AppInfo.displayName) at login", detail: "Start automatically when you sign in to your Mac.",
                               icon: "power", value: $startAtLogin)
                            .disabled(!model.loginItem.isAvailable)
                            .accessibilityIdentifier("setup.startAtLogin")
                    case .permission:
                        AppManagementInstructions()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(step)
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            Divider()
            HStack {
                Button("Not Now") {
                    model.postponeSetup()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if step != .welcome {
                    Button("Back") {
                        step = Step(rawValue: step.rawValue - 1) ?? .welcome
                        error = nil
                    }
                }
                Button(step == .permission ? "Finish Setup" : "Continue") {
                    if let next = Step(rawValue: step.rawValue + 1) { step = next }
                    else { finish() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 550, height: 505)
        .interactiveDismissDisabled()
        .accessibilityIdentifier("setup.sheet")
    }

    private var scheduleSummary: String {
        let clock = Date(timeIntervalSince1970: Double(draft.hour * 3600 + draft.minute * 60))
        var format = Date.FormatStyle(date: .omitted, time: .shortened)
        format.timeZone = .gmt
        let cadence = draft.cadence == .weekly ? draft.weekday.title : draft.cadence.title
        let time = clock.formatted(format)
        return "\(draft.scheduleScope.title) · \(cadence) · \(time) (\(draft.timezone))"
    }

    private func choice(_ title: String, detail: String, icon: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
        }
        .toggleStyle(.switch)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    private func finish() {
        let wasRegistered = model.loginItem.isRegistered
        do { try model.loginItem.setRegistered(startAtLogin) }
        catch {
            self.error = error.localizedDescription
            step = .routine
            return
        }
        guard model.config.save(settings: draft, original: original) else {
            error = model.config.actionError
            model.config.actionError = nil
            do { try model.loginItem.setRegistered(wasRegistered) }
            catch { self.error = [self.error, error.localizedDescription].compactMap { $0 }.joined(separator: "\n") }
            return
        }
        model.completeSetup()
        dismiss()
        Task {
            if draft.automaticRuns { await ScheduleNotifications.requestPermission() }
            await model.scheduler.runScheduledIfDue()
        }
    }
}

struct UpdateBehaviorFields: View {
    @Binding var draft: EngineSettings
    var body: some View {
        Section {
            Toggle("Install Mac App Store updates in \(AppInfo.displayName)", isOn: $draft.directAppStoreUpdates)
        } header: {
            Text("Mac App Store")
        } footer: {
            Text("macOS may ask for administrator approval. These installs are started individually from Apps.")
        }
        Section {
            restartOptions
        } header: {
            Text("Restarts")
        } footer: {
            Text("\(AppInfo.displayName) asks apps to quit normally and respects your whitelist.")
        }
    }

    private var restartOptions: some View {
        Group {
            let timeoutTitle = "Quit timeout"
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
            Toggle("Restart apps that are already current",
                   isOn: $draft.restartCurrent)
            Toggle("Restart apps without a supported updater",
                   isOn: $draft.restartUnmanaged)
        }
    }
}

struct ScheduleFields: View {
    @Binding var draft: EngineSettings
    let hasHomebrew: Bool
    var body: some View {
        Section {
            Toggle("Run scheduled updates", isOn: $draft.automaticRuns)
            ScheduleTimingFields(draft: $draft, hasHomebrew: hasHomebrew)
        } header: {
            Text("Schedule")
        } footer: {
            Text("\(AppInfo.displayName) starts within 30 minutes of the scheduled time. If it misses that window, it reminds you when updates are ready.")
        }
    }

}

private struct ScheduleTimingFields: View {
    @Binding var draft: EngineSettings
    let hasHomebrew: Bool
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    @ViewBuilder
    var body: some View {
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
                .accessibilityValue(time.wrappedValue.formatted(wallClockFormat))
        }
        LabeledContent("Time zone") {
            TimeZonePicker(selection: $draft.timezone, keep: [draft.timezone])
        }
    }

    private var wallClockFormat: Date.FormatStyle {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = .gmt
        return style
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
