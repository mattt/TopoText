import Foundation

// The merge state of a note, and how a local edit changes it.
//
// Each rule here is a fact from the format notes (see "Merge state" in <doc:NoteStore>),
// which give the source of each one. The rules marked "Inference" are not stated by a source.
// This file changes the substrings and the replicas only;
// ``NoteEditor`` changes the text and the attribute runs to match.

extension StoredNote {
    /// One set of changes to the merge state by one replica.
    ///
    /// Notes reads its style clock once for a set of changes, so every timestamp of a pass shares one floor.
    struct Pass {
        /// The 1-based index of the replica that makes the changes.
        let replica: Int
        /// The lowest style clock value that the pass may write.
        let floor: Int
        /// The highest style clock value that the pass wrote.
        fileprivate var highestStamp: Int?
        /// Whether the pass added a substring, as opposed to making its own last substring longer.
        fileprivate var addedSubstring = false
    }

    /// Starts a pass for a replica, and adds the replica to the vector timestamp if it is new to the document.
    ///
    /// A replica that joins a document starts both of its clocks at the highest values in the vector timestamp.
    ///
    /// The floor is the highest style timestamp in the document,
    /// plus one if that timestamp would win a tie against this replica.
    /// Timestamps compare by clock, then by the bytes of the replica's UUID.
    /// The floor is never below the replica's own style clock.
    mutating func beginPass(replica uuid: [UInt8]) -> Pass {
        let index: Int
        if let existing = replicas.firstIndex(where: { $0.uuid == uuid }) {
            index = existing + 1
        } else {
            replicas.append(
                Replica(
                    uuid: uuid,
                    textClock: replicas.map(\.textClock).max() ?? 0,
                    styleClock: replicas.map(\.styleClock).max() ?? 0
                )
            )
            index = replicas.count
        }

        var highest: (clock: Int, uuid: [UInt8])?
        for substring in substrings {
            let timestamp = substring.styleTimestamp
            // Replica 0 stands for the origin and the end marker, which carry no style.
            guard timestamp.replica >= 1, timestamp.replica <= replicas.count else { continue }
            let holder = replicas[timestamp.replica - 1].uuid
            if let current = highest {
                if timestamp.clock < current.clock { continue }
                if timestamp.clock == current.clock, !current.uuid.lexicographicallyPrecedes(holder) { continue }
            }
            highest = (timestamp.clock, holder)
        }
        let seed = highest.map { $0.clock + ($0.uuid.lexicographicallyPrecedes(uuid) ? 0 : 1) } ?? 0
        return Pass(replica: index, floor: max(seed, replicas[index - 1].styleClock))
    }

    /// Ends a pass: moves the replica's style clock past the timestamps that the pass wrote.
    ///
    /// A pass that only made the replica's own last substring longer leaves the style clock alone.
    /// A pass that added a substring leaves it at 1 or more.
    mutating func endPass(_ pass: Pass) {
        guard pass.highestStamp != nil || pass.addedSubstring else { return }
        replicas[pass.replica - 1].styleClock = max((pass.highestStamp ?? -1) + 1, pass.floor, pass.addedSubstring ? 1 : 0)
    }

    /// Marks a range of the text as deleted.
    ///
    /// Deleted characters stay in the document with a tombstone, because other replicas need them to merge.
    /// A substring that the range covers in part is split first.
    /// Each deleted substring takes the style timestamp `(replica, max(old clock + 8, floor))`:
    /// to Notes a deletion is a style operation, and the 8 lets it win against concurrent style changes.
    mutating func deleteVisible(_ range: Range<Int>, pass: inout Pass) {
        forEachVisibleSubstring(in: range) { substring in
            let clock = max(substring.styleTimestamp.clock + 8, pass.floor)
            substring.isTombstone = true
            substring.styleTimestamp = CharacterID(replica: pass.replica, clock: clock)
            pass.highestStamp = max(pass.highestStamp ?? clock, clock)
        }
    }

