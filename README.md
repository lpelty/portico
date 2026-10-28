# Portico

Portico is one native Mac front for a local coding agent: a SwiftUI app that talks a small, versioned protocol over a loopback WebSocket to a reference gateway written in Python on the Claude Agent SDK. The gateway owns the agent session, numbers chats, forwards every permission and question to the app as a card, detects the files and URLs the agent produces, and replays history on reattach; the app is a pure protocol client with a sidebar, a conversation pane with inline cards, a viewer, a status strip, and settings. The protocol lives in `protocol/` and is the authority a deployment builds against.

Install: `bin/install` (gateway via `uv sync`, app via `swift build`). Run the gateway with `bin/portico-gateway run` and the app with `cd app && swift run`.
