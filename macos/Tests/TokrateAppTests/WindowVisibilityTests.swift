import AppKit
import SwiftUI
import XCTest
import TokrateCore
@testable import TokrateApp

/// The popover and the history window render their content only while their window is on screen. Everything uses synthetic
/// turns, temporary folders, a throwaway defaults suite and fake sharing seams.
@MainActor
final class WindowVisibilityTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var window: NSWindow?

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "tokrate.popover.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> HistoryStore {
        HistoryStore(
            persistenceURL: root.appendingPathComponent("history.json"),
            codexFolder: root.appendingPathComponent("codex", isDirectory: true),
            claudeProjectsFolder: root.appendingPathComponent("claude", isDirectory: true),
            grokSessionsFolder: root.appendingPathComponent("grok", isDirectory: true),
            sharingPreferences: SharingPreferences(
                session: SharingSession(identity: StubIdentity(), transport: StubTransport()),
                store: StubPreferenceStore()
            ),
            defaults: defaults,
            initialRecords: PreviewData.records()
        )
    }

    private func makeWindow(contentView: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        self.window = window
        return window
    }

    private func settle() {
        for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.08)) }
    }

    func testReaderReportsWindowOrderingInAndOut() {
        var reports: [Bool] = []
        let view = WindowVisibilityView()
        view.onChange = { reports.append($0) }
        let window = makeWindow(contentView: view)
        XCTAssertEqual(reports, [false])
        window.orderFrontRegardless()
        XCTAssertEqual(reports, [false, true])
        window.orderOut(nil)
        XCTAssertEqual(reports, [false, true, false])
    }

    func testHiddenPopoverRendersNoContent() {
        let store = makeStore()
        let hidden = NSHostingView(rootView: MenuBarView(store: store, updates: AppUpdates(info: [:]), isWindowVisible: false))
        let visible = NSHostingView(rootView: MenuBarView(store: store, updates: AppUpdates(info: [:])))
        _ = makeWindow(contentView: hidden)
        settle()
        XCTAssertEqual(hidden.fittingSize.width, MenuBarView.width)
        XCTAssertLessThan(hidden.fittingSize.height, 50, "A popover that has never been shown has no content to keep the height of.")
        window?.contentView = visible
        settle()
        XCTAssertGreaterThan(visible.fittingSize.height, 200, "Previews and tests render the full dashboard by default.")
    }

    func testPopoverContentFollowsWindowAndKeepsItsHeightWhileHidden() {
        let store = makeStore()
        let hosting = NSHostingView(rootView: MenuBarView(store: store, updates: AppUpdates(info: [:]), followsWindowVisibility: true))
        let window = makeWindow(contentView: hosting)
        settle()
        XCTAssertLessThan(hosting.fittingSize.height, 50, "Hidden until the window is on screen.")

        window.orderFrontRegardless()
        settle()
        let shownHeight = hosting.fittingSize.height
        XCTAssertGreaterThan(shownHeight, 200)

        window.orderOut(nil)
        settle()
        XCTAssertEqual(hosting.fittingSize.height, shownHeight, accuracy: 0.5, "Hiding must not resize the window.")

        window.orderFrontRegardless()
        settle()
        XCTAssertEqual(hosting.fittingSize.height, shownHeight, accuracy: 0.5)
    }

    func testHistoryWindowRendersOnlyWhileOnScreen() {
        let hosting = NSHostingView(rootView: HistoryWindowView(store: makeStore(), updates: AppUpdates(info: [:])))
        let window = makeWindow(contentView: hosting)
        window.setContentSize(NSSize(width: 940, height: 780))
        settle()
        let hiddenSize = hosting.fittingSize
        XCTAssertEqual(hiddenSize.width, 820, "The minimum size stays in force while the history is not rendered.")
        XCTAssertEqual(hiddenSize.height, 680)

        window.orderFrontRegardless()
        settle()
        XCTAssertGreaterThan(hosting.fittingSize.height, 680, "The history renders once the window is on screen.")

        window.orderOut(nil)
        settle()
        XCTAssertEqual(hosting.fittingSize.height, 680)
    }
}

private struct StubIdentity: SharingIdentity {
    func loadOrCreate() throws -> Data { Data(repeating: 7, count: 32) }
}

private struct StubTransport: SharingTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) { (Data(), 202) }
}

@MainActor
private final class StubPreferenceStore: SharingPreferenceStore {
    var sharingEnabled: Bool?
    var consentRecord: SharingConsentRecord?
}
