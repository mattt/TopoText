@testable import TopoText
import Foundation
import Testing

/// Runs the usage example in the README against a synthetic store; keep the two in sync.
@Suite struct UsageTests {
    @Test("The README usage example runs")
    func readme() async throws {
        let folder = try NotesFolder.current()
        var lines: [String] = []
        func print(_ items: Any...) {
            lines.append(items.map { "\($0)" }.joined(separator: " "))
        }

        let store = Store(root: folder.root)
        try await store.checkAccess()

        let folders = try await store.folders()
        let result = try await store.search(.init(query: "groceries"))
        for note in result.notes {
            print(note.id, note.title, note.modificationDate ?? .distantPast)
        }

        if let note = result.notes.first, !note.isLocked {
            let content = try await store.content(for: note.id)
            for paragraph in content.paragraphs {
                switch paragraph.style.kind {
                case .checklist:
                    print(paragraph.style.isChecked ? "[x]" : "[ ]", paragraph.text)
                default:
                    print(paragraph.text)
                }
            }
        }

        #expect(folders.count == 4)
        #expect(lines.first?.hasPrefix("NOTE-GROCERIES Groceries ") == true)
        #expect(lines.contains("[x] Milk"))
        #expect(lines.contains("[ ] Eggs"))
    }
}
