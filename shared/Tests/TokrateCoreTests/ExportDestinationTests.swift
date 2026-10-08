import Foundation
import XCTest
@testable import TokrateCore

final class ExportDestinationTests: XCTestCase {
    private var root: URL!
    private var folders: SourceFolders!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tokrate-export-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        folders = SourceFolders(
            codex: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            claudeCode: home.appendingPathComponent(".claude/projects", isDirectory: true),
            grokBuild: home.appendingPathComponent(".grok/sessions", isDirectory: true),
            antigravity: home.appendingPathComponent(".gemini", isDirectory: true),
            openCode: home.appendingPathComponent(".local/share/opencode", isDirectory: true)
        )
        for folder in [folders.codex, folders.claudeCode, folders.grokBuild, folders.antigravity, folders.openCode] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("elsewhere"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var elsewhere: URL { root.appendingPathComponent("elsewhere", isDirectory: true) }

    private func assertInsideSourceFolder(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ExportDestination.validated(url, sourceFolders: folders), file: file, line: line) { error in
            guard case ExportDestination.Rejection.insideSourceFolder = error else { return XCTFail("\(error)", file: file, line: line) }
        }
    }

    func testADestinationInsideAnySourceFolderIsRefusedAndNothingIsWritten() throws {
        let session = folders.codex.appendingPathComponent("rollout.jsonl")
        try Data("session".utf8).write(to: session)
        for folder in [folders.codex, folders.claudeCode, folders.grokBuild, folders.antigravity, folders.openCode] {
            assertInsideSourceFolder(folder.appendingPathComponent("export.jsonl"))
            assertInsideSourceFolder(folder.appendingPathComponent("deeper/../export.jsonl"))
            assertInsideSourceFolder(folder)
        }
        XCTAssertThrowsError(try ExportDestination.write(Data("export".utf8), to: session, sourceFolders: folders))
        XCTAssertEqual(try Data(contentsOf: session), Data("session".utf8), "the session file is untouched")
    }

    func testSymbolicLinksAndDotDotCannotSmuggleADestinationIntoASourceFolder() throws {
        let linkToFolder = elsewhere.appendingPathComponent("link-to-codex")
        try FileManager.default.createSymbolicLink(at: linkToFolder, withDestinationURL: folders.codex)
        assertInsideSourceFolder(linkToFolder.appendingPathComponent("export.jsonl"))
        assertInsideSourceFolder(elsewhere.appendingPathComponent("../home/.codex/sessions/export.jsonl"))
        // A link to a session file, as the destination itself.
        let session = folders.claudeCode.appendingPathComponent("transcript.jsonl")
        try Data("transcript".utf8).write(to: session)
        let linkToFile = elsewhere.appendingPathComponent("out.jsonl")
        try FileManager.default.createSymbolicLink(at: linkToFile, withDestinationURL: session)
        assertInsideSourceFolder(linkToFile)
        XCTAssertThrowsError(try ExportDestination.write(Data("export".utf8), to: linkToFile, sourceFolders: folders))
        XCTAssertEqual(try Data(contentsOf: session), Data("transcript".utf8))
        // A source folder reached through a link is resolved too.
        let home = root.appendingPathComponent("linked-home")
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: root.appendingPathComponent("home"))
        let viaLink = SourceFolders(
            codex: home.appendingPathComponent(".codex/sessions"), claudeCode: folders.claudeCode, grokBuild: folders.grokBuild,
            antigravity: folders.antigravity, openCode: folders.openCode
        )
        XCTAssertThrowsError(try ExportDestination.validated(folders.codex.appendingPathComponent("x.jsonl"), sourceFolders: viaLink))
    }

    func testANeighbouringFolderWithTheSamePrefixIsNotASourceFolder() throws {
        let neighbour = folders.codex.deletingLastPathComponent().appendingPathComponent("sessions-export", isDirectory: true)
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)
        XCTAssertNoThrow(try ExportDestination.validated(neighbour.appendingPathComponent("out.jsonl"), sourceFolders: folders))
    }

    func testADestinationThatExistsAndIsNotARegularFileIsRefused() throws {
        let fifo = elsewhere.appendingPathComponent("fifo.jsonl")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for url in [fifo, elsewhere] {
            XCTAssertThrowsError(try ExportDestination.validated(url, sourceFolders: folders)) { error in
                XCTAssertEqual(error as? ExportDestination.Rejection, .notRegularFile)
            }
        }
        // A link to a FIFO is refused too.
        let link = elsewhere.appendingPathComponent("link-to-fifo.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)
        XCTAssertThrowsError(try ExportDestination.validated(link, sourceFolders: folders))
        XCTAssertThrowsError(try ExportDestination.validated(elsewhere.appendingPathComponent("missing/out.jsonl"), sourceFolders: folders)) { error in
            XCTAssertEqual(error as? ExportDestination.Rejection, .missingFolder)
        }
    }

    func testANormalFileElsewhereIsOverwrittenAtomicallyAndOwnerOnly() throws {
        let out = elsewhere.appendingPathComponent("export.jsonl")
        try Data("old".utf8).write(to: out)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: out.path)
        try ExportDestination.write(Data("new".utf8), to: out, sourceFolders: folders)
        XCTAssertEqual(try Data(contentsOf: out), Data("new".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), ["export.jsonl"], "no temporary file is left")

        // A new file is owner-only whatever the umask, and a link elsewhere is written through.
        let previous = umask(0)
        defer { umask(previous) }
        let fresh = elsewhere.appendingPathComponent("fresh.jsonl")
        try ExportDestination.write(Data("fresh".utf8), to: fresh, sourceFolders: folders)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fresh.path)[.posixPermissions] as? Int, 0o600)
        let link = elsewhere.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fresh)
        try ExportDestination.write(Data("through".utf8), to: link, sourceFolders: folders)
        XCTAssertEqual(try Data(contentsOf: fresh), Data("through".utf8))
    }

    func testTheRejectionsExplainThemselves() {
        XCTAssertTrue(String(describing: ExportDestination.Rejection.insideSourceFolder("/home/me/.codex/sessions")).contains("/home/me/.codex/sessions"))
        XCTAssertTrue(String(describing: ExportDestination.Rejection.notRegularFile).contains("regular file"))
    }
}
