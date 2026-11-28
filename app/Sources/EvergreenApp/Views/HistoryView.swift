import EvergreenKit
import SwiftUI

struct HistoryView: View {
    let history: HistoryModel
    let stateDirectory: URL
    let reveal: () -> Void

    private enum Item: Hashable {
        case latest
        case stored(URL)
    }

    @State private var selection: Item?

    var body: some View {
        Group {
            if let selection {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        self.selection = nil
                    } label: {
                        Label("All Runs", systemImage: "chevron.backward")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider()
                    detail(for: selection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                overview
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItemGroup {
                Button(action: reveal) {
                    Label("Show Reports in Finder", systemImage: "folder")
                }
                .help("Reveal the state folder: \(stateDirectory.path)")
                Button {
                    Task { await history.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload reports (⌘R)")
                .disabled(history.state.isLoading)
            }
        }
    }

    @ViewBuilder
    private var overview: some View {
        let latest = history.latest.flatMap { $0.isNeverRun ? nil : $0 }
        if latest == nil && history.runs.isEmpty && history.state.errorMessage == nil {
            if history.latest == nil {
                LoadingView(message: "Loading runs…")
            } else {
                ContentUnavailableView("No Runs Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Reports appear here after the first update or scheduled run."))
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if let latest {
                        Button { selection = .latest } label: {
                            FeaturedRun(report: latest)
                        }
                        .buttonStyle(JournalButtonStyle())
                    } else if let message = history.state.errorMessage {
                        ErrorStateView(title: "Couldn’t Load the Latest Report", message: message) {
                            Task { await history.refresh() }
                        }
                    }

                    let duplicate = latest.flatMap { report in history.runs.first { $0.report == report }?.id }
                    let earlier = history.runs.filter { $0.id != duplicate }
                    ForEach(archiveMonths(earlier), id: \.month) { section in
                        LazyVStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 12) {
                                Text(section.month?.formatted(.dateTime.month(.wide).year()) ?? "Undated runs")
                                    .font(.system(.title3, design: .serif))
                                Rectangle().fill(.quaternary).frame(height: 1)
                            }
                            .padding(.bottom, 7)
                            ForEach(section.runs) { run in
                                Button { selection = .stored(run.url) } label: {
                                    ArchiveRow(run: run)
                                }
                                .buttonStyle(JournalButtonStyle())
                            }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func archiveMonths(_ runs: [StoredRun]) -> [(month: Date?, runs: [StoredRun])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: runs) { run in
            run.date.flatMap { calendar.dateInterval(of: .month, for: $0)?.start }
        }
        return groups.map { (month: $0.key, runs: $0.value) }
            .sorted { ($0.month ?? .distantPast) > ($1.month ?? .distantPast) }
    }

    @ViewBuilder
    private func detail(for item: Item) -> some View {
        switch item {
        case .latest:
            if let report = history.latest {
                ReportDetail(report: report)
            } else if let message = history.state.errorMessage {
                ErrorStateView(title: "Couldn’t Load the Latest Report", message: message) {
                    Task { await history.refresh() }
                }
            } else {
                LoadingView(message: "Loading last run…")
            }
        case .stored(let url):
            if let run = history.runs.first(where: { $0.id == url }) {
                if let report = run.report {
                    ReportDetail(report: report)
                } else {
                    ErrorStateView(title: "Unreadable Report", message: run.error ?? "Unknown error")
                }
            } else {
                ContentUnavailableView("Report Not Found", systemImage: "doc.questionmark")
            }
        }
    }
}

private struct FeaturedRun: View {
    let report: RunReport

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Latest run")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
            Text(report.startedDate?.formatted(.dateTime.weekday(.wide).month(.wide).day()) ?? "Unknown date")
                .font(.system(size: 34, weight: .regular, design: .serif))
                .padding(.top, 6)
            if let date = report.startedDate {
                Text("\(date.formatted(.dateTime.year()))  ·  \(date.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.white.opacity(0.8))
                    .font(.subheadline)
            }
            HStack(spacing: 9) {
                Text(report.apply ? "Applied run" : "Preview")
                Text("·")
                RunCounts(report: report)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.body.weight(.medium))
                    .accessibilityHidden(true)
            }
            .font(.callout.weight(.medium))
            .padding(.top, 22)
        }
        .foregroundStyle(.white)
        .padding(24)
        .background {
            ZStack(alignment: .trailing) {
                LinearGradient(colors: [Color(red: 0.07, green: 0.20, blue: 0.17),
                                        Color(red: 0.15, green: 0.31, blue: 0.25)],
                               startPoint: .leading, endPoint: .trailing)
                GrowthRings()
                    .frame(maxWidth: 220)
                    .mask(LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .center))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// A cropped woodcut of annual rings. Each contour shares the same irregular grain.
struct GrowthRings: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.94, y: size.height * 0.26)
            for ring in 1...19 {
                var path = Path()
                for step in 0..<120 {
                    let angle = Double(step) * .pi / 60
                    let grain = 1 + 0.065 * sin(3 * angle) + 0.035 * cos(5 * angle + Double(ring) * 0.09)
                    let radius = Double(ring) * 13 * grain
                    let point = CGPoint(x: center.x + cos(angle) * radius,
                                        y: center.y + sin(angle) * radius * 0.86)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
                context.stroke(path, with: .color(.white.opacity(0.19)), lineWidth: ring.isMultiple(of: 4) ? 1.2 : 0.7)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct RunCounts: View {
    let report: RunReport

    var body: some View {
        Text("\(report.results.count) \(report.results.count == 1 ? "app" : "apps")")
        if report.attentionCount > 0 {
            Label("\(report.attentionCount) to review", systemImage: "exclamationmark.circle")
        }
    }
}

private struct ArchiveRow: View {
    let run: StoredRun

    var body: some View {
        HStack(spacing: 16) {
            if let date = run.date {
                VStack(spacing: 0) {
                    Text(date.formatted(.dateTime.day()))
                        .font(.system(size: 25, design: .serif))
                    Text(date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 42)
                .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(run.report.map { $0.apply ? "Applied run" : "Preview" } ?? "Unreadable report")
                    .font(.headline)
                Text(run.date?.formatted(date: .omitted, time: .shortened) ?? run.url.lastPathComponent)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let report = run.report {
                HStack(spacing: 12) { RunCounts(report: report) }
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.forward")
                .font(.caption2.bold())
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct JournalButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ReportDetail: View {
    let report: RunReport
    @State private var showProtected = false

    var body: some View {
        if report.isNeverRun {
            ContentUnavailableView("No Runs Yet", systemImage: "clock",
                                   description: Text("Reports appear here after the first update or scheduled run."))
        } else if let status = report.status, report.results.isEmpty {
            ContentUnavailableView("No Results", systemImage: "tray",
                                   description: Text("The engine reported status “\(status)”."))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.startedDate.map { $0.formatted(date: .complete, time: .shortened) } ?? "Unknown date")
                        .font(.system(.title2, design: .serif))
                    Text([report.apply ? "Applied run" : "Preview", report.timezone]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top) {
                        ResultsSummary(report: report)
                        Spacer(minLength: 12)
                        if report.results.contains(where: \.isProtected) {
                            Toggle("Show protected apps", isOn: $showProtected)
                                .toggleStyle(.checkbox)
                                .fixedSize()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                let results = report.results.filter { showProtected || !$0.isProtected }
                if results.isEmpty && !report.results.isEmpty {
                    ContentUnavailableView("Only Protected Apps", systemImage: "checkmark.shield",
                                           description: Text("Show protected apps to see the full report."))
                } else {
                    ResultsTable(results: results)
                }
            }
        }
    }
}
