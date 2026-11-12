import AppKit
import DaybreakKit
import SwiftUI

/// An installed app resolved from a bundle ID via Launch Services.
struct ResolvedApp: Sendable, Equatable {
    let url: URL
    let name: String
}

/// Loads Finder icons and Launch Services lookups off the main thread and caches them.
/// Observable, so views re-render when a lookup completes.
@MainActor
@Observable
final class IconStore {
    static let shared = IconStore()

    private var icons: [String: NSImage] = [:]
    private var resolved: [String: ResolvedApp?] = [:]
    @ObservationIgnored private var pendingIcons = Set<String>()
    @ObservationIgnored private var pendingLookups = Set<String>()

    /// Cached icon, or nil while it loads in the background.
    func icon(forPath path: String) -> NSImage? {
        if let icon = icons[path] { return icon }
        if pendingIcons.insert(path).inserted {
            Task {
                let box = await Task.detached(priority: .utility) { () -> ImageBox in
                    let workspace = NSWorkspace.shared
                    let image = FileManager.default.fileExists(atPath: path)
                        ? workspace.icon(forFile: path)
                        : workspace.icon(for: .applicationBundle)
                    return ImageBox(image: image)
                }.value
                icons[path] = box.image
                pendingIcons.remove(path)
            }
        }
        return nil
    }

    /// Installed app for an exact bundle ID (nil for globs, unknown IDs, or while resolving).
    func app(forBundleID bundleID: String) -> ResolvedApp? {
        guard !bundleID.isEmpty, !Whitelist.isGlob(bundleID) else { return nil }
        if let cached = resolved[bundleID] { return cached }
        if pendingLookups.insert(bundleID).inserted {
            Task {
                let result = await Task.detached(priority: .utility) { () -> ResolvedApp? in
                    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
                    let name = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
                    return ResolvedApp(url: url, name: name)
                }.value
                resolved[bundleID] = .some(result)
                pendingLookups.remove(bundleID)
            }
        }
        return nil
    }
}

/// NSImage is not declared Sendable; the image is created once and only read afterwards.
private struct ImageBox: @unchecked Sendable {
    let image: NSImage
}

struct AppIconView: View {
    let path: String?
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let path, !path.isEmpty, let image = IconStore.shared.icon(forPath: path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else if let path, !path.isEmpty {
                // Still loading: keep the layout stable.
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(.quaternary)
                    .padding(size * 0.08)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.1)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Icon for a bundle ID, resolved asynchronously through Launch Services.
struct BundleIconView: View {
    let bundleID: String
    var fallbackPath: String?
    var size: CGFloat = 20

    var body: some View {
        AppIconView(path: fallbackPath ?? IconStore.shared.app(forBundleID: bundleID)?.url.path, size: size)
    }
}

extension StatusTone {
    var color: Color {
        switch self {
        case .success: .green
        case .info: .blue
        case .neutral: .secondary
        case .warning: .orange
        case .danger: .red
        }
    }
}

struct StatusBadge: View {
    let status: ResultStatus

    var body: some View {
        Label(status.title, systemImage: status.symbolName)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(status.tone.color)
            .background(status.tone.color.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(status.tone.color.opacity(0.25), lineWidth: 0.5))
            .help(status.isKnown ? status.rawValue : "Unrecognised status “\(status.rawValue)”")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Status: \(status.title)")
    }
}

struct TagBadge: View {
    let title: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}

/// Full-pane error state with a retry action.
struct ErrorStateView: View {
    let title: String
    let message: String
    var retryTitle = "Try Again"
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .textSelection(.enabled)
        } actions: {
            if let retry {
                Button(retryTitle, action: retry)
            }
        }
    }
}

struct LoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Date {
    var relativeDescription: String {
        formatted(.relative(presentation: .named))
    }
}
