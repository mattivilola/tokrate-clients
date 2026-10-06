import AppKit
import SwiftUI

/// Renders `content` only while the hosting window is on screen. AppKit keeps `MenuBarExtra` and
/// `Window` scene windows, and their SwiftUI hierarchies, alive while they are hidden, so a hidden
/// dashboard would keep re-evaluating on every store change and filling offscreen render buffers.
/// While hidden the gate reads no observable state, so nothing re-evaluates.
///
/// State that must survive hiding (selected range, expanded sections) has to live above the gate.
/// `keepsHeight` holds the last rendered height while hidden so a content-sized window does not
/// resize when it is shown again. Without a window to track (`tracksWindow: false`: previews and
/// tests) the content is always rendered, unless `isVisible` says otherwise.
struct WindowVisibilityGate<Content: View>: View {
    private let tracksWindow: Bool
    private let keepsHeight: Bool
    private let content: () -> Content
    @State private var isVisible: Bool
    @State private var renderedHeight: CGFloat?

    init(
        tracksWindow: Bool = true,
        isVisible: Bool? = nil,
        keepsHeight: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.tracksWindow = tracksWindow
        self.keepsHeight = keepsHeight
        self.content = content
        _isVisible = State(initialValue: isVisible ?? !tracksWindow)
    }

    var body: some View {
        Group {
            if isVisible {
                content()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { renderedHeight = $0 }
            } else {
                Color.clear.frame(height: keepsHeight ? renderedHeight : nil)
            }
        }
        .background {
            if tracksWindow {
                WindowVisibilityReader { isVisible = $0 }
            }
        }
    }
}

/// Reports whether the hosting window is ordered on screen, starting with its current state.
/// `NSWindow.isVisible` flips inside `orderFront`/`orderOut`, before the window draws; the occlusion
/// notification follows about 40 ms after showing and 200 ms after hiding, so waiting for it would
/// show an empty first frame. It must stay in the hierarchy whether or not the content is shown.
struct WindowVisibilityReader: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowVisibilityView {
        let view = WindowVisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WindowVisibilityView, context: Context) {
        view.onChange = onChange
    }
}

final class WindowVisibilityView: NSView {
    var onChange: (Bool) -> Void = { _ in }
    private var observation: NSKeyValueObservation?
    private var lastReported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = window?.observe(\.isVisible, options: [.initial, .new]) { [weak self] _, change in
            MainActor.assumeIsolated { self?.report(change.newValue ?? false) }
        }
        if window == nil { report(false) }
    }

    private func report(_ visible: Bool) {
        guard visible != lastReported else { return }
        lastReported = visible
        onChange(visible)
    }
}
