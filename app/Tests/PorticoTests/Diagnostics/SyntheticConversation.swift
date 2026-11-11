import AppKit
import Foundation

@testable import Portico

/// A conversation rebuilt from recorded shapes alone (v0.26.4, D8, D11): filler
/// Markdown that reproduces each entry's metrics, and solid-colour PNG files of
/// the recorded pixel sizes, attached by path so they load through the real
/// thumbnail path. The replay runner hosts the real `ConversationView` on it;
/// none of the original words, paths or names are needed.
///
/// Not reproduced: `card`, `turnMarker`, `compacted`, `notice`, `agents`, `signin`,
/// `brief` and `divider` entries (rare in the field problems; skipped). A recording
/// keeps no block order, so blocks are interleaved in a fixed order, and a list
/// item's or heading's length (not recorded) is a typical one. Also not reproduced:
/// line breaks inside a paragraph (each is one line of prose), heading levels above 3
/// (they draw as 3 anyway) and nested list levels (one flat list). Two tool runs with
/// nothing emitted between them (side by side, or around a skipped kind) merge into one
/// run; a recording never holds them side by side, but may around a skipped card.
@MainActor
enum SyntheticConversation {
    // MARK: - filler words (3-9 letters)

    private static let words: [Int: [String]] = [
        3: ["sun", "map", "red", "log", "key", "bay", "oak", "fin", "web", "gum"],
        4: ["tale", "moon", "lake", "wind", "road", "gold", "fern", "dusk", "echo", "salt"],
        5: ["river", "stone", "cloud", "light", "grain", "trace", "bring", "plain", "forge", "orbit"],
        6: ["garden", "bridge", "silver", "winter", "market", "signal", "narrow", "anchor", "harbor", "pocket"],
        7: ["morning", "gallery", "network", "journey", "lantern", "compass", "pattern", "mineral", "balance", "kitchen"],
        8: ["mountain", "reliable", "calendar", "document", "painting", "treasure", "standard", "daylight", "frontier", "festival"],
        9: ["adventure", "framework", "carefully", "landscape", "structure", "knowledge", "wandering", "interface", "beautiful", "celebrate"],
    ]

    /// SplitMix64, seeded from the shape's id and a salt: the same shapes make the same text.
    private struct Generator {
        var state: UInt64
        init(_ id: String, _ salt: Int) {
            var hash: UInt64 = 0xcbf29ce484222325  // FNV-1a
            for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            state = hash ^ (UInt64(truncatingIfNeeded: salt) &* 0x9E3779B97F4A7C15)
        }
        mutating func next(_ bound: Int) -> Int {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Int((z ^ (z >> 31)) % UInt64(bound))
        }
    }

    /// `count` characters of prose-like words: 3-9 letters apiece, one space between.
    private static func filler(_ count: Int, _ generator: inout Generator) -> String {
        if count <= 0 { return "" }
        if count < 3 { return String("ok".prefix(count)) }
        var out: [String] = []
        var remaining = count  // characters still to place, counting a separating space
        while remaining > 0 {
            let space = out.isEmpty ? 0 : 1
            let room = remaining - space
            // A word that leaves nothing, or room for at least one more word (space + 3).
            let lengths = (3...9).filter { $0 <= room && (room - $0 == 0 || room - $0 >= 4) }
            guard let length = lengths.isEmpty ? nil : lengths[generator.next(lengths.count)] else {
                break  // fewer than 3 left over: cannot happen by construction for count >= 3
            }
            let choices = words[length]!
            out.append(choices[generator.next(choices.count)])
            remaining -= length + space
        }
        return out.joined(separator: " ")
    }

    // MARK: - text

    /// Filler Markdown reproducing the shape's paragraphs, headings, list items,
    /// code blocks, tables, quotes and rules; plain paragraphs for a person.
    static func text(matching shape: EntryShape) -> String {
        var salt = 0
        func make(_ count: Int) -> String {
            salt += 1
            var generator = Generator(shape.id, salt)
            return filler(count, &generator)
        }
        if shape.kind == .person { return shape.paragraphs.map(make).joined(separator: "\n\n") }

        var paragraphs = shape.paragraphs
        // A quote's inner paragraph counts as a paragraph too: quotes take the last ones.
        let quoted = Array(paragraphs.suffix(min(shape.quotes, paragraphs.count)))
        paragraphs.removeLast(quoted.count)

        var extras: [String] = []
        if shape.listItems > 0 { extras.append((0..<shape.listItems).map { _ in "- " + make(45) }.joined(separator: "\n")) }
        for lines in shape.codeBlocks {
            extras.append("```\n" + (0..<lines).map { _ in make(40) }.joined(separator: "\n") + (lines > 0 ? "\n" : "") + "```")
        }
        for table in shape.tables {
            let rows = table[0], columns = max(table[1], 1)
            func row() -> String { "| " + (0..<columns).map { _ in make(8) }.joined(separator: " | ") + " |" }
            extras.append(([row(), "|" + String(repeating: "---|", count: columns)] + (0..<rows).map { _ in row() }).joined(separator: "\n"))
        }
        for paragraph in quoted { extras.append("> " + make(paragraph)) }
        extras += Array(repeating: "---", count: shape.rules)

        var blocks: [String] = []
        for level in shape.headings {
            blocks.append(String(repeating: "#", count: min(max(level, 1), 3)) + " " + make(20))
            if !paragraphs.isEmpty { blocks.append(make(paragraphs.removeFirst())) }
        }
        for paragraph in paragraphs {
            blocks.append(make(paragraph))
            if !extras.isEmpty { blocks.append(extras.removeFirst()) }
        }
        blocks += extras
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - images

    /// A solid-colour PNG of exactly `size` pixels (`[0, 0]` becomes 1 x 1), one
    /// file per distinct size, written once.
    private static func imagePath(_ size: [Int], in directory: URL) throws -> String {
        let width = max(size.first ?? 0, 1), height = max(size.count > 1 ? size[1] : 0, 1)
        let url = directory.appendingPathComponent("image-\(width)x\(height).png")
        if FileManager.default.fileExists(atPath: url.path) { return url.path }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let data = rep.bitmapData
        else { throw CocoaError(.fileWriteUnknown) }
        memset(data, 0x80, rep.bytesPerRow * height)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: url)
        return url.path
    }

