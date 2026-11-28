import AppKit
import EvergreenKit
import SwiftUI

struct AppManagementFields: View {
    var body: some View {
        Section("App Management") { AppManagementInstructions() }
    }
}

struct AppManagementInstructions: View {
    @State private var settingsCouldNotOpen = false
    private let appURL = Bundle.main.bundleURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Open App Management").font(.headline)
                Text("In System Settings, go to Privacy & Security → App Management.")
                    .foregroundStyle(.secondary)
                Button("Open App Management…") {
                    let pane = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles")!
                    settingsCouldNotOpen = !NSWorkspace.shared.open(pane)
                }
                .accessibilityIdentifier("appManagement.open")
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("2. Turn on \(AppInfo.displayName)").font(.headline)
                Text("If it’s missing, drag the app icon below into the list, or click + and select \(AppInfo.displayName). Approve the change if macOS asks.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    AppBundleDragIcon(url: appURL)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Drag \(AppInfo.displayName) into App Management")
                        .accessibilityIdentifier("appManagement.drag")
                    Text("Drag this icon").font(.callout)
                    Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Couldn’t Open App Management", isPresented: $settingsCouldNotOpen) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Open System Settings and go to Privacy & Security → App Management.")
        }
    }
}

private struct AppBundleDragIcon: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.url = url
        view.image = NSWorkspace.shared.icon(forFile: url.path)
    }

    final class DragView: NSImageView, NSDraggingSource {
        var url: URL?
        private var isDragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            // Leave the destination visible when a drag starts from an inactive window.
            NSApp.preventWindowOrdering()
        }

        override func mouseDragged(with event: NSEvent) {
            guard !isDragging, let url, url.pathExtension == "app" else { return }
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: image)
            isDragging = true
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            isDragging = false
        }
    }
}
