import AppKit
import SwiftUI

struct AppManagementFields: View {
    @State private var settingsCouldNotOpen = false
    private let appURL = Bundle.main.bundleURL

    var body: some View {
        Section("App Management") {
            Button("Open App Management") {
                let pane = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles")!
                settingsCouldNotOpen = !NSWorkspace.shared.open(pane)
            }
            .accessibilityIdentifier("appManagement.open")

            HStack(spacing: 12) {
                AppBundleDragIcon(url: appURL)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Drag Evergreen into App Management")
                    .accessibilityIdentifier("appManagement.drag")
                    .help("Drag this app into the App Management list")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Evergreen").fontWeight(.medium)
                    Text("Drag this icon into the App Management list, then turn on Evergreen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([appURL])
                }
            }
        }
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
