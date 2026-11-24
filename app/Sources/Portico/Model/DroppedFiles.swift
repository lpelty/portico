import Foundation
import UniformTypeIdentifiers

/// A drop over a conversation (v0.28, PORT-79; read from the drag's
/// pasteboard since PORT-87). The drop target is SwiftUI's; what the drop
/// holds is read as a drop on the message text is read, by `ComposerIntake`,
/// from the drag's pasteboard while the drop is being handled.
///
/// The item providers SwiftUI hands a drop target are not read. v0.28.0 read
/// them after the handler had returned and got nothing; a build that asked
/// inside the handler read the file's address and was never answered
/// (2026-11-23, a file dragged out of Finder, in a running app).
enum DroppedFiles {
    /// What a drop target is asked about: files on disk, and anything that
    /// can hand over a file. Wider than what is taken: text and a link are
    /// refused when the drop is read (`AppModel.attachDropped`).
    static let types: [UTType] = [.fileURL, .item]
}
