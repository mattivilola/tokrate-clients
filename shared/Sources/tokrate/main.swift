import Foundation
import TokrateCore

private struct InspectionOutput: Encodable {
    let schemaVersion = 1
    let metrics: [TurnMetric]
}

@main
enum TokrateCommand {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1] == "inspect" else {
            FileHandle.standardError.write(Data("Usage: tokrate inspect <session.jsonl>\n".utf8))
            Foundation.exit(2)
        }

        let url = URL(fileURLWithPath: arguments[2])
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
}
