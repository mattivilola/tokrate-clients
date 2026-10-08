import Foundation
import TokrateCore

private struct InspectionOutput: Encodable {
    let schemaVersion = 1
    let metrics: [TurnMetric]
}

private let usage = """
    Usage: tokrate inspect <session.jsonl>
           tokrate export-history --days <n> --out <file.jsonl> [--before <ISO-8601 instant>]

    """

private func fail(_ message: String? = nil, status: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data(((message.map { "\($0)\n" } ?? "") + usage).utf8))
    Foundation.exit(status)
}

private func refuse(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    Foundation.exit(1)
}

private func say(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

@main
enum TokrateCommand {
    /// The longest window the export accepts: thirteen months.
    static let maximumExportDays = 395

    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "inspect" {
            inspect(URL(fileURLWithPath: arguments[2]))
        } else if arguments.count >= 2, arguments[1] == "export-history" {
            await exportHistory(Array(arguments.dropFirst(2)))
        } else {
            fail()
        }
    }

    private static func inspect(_ url: URL) {
        do {
            var reader = JSONLFileReader(url: url)
            var records: [TurnMetric] = []
            while true {
                let batch = try reader.poll(maxBytes: 1_048_576)
                records.append(contentsOf: batch)
                if reader.bytesReadLastPoll == 0 { break }
            }
            records.sort { $0.completedAt > $1.completedAt }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let output = try encoder.encode(InspectionOutput(metrics: records))
            FileHandle.standardOutput.write(output)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            FileHandle.standardError.write(Data("Unable to inspect the selected Codex session file.\n".utf8))
            Foundation.exit(1)
        }
    }

    // MARK: export-history

    private struct ExportOptions {
        var days: Int
        var out: URL
        var before: Date?
    }

    private static func parseExportOptions(_ arguments: [String]) -> ExportOptions? {
        var days: Int?
        var out: String?
        var before: Date?
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else { return nil }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--days":
                guard days == nil, let parsed = Int(value), (1...maximumExportDays).contains(parsed) else { return nil }
                days = parsed
            case "--out":
                guard out == nil, !value.isEmpty else { return nil }
                out = value
            case "--before":
                guard before == nil, let parsed = parseInstant(value) else { return nil }
                before = parsed
            default:
                return nil
            }
            index += 2
        }
        guard let days, let out else { return nil }
        return ExportOptions(days: days, out: URL(fileURLWithPath: out), before: before)
    }

    private static func parseInstant(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    private static func exportHistory(_ arguments: [String]) async {
        guard let options = parseExportOptions(arguments) else { fail() }
        let now = Date.now
        let start = now.addingTimeInterval(-TimeInterval(options.days) * 86_400)
        let end = options.before ?? now
        guard start < end else { fail("--before must be later than the start of the --days window.") }
        // Before the replay, so a refused destination costs nothing.
        let folders = SourceFolders.defaults()
        do {
            _ = try ExportDestination.validated(options.out, sourceFolders: folders)
        } catch {
            refuse(String(describing: error))
        }

        // Reads session files only. It never contacts the network and never touches the signing key,
        // preferences, checkpoints, consent records or local history.
        let replay = await HistoryReplay.run(folders: folders, retention: TimeInterval(options.days) * 86_400)
        let result = HistoryExport.samples(from: replay.metrics, window: start..<end)

        do {
            let encoder = SampleEnvelope.makeEncoder()
            var output = Data()
            for sample in result.samples {
                output.append(try encoder.encode(sample))
                output.append(0x0A)
            }
            try ExportDestination.write(output, to: options.out, sourceFolders: folders)
        } catch let rejection as ExportDestination.Rejection {
            refuse(String(describing: rejection))
        } catch {
            refuse("Unable to write the export file.")
        }
        printSummary(result, replay: replay, start: start, end: end)
    }

    private static func printSummary(_ result: HistoryExport.Result, replay: HistoryReplay.Result, start: Date, end: Date) {
        let formatter = ISO8601DateFormatter()
        say("Exported \(result.samples.count) samples for turns completed in [\(formatter.string(from: start)), \(formatter.string(from: end))).")
        if let first = result.samples.first, let last = result.samples.last {
            say("First observedAt: \(formatter.string(from: first.observedAt))")
            say("Last observedAt: \(formatter.string(from: last.observedAt))")
        }
        func counts(_ keys: [String], _ title: String) {
            guard !keys.isEmpty else { return }
            say("\(title):")
            for (key, count) in Dictionary(grouping: keys, by: { $0 }).map({ ($0.key, $0.value.count) }).sorted(by: { ($1.1, $0.0) < ($0.1, $1.0) }) {
                say("  \(key): \(count)")
            }
        }
        counts(result.samples.map(\.client), "Samples per client")
        counts(result.samples.map(\.model), "Samples per model")
        say("Turns skipped by filter:")
        let skips = result.skipped.sorted { ($1.value, $0.key.label) < ($0.value, $1.key.label) }
        if skips.isEmpty { say("  none") }
        for (reason, count) in skips { say("  \(reason.label): \(count)") }
        for (client, reasons) in result.skippedByClient.sorted(by: { $0.key < $1.key }) {
            let line = reasons.sorted { ($1.value, $0.key.label) < ($0.value, $1.key.label) }
                .map { "\($0.key.label) \($0.value)" }.joined(separator: ", ")
            say("  \(client): \(line)")
        }
        if !replay.incompleteSources.isEmpty {
            say("Warning: not every file was read for: \(replay.incompleteSources.joined(separator: ", ")).")
        }
    }
}