    // MARK: - events

    /// What `events` built: the messages, and which synthetic entry stands for each
    /// recorded one (`nil`: a skipped kind). Synthetic ids come from the model (a person
    /// row's carries a per-process hash, a reply's a counter), so a scratch model replays
    /// the events and recorded entries are paired with the synthetic ones by order among
    /// the non-skipped shapes. The ids hold for any fresh model fed the same events in
    /// this process, which is what `model(...)` builds.
    struct Built {
        var events: [ServerMessage]
        var ids: [String: String?]
    }

    /// `ChatHistory`-ready events for `shapes`, in order, each entry in a turn of its own.
    /// A `toolRun` of two rows uses viewer-step tools (the only two-row run the app folds);
    /// of three or more, `Read`; one row (never recorded) is a single tool.
    /// A single tool beside another tool entry is a Mark row, so it stays an entry of its own.
    static func events(chat: Int, shapes: [EntryShape], images: URL) throws -> Built {
        var out: [ServerMessage] = []
        var seq = 0
        var kept: [String] = []
        // Neighbours are those in the event stream: skipped kinds emit nothing, so two tool
        // entries around a card or a divider are adjacent there.
        let emitted = shapes.filter { ![.card, .turnMarker, .compacted, .notice, .agents, .signin, .brief, .divider].contains($0.kind) }
        func next() -> Int { seq += 1; return seq }
        for (index, shape) in shapes.enumerated() {
            let turn = index + 1
            switch shape.kind {
            case .person:
                var attachments = try shape.images.map { try imagePath($0, in: images) }
                attachments += (0..<shape.documents).map { images.appendingPathComponent("document-\(index)-\($0).txt").path }
                out.append(.userText(UserText(
                    chat: chat, turn: turn, text: text(matching: shape),
                    attachments: attachments.isEmpty ? nil : attachments, seq: next(),
                    // A fixed time: a person row's id hashes it, and the runner pairs ids across two builds (G2).
                    ts: "2026-11-01T09:00:00.000Z")))
            case .reply:
                out.append(.textDelta(TextDelta(chat: chat, turn: turn, text: text(matching: shape), seq: next())))
            case .tool, .toolRun:
                let rows = shape.kind == .tool ? 1 : max(shape.toolRows, 1)
                // A single tool row beside another tool row or run would fold into it and break
                // the count (real recordings have such neighbours around a question record or a
                // proposal): it stands alone, as the Mark row does. Two runs side by side cannot
                // be told apart and merge; recordings never hold that (the app folds them).
                let place = kept.count
                let neighbours = [place - 1, place + 1].contains { emitted.indices.contains($0) && [.tool, .toolRun].contains(emitted[$0].kind) }
                let name = shape.kind == .tool && neighbours ? ViewerSteps.markTool
                    : rows == 2 ? ViewerSteps.prefix + "look" : "Read"
                for row in 0..<rows {
                    let id = "tool-\(index)-\(row)"
                    out.append(.toolStarted(ToolStarted(
                        chat: chat, turn: turn, toolUseId: id, tool: name, summary: "notes.md", input: [:], seq: next())))
                    out.append(.toolFinished(ToolFinished(
                        chat: chat, turn: turn, toolUseId: id, ok: true, summary: "done", seq: next())))
                }
            case .card, .turnMarker, .compacted, .notice, .agents, .signin, .brief, .divider:
                continue
            }
            kept.append(shape.id)
        }
        var ids: [String: String?] = [:]
        for shape in shapes { ids[shape.id] = .some(nil) }
        let entries = TranscriptEntry.entries(try scratch(chat: chat, events: out).transcripts[chat] ?? [])
        for (position, id) in kept.enumerated() where position < entries.count { ids[id] = .some(entries[position].id) }
        return Built(events: out, ids: ids)
    }

    private static func scratch(chat: Int, events: [ServerMessage]) throws -> AppModel {
        let suite = "portico-synthetic-scratch-\(UUID().uuidString)"
        let defaults = try suiteDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        return build(chat: chat, events: events, defaults: defaults)
    }

    private static func suiteDefaults(_ suite: String) throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileWriteUnknown) }
        return defaults
    }

    /// A connected model with `chat` selected and `shapes` replayed into it.
    static func model(chat: Int, shapes: [EntryShape], images: URL, defaults: UserDefaults) throws -> AppModel {
        build(chat: chat, events: try events(chat: chat, shapes: shapes, images: images).events, defaults: defaults)
    }

    private static func build(chat: Int, events: [ServerMessage], defaults: UserDefaults) -> AppModel {
        let model = AppModel(settings: Settings(defaults: defaults))
        model.outbound = { _ in }
        model.relistDelay = .zero
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.26.4", epoch: "e",
            brand: Brand(name: "Acme", agentName: "Agent"), actions: [], roots: [],
            commands: [], capabilities: ["sessions"], presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: [ChatSummary(
            chat: chat, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z")])))
        model.selected = chat
        model.apply(.chatHistory(ChatHistory(chat: chat, events: events, truncated: false)))
        model.apply(.chatLive(ChatLive(chat: chat)))
        return model
    }
}
