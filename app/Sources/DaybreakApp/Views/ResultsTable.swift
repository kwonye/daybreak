import DaybreakKit
import SwiftUI

/// Per-app results of a run or a stored report.
struct ResultsTable: View {
    let results: [RunResult]
    @State private var selection: RunResult.ID?
    @State private var sortOrder: [KeyPathComparator<RunResult>] = []

    private var rows: [RunResult] {
        sortOrder.isEmpty ? results : results.sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("App", value: \.name) { result in
                HStack(spacing: 8) {
                    BundleIconView(bundleID: result.bundleID, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(result.name.isEmpty ? result.bundleID : result.name)
                                .lineLimit(1)
                            if result.bundleID == InventoryApp.ownBundleID {
                                Image(systemName: "sunrise.fill")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                    .help("This app. Daybreak never quits itself; it is left out of Update Now.")
                                    .accessibilityLabel("This app")
                            }
                        }
                        Text(result.bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .help(result.bundleID)
                .accessibilityElement(children: .combine)
            }
            .width(min: 150, ideal: 210)

            TableColumn("Status", value: \.status.rawValue) { result in
                StatusBadge(status: result.status)
                    .fixedSize()
            }
            .width(min: 120, ideal: 165, max: 200)

            TableColumn("Version", value: \.versionChange) { result in
                Text(result.versionChange.isEmpty ? "—" : result.versionChange)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(result.versionChange)
                    .foregroundStyle(result.after.isEmpty ? .secondary : .primary)
            }
            .width(min: 60, ideal: 100, max: 180)

            TableColumn("Backend", value: \.backend) { result in
                Text(result.backend.isEmpty ? "—" : result.backend)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 85, max: 130)

            TableColumn("Detail", value: \.detail) { result in
                Text(detailText(result))
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
                    .help(detailText(result))
            }
            .width(min: 120)
        }
        .contextMenu(forSelectionType: RunResult.ID.self) { ids in
            if let id = ids.first, let result = results.first(where: { $0.id == id }) {
                Button("Copy Bundle ID") { copy(result.bundleID) }
                Button("Copy Detail") { copy(detailText(result)) }
                    .disabled(detailText(result).isEmpty)
            }
        }
    }

    private func detailText(_ result: RunResult) -> String {
        [result.detail, result.verification.isEmpty ? "" : "Verification: \(result.verification)"]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// One-line summary of status counts, e.g. "3 Updated · 1 Deferred".
struct ResultsSummary: View {
    let report: RunReport

    var body: some View {
        let counts = Dictionary(grouping: report.results, by: \.status).mapValues(\.count)
        let ordered = ResultStatus.known.filter { counts[$0] != nil }
            + counts.keys.filter { !$0.isKnown }.sorted { $0.rawValue < $1.rawValue }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
            ForEach(ordered, id: \.self) { status in
                HStack(spacing: 3) {
                    Image(systemName: status.symbolName)
                    Text("\(counts[status] ?? 0) \(status.title)")
                }
                .font(.caption)
                .foregroundStyle(status.tone.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(status.tone.color.opacity(0.12), in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(counts[status] ?? 0) \(status.title)")
                .fixedSize()
            }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
