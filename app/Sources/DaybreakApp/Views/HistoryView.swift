import AppKit
import DaybreakKit
import SwiftUI

/// Read-only view of `status` (latest.json) and stored run reports.
struct HistoryView: View {
    let history: HistoryModel
    let stateDirectory: URL
    let reveal: () -> Void

    enum Item: Hashable {
        case latest
        case stored(URL)
    }

    @State private var selection: Item? = .latest

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider()
            detail
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
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

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Last Run") {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Latest")
                        Text(latestSubtitle).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "star.circle")
                }
                .tag(Item.latest)
            }
            Section("Stored Runs") {
                if history.runs.isEmpty {
                    Text(history.state.isLoading ? "Loading…" : "No stored runs")
                        .foregroundStyle(.secondary)
                }
                ForEach(history.runs) { run in
                    StoredRunRow(run: run).tag(Item.stored(run.url))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text(stateDirectory.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(stateDirectory.path)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    private var latestSubtitle: String {
        guard let latest = history.latest else { return "—" }
        if latest.isNeverRun { return "Never run" }
        return latest.startedDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown date"
    }

    @ViewBuilder
    private var detail: some View {
        if let message = history.state.errorMessage, history.latest == nil {
            ErrorStateView(title: "Couldn’t Load History", message: message) {
                Task { await history.refresh() }
            }
        } else {
            switch selection {
            case .latest, .none:
                if let latest = history.latest {
                    ReportDetail(report: latest, source: "latest.json")
                } else {
                    LoadingView(message: "Loading last run…")
                }
            case .stored(let url):
                if let run = history.runs.first(where: { $0.url == url }) {
                    if let report = run.report {
                        ReportDetail(report: report, source: url.lastPathComponent)
                    } else {
                        ErrorStateView(title: "Unreadable Report", message: run.error ?? "Unknown error")
                    }
                } else {
                    ContentUnavailableView("Report Not Found", systemImage: "doc.questionmark")
                }
            }
        }
    }
}

private struct StoredRunRow: View {
    let run: StoredRun

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(run.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? run.url.lastPathComponent)
            if let report = run.report {
                HStack(spacing: 4) {
                    Text("\(report.results.count) apps")
                    if report.attentionCount > 0 {
                        Text("·")
                        Label("\(report.attentionCount)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Unreadable").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 1)
    }
}

private struct ReportDetail: View {
    let report: RunReport
    let source: String

    var body: some View {
        if report.isNeverRun {
            ContentUnavailableView("No Runs Yet", systemImage: "clock",
                                   description: Text("Reports appear here after the first real update run. Dry runs are not recorded."))
        } else if let status = report.status, report.results.isEmpty {
            ContentUnavailableView("No Results", systemImage: "tray",
                                   description: Text("The engine reported status “\(status)”."))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.startedDate.map { $0.formatted(date: .complete, time: .shortened) } ?? "Unknown date")
                        .font(.headline)
                    Text([report.apply ? "Applied run" : "Dry run", report.timezone, source]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ResultsSummary(report: report)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                ResultsTable(results: report.results)
            }
        }
    }
}
