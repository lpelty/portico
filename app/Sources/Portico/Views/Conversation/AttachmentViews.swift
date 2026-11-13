import AppKit
import SwiftUI

/// A loaded attachment image, or the sign that there is none to show.
enum AttachmentImage: @unchecked Sendable, Equatable {
    case image(NSImage)
    /// The file is gone or is not an image AppKit can read (spec Review Focus 2).
    case missing

    static func == (lhs: AttachmentImage, rhs: AttachmentImage) -> Bool {
        switch (lhs, rhs) {
        case (.missing, .missing): true
        case (.image(let a), .image(let b)): a === b
        default: false
        }
    }
}

/// Attachment images, loaded off the main thread with `NSImage(contentsOf:)`
/// and kept in a small cache keyed by path and modification date, so an
/// edited file shows its new picture.
final class AttachmentImageCache: @unchecked Sendable {
    static let shared = AttachmentImageCache()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    /// Synchronous: call it off the main thread (`AttachmentThumbnail` does).
    func load(path: String) -> AttachmentImage {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            (attributes[.type] as? FileAttributeType) != .typeDirectory
        else { return .missing }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(modified)|\(path)" as NSString
        if let hit = cache.object(forKey: key) { return .image(hit) }
        guard let image = NSImage(contentsOf: URL(fileURLWithPath: path)), image.isValid, image.size.width > 0 else {
            return .missing
        }
        cache.setObject(image, forKey: key)
        return .image(image)
    }
}

/// One image attachment as a thumbnail. In the composer a 64-pt rounded
/// square with an × on hover; in the sent message up to 160 pt wide.
/// Clicking it opens the image in the viewer.
struct AttachmentThumbnail: View {
    enum Size: Equatable {
        case composer
        case bubble
    }

    let path: String
    var size: Size = .bubble
    var onOpen: (String) -> Void
    var onRemove: ((String) -> Void)? = nil
    /// v0.26.4 (D4): told the thumbnail's laid-out height when the image replaces
    /// the placeholder; set only while diagnostics are on.
    var onLoaded: ((CGFloat) -> Void)? = nil

    @State private var loaded: AttachmentImage?
    @State private var hovering = false

    static let composerSide: CGFloat = 64
    static let bubbleMaxWidth: CGFloat = 160
    static let bubbleMaxHeight: CGFloat = 120
    /// What stands in for a file that is gone or unreadable.
    static let missingSymbol = "exclamationmark.triangle"
    static let loadingSymbol = "photo"

    /// A loaded image's height in the bubble: the frame clamps each side on its
    /// own (measured hosted: 200 × 100 lays out 160 × 100), so the height is the
    /// image's, at most `bubbleMaxHeight`.
    static func bubbleHeight(for size: CGSize) -> CGFloat {
        min(size.height, bubbleMaxHeight)
    }

    /// The symbol drawn in place of the picture, if any.
    static func placeholderSymbol(for loaded: AttachmentImage?) -> String? {
        switch loaded {
        case .image: nil
        case .missing: missingSymbol
        case nil: loadingSymbol
        }
    }

    private var name: String { URL(fileURLWithPath: path).lastPathComponent }

    var body: some View {
        Button { onOpen(path) } label: { face }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                if let onRemove, hovering {
                    Button { onRemove(path) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Theme.iconFont(15))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Theme.text, Theme.surface)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .tip("Remove \(name)")
                }
            }
            .onHover { hovering = $0 }
            .tip(loaded == .missing ? "\(path) is no longer there" : path)
            .accessibilityLabel(Text("Image \(name)"))
            .task(id: path) {
                let path = path
                loaded = await Task.detached(priority: .userInitiated) { AttachmentImageCache.shared.load(path: path) }.value
                if let onLoaded, case .image(let image) = loaded { onLoaded(Self.bubbleHeight(for: image.size)) }
            }
    }

    @ViewBuilder
    private var face: some View {
        let shape = RoundedRectangle(cornerRadius: size == .composer ? 8 : 10, style: .continuous)
        Group {
            if case .image(let image) = loaded {
                switch size {
                case .composer:
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.composerSide, height: Self.composerSide)
                case .bubble:
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: Self.bubbleMaxWidth, maxHeight: Self.bubbleMaxHeight)
                }
            } else {
                Image(systemName: Self.placeholderSymbol(for: loaded) ?? Self.loadingSymbol)
                    .font(Theme.iconFont(size == .composer ? 18 : 22))
                    .foregroundStyle(Theme.text3)
                    .frame(
                        width: size == .composer ? Self.composerSide : Self.bubbleMaxWidth,
                        height: size == .composer ? Self.composerSide : Self.bubbleMaxHeight * 0.75)
                    .background(Theme.control)
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(Theme.border, lineWidth: 1))
        .contentShape(shape)
    }
}

/// A file that is not an image: its name in a small bordered chip. In
/// the composer it has an ×; in the message clicking it opens the file.
struct AttachmentChip: View {
    let path: String
    var onOpen: ((String) -> Void)? = nil
    var onRemove: ((String) -> Void)? = nil

    private var name: String { URL(fileURLWithPath: path).lastPathComponent }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc")
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            if let onRemove {
                Button(action: { onRemove(path) }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.hover)
                .foregroundStyle(.secondary)
                .tip("Remove \(path)")
            }
        }
        .scaledFont(12)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture { onOpen?(path) }
        .pointerStyle(onOpen == nil ? nil : .link)
        .tip(path)
    }
}

/// A composer's attachments (v0.19 spec §8.1): image thumbnails, then the
/// other files' chips, in one row that scrolls sideways when it overflows.
struct AttachmentStrip: View {
    let paths: [String]
    var onOpen: (String) -> Void
    var onRemove: (String) -> Void

    var body: some View {
        let split = Attachment.split(paths)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(split.images, id: \.self) { path in
                    AttachmentThumbnail(path: path, size: .composer, onOpen: onOpen, onRemove: onRemove)
                }
                ForEach(split.files, id: \.self) { path in
                    AttachmentChip(path: path, onRemove: onRemove)
                }
            }
            // Room for the × that sits over a thumbnail's corner.
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }
}

/// What a sent message's bubble shows (v0.19 spec §8.1, §8.4): the typed
/// text, image thumbnails above it, other files as chips under it. With an
/// older gateway (`attachments` absent) the text is shown as it came.
struct BubbleContent: Equatable {
    var text: String
    var images: [String]
    var files: [String]

    init(_ user: UserText) {
        text = user.text
        let split = Attachment.split(user.attachments ?? [])
        images = split.images
        files = split.files
    }
}

/// Lays children left to right, wrapping to a new row when one is full;
/// rows align to the trailing edge (a bubble's), or the leading one.
struct WrappingRows: Layout {
    var spacing: CGFloat = 6
    var trailing = true

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + row.height - size.height), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
