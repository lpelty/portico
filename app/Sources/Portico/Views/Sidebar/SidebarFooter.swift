import SwiftUI

/// The person as the app names them: the first word of the account's full
/// name, shared by the welcome greeting and the sidebar footer (v0.9
/// decision 6, AE1). An empty name gives no first name and no initial, and
/// the footer draws a person glyph instead.
struct PersonName: Equatable, Sendable {
    /// "Larry" from "Larry Paul Pelty"; `nil` when the name is empty.
    let first: String?

    init(fullName: String = NSFullUserName()) {
        let word = fullName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        first = word.isEmpty ? nil : word
    }

    /// The round mark's letter, upper-cased; `nil` means draw the person glyph.
    var initial: String? { first.flatMap { $0.first }.map { String($0).uppercased() } }
}

/// The sidebar's footer, option A in AE1 (v0.9 decision 6), as in the
/// Claude desktop app: a round initial on the accent, the first name, and
/// a gear on the right that opens Settings. Pinned under the sidebar's
/// content, above a hairline.
struct SidebarFooter: View {
    @Environment(\.openSettings) private var openSettings
    let person: PersonName

    init(person: PersonName = PersonName()) {
        self.person = person
    }

    static let markSize: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 8) {
                mark
                if let first = person.first {
                    Text(first)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // The same Settings scene ⌘, opens (SwiftUI's openSettings).
                Button { openSettings() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var mark: some View {
        ZStack {
            Circle().fill(Theme.accent)
            if let initial = person.initial {
                Text(initial)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: Self.markSize, height: Self.markSize)
        .accessibilityHidden(true)
    }
}
