@testable import TopoText
import Foundation
import Testing

@Suite struct NoteEditTrialTests {
    @Test("The trial edits of a large document are sound, and take time in proportion to its size")
    func largeDocumentTrials() throws {
        // The size of a large real note: 200,000 code units in 20,000 substrings, four in five of them deleted text,
        // from six replicas, with a few substrings that have two children.
        let stored = try StoredNote(protobuf: largeDocument())
        #expect(stored.length == 199_980 && stored.substrings.count == 20_002 && stored.runs.count == 4_999)
        #expect(stored.substrings.filter(\.isTombstone).count == 16_000)
        #expect(stored.substrings.filter { $0.children.count > 1 }.count == 5)
        #expect(stored.brokenInvariants.isEmpty)

        var outcomes: [String: NoteEditTrial.Outcome] = [:]
        let elapsed = ContinuousClock().measure {
            for trial in NoteEditTrial.trials(for: stored) {
                outcomes[trial.name] = trial.run(on: stored)
            }
        }
        #expect(
            outcomes == [
                "append a checklist item": .sound,
                "insert text in the first paragraph": .sound,
                "delete a character of the last paragraph": .sound,
                "change a checklist item's state": .sound,
            ]
        )
        // A debug build takes about 0.7 seconds on a 2023 laptop. The bound leaves room for a slow test machine,
        // and still fails for work that grows with the square of the size, which took 9 seconds and more.
        #expect(elapsed < .seconds(5))
    }

    @Test("A document gets the trials that it has the paragraphs for")
    func trialsOfSmallDocuments() throws {
        let rich = try RichNote.stored()
        let trials = NoteEditTrial.trials(for: rich)
        #expect(trials.map(\.name).contains("change a checklist item's state"))
        for trial in trials {
            #expect(trial.run(on: rich) == .sound, "\(trial.name)")
        }

        let empty = try StoredNote(protobuf: storedDocument([], substrings: [originSubstring, endSubstring], replicas: []))
        let only = NoteEditTrial.trials(for: empty)
        #expect(only.map(\.name) == ["append a checklist item"])
        #expect(only.first?.run(on: empty) == .sound)
    }

    @Test("A trial on a document that the engine does not edit is refused, with the invariant and none of the contents")
    func refusedTrial() throws {
        // No end marker.
        let stored = try StoredNote(
            protobuf: storedDocument(
                [run("ab")],
                substrings: [originSubstring, SubstringSpec(replica: 1, clock: 0, length: 2, style: (1, 0))],
                replicas: [ReplicaSpec(uuid: replicaUUID(0x11), clocks: [2, 1])]
            )
        )
        let outcome = try #require(NoteEditTrial.trials(for: stored).first).run(on: stored)
        #expect(outcome == .refused("unsupportedDocument, not true that \(StoredNote.Invariant.endSubstring.rawValue)"))
    }

    @Test("The check names each thing that an edit changed outside its range")
    func failures() throws {
        let before = try RichNote.stored()
        let end = before.paragraphRanges[0].content.upperBound
        let expectation = NoteEditTrial.Expectation(replaced: end ..< end, inserted: 1)
        let edited = try NoteEditor().apply([.insertText("!", at: .offset(end))], to: before)
        #expect(before.failures(of: edited, expecting: expectation) == [])

        func failures(_ change: (inout StoredNote) -> Void) -> [String] {
            var changed = edited
            change(&changed)
            return before.failures(of: changed, expecting: expectation)
        }
        let last = try #require(edited.substrings.lastIndex { $0.isVisible })

        #expect(
            before.failures(of: edited, expecting: .init(replaced: end ..< end, inserted: 2)).contains(
                "the number of new characters is not the number inserted"
            )
        )
        #expect(before.failures(of: edited, expecting: .init(replaced: 0 ..< 0, inserted: 1)).contains("the new characters are not where the edit was"))
        #expect(
            failures { $0.substrings[last].isTombstone = true }.contains("a character outside the range is deleted, or one inside it is not")
        )
        #expect(failures { $0.substrings[last].styleTimestamp.clock += 1 } == ["a style timestamp outside the edit changed"])
        #expect(failures { $0.substrings[last].id.clock += 1 }.contains("a character is lost or out of order"))
        #expect(failures { $0.substrings[last].id = $0.substrings[1].id }.contains("two characters have one identifier"))
        #expect(failures { $0.substrings[0].children = [2] } == ["a substring can't be reached from the first"])
        let style = WireMessage([.init(1, .varint(100))])
        #expect(failures { $0.runs[$0.runs.count - 1].paragraphStyle = style } == ["the attributes after the edit changed"])
        #expect(failures { $0.runs[0].paragraphStyle = style }.contains("the attributes before the edit changed"))
        #expect(failures { $0.replicas[0].styleClock += 1 } == ["the entry of another replica changed"])
        #expect(
            failures { $0.text = "?" + $0.text.dropFirst() }.contains("the text before the edit changed")
        )

        // The edit named another replica than the one that made it.
        let other = NoteEditTrial.Expectation(replaced: end ..< end, inserted: 1, replica: replicaUUID(0x11))
        #expect(before.failures(of: edited, expecting: other).contains("a new character is deleted, or is not the editing replica's"))
    }

    @Test("Shifting child indexes writes the bytes that setting the children writes")
    func shiftChildren() throws {
        // The indexes 127 and 300 take one byte more and the same number of bytes when 1 is added.
        var message = PB()
        message.int(2, 3)
        for child in [2, 127, 300] { message.int(5, child) }
        message.string(9, "kept")
        let substring = StoredNote.Substring(try WireMessage(message.data))

        var shifted = substring
        shifted.shiftChildren(from: 100)
        var set = substring
        set.children = [2, 128, 301]
        #expect(shifted.children == [2, 128, 301])
        #expect(shifted == set && shifted.encoded == set.encoded)
        #expect(try StoredNote.Substring(encoded: shifted.encoded) == shifted)

        var unchanged = substring
        unchanged.shiftChildren(from: 301)
        #expect(unchanged.encoded == Array(message.data))

        var packedMessage = PB()
        packedMessage.bytes(5, [0x02, 0xAC, 0x02])
        var packed = StoredNote.Substring(try WireMessage(packedMessage.data))
        packed.shiftChildren(from: 3)
        #expect(packed.children == [2, 301])
        #expect(packed.message.bytes(5) == [0x02, 0xAD, 0x02])
    }

    @Test("A varint that is longer than it needs to be, or holds more than 64 bits, keeps its bytes")
    func varintForms() throws {
        let forms: [[UInt8]] = [
            // The shortest forms, which are stored without a copy of their bytes.
            [0x08, 0x00],
            [0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01],
            // A zero in two bytes, and a tenth byte with bits that do not fit.
            [0x08, 0x80, 0x00],
            [0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F],
            // A key and a length in two bytes.
            [0x88, 0x00, 0x01],
            [0x12, 0x81, 0x00, 0x41],
        ]
        for bytes in forms {
            let message = try WireMessage(bytes)
            #expect(message.encoded() == bytes)
            var changed = message
            changed.set(message.fields[0].number, message.fields[0].value)
            #expect(changed.encoded() == bytes)
        }
        #expect(try WireMessage(forms[1]).varint(1) == .max)
        #expect(try WireMessage(forms[3]).varint(1) == .max)
        #expect(try WireMessage(forms[3]).reencoded(as: .init()) == forms[1])
    }
}