    /// Gives a range of the text a new style timestamp, as a style operation does.
    ///
    /// Each substring in the range takes `(replica, max(old clock + 1, floor))`.
    mutating func restampVisible(_ range: Range<Int>, pass: inout Pass) {
        forEachVisibleSubstring(in: range) { substring in
            let clock = max(substring.styleTimestamp.clock + 1, pass.floor)
            substring.styleTimestamp = CharacterID(replica: pass.replica, clock: clock)
            pass.highestStamp = max(pass.highestStamp ?? clock, clock)
        }
    }

    /// Inserts characters at a position of the text.
    ///
    /// The characters get the replica's next clock values, and the replica's text clock advances past them.
    /// If the substring before the position holds the replica's newest characters, that substring grows.
    /// Otherwise a new substring is added, with the style timestamp `(replica, 0)`, which stands for "never styled".
    /// The new substring goes after any deleted substrings at the position, as it does in the source.
    mutating func insertVisible(count: Int, at position: Int, pass: inout Pass) {
        guard count > 0 else { return }
        var index = substrings.count
        var offset = 0
        for current in substrings.indices {
            let substring = substrings[current]
            if substring.isEnd {
                index = current
                break
            }
            guard substring.isVisible else {
                index = current + 1
                continue
            }
            if position < offset + substring.length {
                if position == offset {
                    index = current
                } else {
                    split(current, at: position - offset)
                    index = current + 1
                }
                break
            }
            offset += substring.length
            index = current + 1
        }

        let clock = replicas[pass.replica - 1].textClock
        replicas[pass.replica - 1].textClock = clock + count
        if index > 0 {
            let previous = substrings[index - 1]
            if previous.isVisible, previous.id == CharacterID(replica: pass.replica, clock: clock - previous.length) {
                substrings[index - 1].length += count
                return
            }
        }

        var added = Substring(
            id: CharacterID(replica: pass.replica, clock: clock),
            length: count,
            styleTimestamp: CharacterID(replica: pass.replica, clock: 0)
        )
        shiftChildren(from: index)
        if index > 0 {
            // The substring that was at `index` is now a child index higher.
            var children = substrings[index - 1].children
            if let edge = children.firstIndex(of: index + 1) {
                // The new substring goes between its neighbors in the graph.
                children[edge] = index
                added.children = [index + 1]
                substrings[index - 1].children = children
            } else {
                // The neighbors in the list are not linked, as after concurrent insertions.
                // The new substring takes the children of the one before it, and becomes its only child.
                added.children = children
                substrings[index - 1].children = [index]
            }
        } else {
            added.children = [index + 1]
        }
        substrings.insert(added, at: index)
        pass.addedSubstring = true
    }

    /// Splits a substring in two at an offset within it.
    ///
    /// The second part's clock continues from the first part's, and it keeps the style timestamp and the tombstone.
    /// It takes over the children, and becomes the only child of the first part.
    private mutating func split(_ index: Int, at offset: Int) {
        shiftChildren(from: index + 1)
        var tail = substrings[index]
        tail.id.clock += offset
        tail.length -= offset
        substrings[index].length = offset
        substrings[index].children = [index + 1]
        substrings.insert(tail, at: index + 1)
    }

    /// Adds 1 to each child index at or past a position, ahead of an insertion into the list there.
    private mutating func shiftChildren(from threshold: Int) {
        for index in substrings.indices {
            let children = substrings[index].children
            if children.contains(where: { $0 >= threshold }) {
                substrings[index].children = children.map { $0 >= threshold ? $0 + 1 : $0 }
            }
        }
    }

    /// Calls a closure with each substring of the text in a range, after splitting the substrings at the range's ends.
    private mutating func forEachVisibleSubstring(in range: Range<Int>, _ body: (inout Substring) -> Void) {
        guard !range.isEmpty else { return }
        var index = 0
        var offset = 0
        while index < substrings.count, offset < range.upperBound {
            guard substrings[index].isVisible else {
                index += 1
                continue
            }
            let end = offset + substrings[index].length
            if end > range.lowerBound {
                if offset < range.lowerBound {
                    split(index, at: range.lowerBound - offset)
                    index += 1
                    offset = range.lowerBound
                }
                if range.upperBound < end {
                    split(index, at: range.upperBound - offset)
                }
                body(&substrings[index])
                offset += substrings[index].length
            } else {
                offset = end
            }
            index += 1
        }
    }
}
