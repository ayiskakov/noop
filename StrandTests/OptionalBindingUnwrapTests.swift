import XCTest

/// W06-053: `Binding($optional)` force-unwraps the optional on every read. The Raw Data Collector's marker
/// sheet edited `markerDraft` through one, SwiftUI read it again while the sheet closed, after Save or
/// Cancel had set the draft to nil, and the app ended in `BindingOperations.ForceUnwrapping.get`. A unit
/// test cannot present a sheet and close it, so this reads the app sources with comments removed: no view
/// may unwrap optional state into a binding. Give the edited value its own `@State` instead.
final class OptionalBindingUnwrapTests: XCTestCase {
    private static let appDirectories = ["Strand", "StrandiOS", "StrandiOSShared", "StrandiOSWidgets",
                                         "NOOPWatch", "NOOPWatchComplications"]

    func testNoViewUnwrapsOptionalStateIntoABinding() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var scanned: Set<String> = []
        var hits: [String] = []
        for directory in Self.appDirectories {
            let base = root.appendingPathComponent(directory)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let path = directory + url.path.dropFirst(base.path.count)
                scanned.insert(path)
                let source = try String(contentsOf: url, encoding: .utf8)
                    .replacingOccurrences(of: #"/\*.*?\*/"#, with: "", options: .regularExpression)
                for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                    if code.range(of: #"Binding\(\s*\$"#, options: .regularExpression) != nil {
                        hits.append("\(path):\(index + 1)")
                    }
                }
            }
        }
        // A scan that finds no files passes trivially; the collector is the file that crashed.
        XCTAssertTrue(scanned.contains("Strand/Screens/RawDataCollectorView.swift"), "scanned \(scanned.count) files")
        XCTAssertEqual(hits, [], "Binding($optional) crashes when the optional turns nil while a view still reads it")
    }
}
