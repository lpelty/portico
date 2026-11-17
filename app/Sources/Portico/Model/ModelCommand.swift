import Foundation

// MARK: - `/model` typed in a composer (v0.26.7, PORT-75)

/// `/model` opens the status strip's model menu; `/model <name>` switches
/// to that model. The engine lists `/model` among its commands but does
/// nothing with it when it arrives as a message, so the app answers it
/// and nothing is sent. Pure, so the matching is tested without a view.
enum ModelCommand: Equatable, Sendable {
    /// `/model` alone: open the menu.
    case open
    /// `/model <name>`: switch to the model `name` names.
    case named(String)

    static let unavailable = "The model can't be changed in this session."
    static let disconnected = "Not connected; the model can't be changed right now."

    /// What `text` asks for, read the way the gateway reads a command (the
    /// word, then a blank or the end); `nil` when it is not `/model`.
    static func parse(_ text: String) -> ModelCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let word = trimmed.dropFirst().prefix { !$0.isWhitespace && !$0.isNewline }
        guard word == "model" else { return nil }
        let name = trimmed.dropFirst(1 + word.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? .open : .named(name)
    }

    /// The choice `name` names, whatever the case: its value or its name
    /// in the menu (with or without the trailing parenthetical); else the
    /// model id it resolves to (a named choice before Default); else the
    /// only choice whose value or name contains `name`. `nil` when none
    /// does, or more than one.
    static func choice(named name: String, in choices: [ModelChoice]) -> ModelChoice? {
        let wanted = name.lowercased()
        func names(_ choice: ModelChoice) -> [String] {
            [choice.value, choice.displayName, ModelMenuPresentation.shortChoiceName(choice.displayName)].map { $0.lowercased() }
        }
        if let exact = choices.first(where: { names($0).contains(wanted) }) { return exact }
        let resolving = choices.filter { $0.resolvedModel?.lowercased() == wanted }
        if let byId = resolving.first(where: { $0.value != Models.defaultValue }) ?? resolving.first { return byId }
        let partial = choices.filter { choice in names(choice).contains { $0.contains(wanted) } }
        return partial.count == 1 ? partial[0] : nil
    }

    /// The one line that lists the models, for a name that matched none
    /// and for `/model` where the strip has no room for its menu.
    static func list(_ choices: [ModelChoice], current: String?) -> String {
        let now = current ?? Models.defaultValue
        // Full names but Default's: "Fable 5.1 (1M context)" is a different choice from "Fable 5.1".
        let names = choices.map { choice in
            let name = choice.value == Models.defaultValue ? ModelMenuPresentation.shortChoiceName(choice.displayName) : choice.displayName
            return choice.value == now ? "\(name) (current)" : name
        }
        return "Models: \(names.joined(separator: ", ")). Type /model and a name to switch."
    }

    static func unknown(_ name: String, in choices: [ModelChoice], current: String?) -> String {
        "No model matches \u{201C}\(name)\u{201D}. \(list(choices, current: current))"
    }
}

extension AppModel {
    /// `/model` typed in `chat`'s composer: the menu opens, or the named
    /// model is chosen, or one line says why not. Nothing is sent as a
    /// message. Returns whether `text` was the command.
    @discardableResult
    func runModelCommand(_ text: String, chat: Int) -> Bool {
        guard let command = ModelCommand.parse(text) else { return false }
        let menu = modelMenu(for: chat)
        guard menu.menu else {
            appendNotice(ModelCommand.unavailable, to: chat)
            return true
        }
        guard menu.enabled else {
            appendNotice(menu.connected ? ModelMenuPresentation.busyHelp + "." : ModelCommand.disconnected, to: chat)
            return true
        }
        switch command {
        case .open:
            modelMenuRequests += 1
        case .named(let name):
            guard let choice = ModelCommand.choice(named: name, in: menu.choices) else {
                appendNotice(ModelCommand.unknown(name, in: menu.choices, current: menu.current), to: chat)
                return true
            }
            if menu.checked(choice.value) {
                appendNotice("Already on \(ModelMenuPresentation.shortChoiceName(choice.displayName)).", to: chat)
            } else {
                // The gateway answers with the new list and a "Model: …" notice.
                setModel(choice.value, chat: chat)
            }
        }
        return true
    }

    /// The strip had no model menu on screen to open (a narrow window):
    /// the choices as one line instead.
    func listModels(chat: Int) {
        let menu = modelMenu(for: chat)
        appendNotice(ModelCommand.list(menu.choices, current: menu.current), to: chat)
    }
}
