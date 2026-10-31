import Foundation
import XCTest

@testable import Portico

/// v0.12 messages and model plumbing (viewer vision, spaces). The wire
/// shapes are hand-written fixtures in snake_case, as the gateway sends them.
@MainActor
final class ViewerSpacesPlumbingTests: XCTestCase {

    // MARK: - helpers

    private func decodeServer(_ json: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
    }

    private func encodedObject(_ message: ClientMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func isolatedSettings() -> Settings {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return Settings(defaults: defaults)
    }

    private func hello(defaults: ViewerDefaults? = ViewerDefaults(agentCanSee: true, agentChecksHTML: true, actHosts: ["figma.com"]))
        -> HelloServer
    {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.12.0", epoch: "e1",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [], roots: [], commands: [],
            capabilities: ["spaces.v1", "spaces.refresh"], viewerDefaults: defaults)
    }

    private func model(settings: Settings? = nil) -> (AppModel, AppModelTests.Sent) {
        let model = AppModel(settings: settings ?? isolatedSettings())
        let sent = AppModelTests.Sent()
        model.outbound = { sent.frames.append($0) }
        return (model, sent)
    }

    private func viewerSettingsFrames(_ sent: AppModelTests.Sent) -> [ViewerSettings] {
        sent.frames.compactMap { if case .viewerSettings(let v) = $0 { v } else { nil } }
    }

    private func space(_ id: String, updated: String = "2026-10-31T12:00:00Z") -> SpaceInfo {
        SpaceInfo(id: id, title: id, icon: "doc", order: nil, location: "/tmp/\(id).md", media: "markdown", updated: updated)
    }

    // MARK: - decoding the wire shapes

    func testHelloDecodesViewerDefaultsAndSpacesCapabilities() throws {
        let json = """
            {"type":"hello","protocol":\(protocolVersion),"gateway_version":"0.12.0","epoch":"e1",
             "brand":{"name":"Portico","agent_name":"Acme"},"actions":[],"roots":[],"commands":[],
             "capabilities":["spaces.v1","spaces.refresh"],
             "viewer_defaults":{"agent_can_see":true,"agent_checks_html":false,"act_hosts":["figma.com","lovable.dev"]},
             "ts":"2026-10-31T12:00:00Z"}
            """
        guard case .hello(let hello) = try decodeServer(json) else { return XCTFail("not a hello") }
        XCTAssertEqual(hello.viewerDefaults, ViewerDefaults(agentCanSee: true, agentChecksHTML: false, actHosts: ["figma.com", "lovable.dev"]))
        XCTAssertTrue(hello.capabilities.contains(SpacesList.capability))
        XCTAssertTrue(hello.capabilities.contains(SpacesList.refreshCapability))
    }

    func testHelloWithoutViewerDefaultsStillDecodes() throws {
        let json = """
            {"type":"hello","protocol":\(protocolVersion),"gateway_version":"0.11.0","epoch":"e1",
             "brand":{"name":"Portico","agent_name":"Acme"},"actions":[],"roots":[],"commands":[],
             "capabilities":[],"ts":"2026-10-31T12:00:00Z"}
            """
        guard case .hello(let hello) = try decodeServer(json) else { return XCTFail("not a hello") }
        XCTAssertNil(hello.viewerDefaults)
    }

    func testAppHelloNamesViewerCapability() throws {
        XCTAssertTrue(HelloClient.appCapabilities.contains("viewer.v1"))
        let object = try encodedObject(.hello(HelloClient(appVersion: "0.12.0", capabilities: HelloClient.appCapabilities)))
        XCTAssertTrue((object["capabilities"] as? [String] ?? []).contains("viewer.v1"))
    }

    func testViewerActDecodesEveryAction() throws {
        let cases: [(String, ViewerAct.Action, String)] = [
            ("look", .look, "{}"),
            ("click", .click, #"{"target":"e12"}"#),
            ("type", .type, #"{"target":"e3","text":"Sam","submit":true}"#),
            ("scroll", .scroll, #"{"direction":"down"}"#),
            ("back", .back, "{}"),
        ]
        for (name, action, args) in cases {
            let json = #"{"type":"viewer.act","id":"a1","chat":2,"action":"\#(name)","args":\#(args),"ts":"2026-10-31T12:00:00Z"}"#
            guard case .viewerAct(let act) = try decodeServer(json) else { return XCTFail("not a viewer.act for \(name)") }
            XCTAssertEqual(act.id, "a1")
            XCTAssertEqual(act.chat, 2)
            XCTAssertEqual(act.action, action)
            XCTAssertEqual(act.envelope.chat, 2)
        }
        let typed = #"{"type":"viewer.act","id":"a2","chat":1,"action":"type","args":{"target":"e3","text":"Sam","submit":true}}"#
        guard case .viewerAct(let act) = try decodeServer(typed) else { return XCTFail("not a viewer.act") }
        XCTAssertEqual(act.args["target"], .string("e3"))
        XCTAssertEqual(act.args["text"], .string("Sam"))
        XCTAssertEqual(act.args["submit"], .bool(true))
    }

    func testViewerResultEncodesImageAndNulls() throws {
        let withImage = ViewerResult(id: "a1", ok: true, text: "A page", image: .init(data: "AAAA"))
        let object = try encodedObject(.viewerResult(withImage))
        XCTAssertEqual(object["type"] as? String, "viewer.result")
        XCTAssertEqual(object["id"] as? String, "a1")
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["image"] as? [String: String], ["data": "AAAA", "media_type": "image/png"])
        XCTAssertTrue(object["error"] is NSNull, "error is null on the wire, not absent")

        let failure = ViewerResult(id: "a2", ok: false, text: "", error: "Nothing is open in the viewer.")
        let failed = try encodedObject(.viewerResult(failure))
        XCTAssertTrue(failed["image"] is NSNull)
        XCTAssertEqual(failed["error"] as? String, "Nothing is open in the viewer.")
        // And it reads back.
        let back = try JSONDecoder().decode(ClientMessage.self, from: JSONEncoder().encode(ClientMessage.viewerResult(failure)))
        XCTAssertEqual(back, .viewerResult(failure))
    }

    func testViewerSettingsEncodesSnakeCase() throws {
        let object = try encodedObject(.viewerSettings(ViewerSettings(canSee: true, checkHTML: false)))
        XCTAssertEqual(object["type"] as? String, "viewer.settings")
        XCTAssertEqual(object["can_see"] as? Bool, true)
        XCTAssertEqual(object["check_html"] as? Bool, false)
    }

    func testSpacesListDecodes() throws {
        let json = """
            {"type":"spaces.list","spaces":[
              {"id":"roadmap","title":"Roadmap","icon":"map","order":1,"location":"/spaces/roadmap.md","media":"markdown","updated":"2026-10-31T12:00:00Z"},
              {"id":"board","title":"board.html","icon":"doc","order":null,"location":"/spaces/board.html","media":"html","updated":"2026-10-30T08:30:00Z"}],
             "ts":"2026-10-31T12:00:01Z"}
            """
        guard case .spacesList(let list) = try decodeServer(json) else { return XCTFail("not spaces.list") }
        XCTAssertEqual(list.spaces.map(\.id), ["roadmap", "board"])
        XCTAssertEqual(list.spaces[0].order, 1)
        XCTAssertNil(list.spaces[1].order)
        XCTAssertEqual(list.spaces[1].media, "html")
        XCTAssertEqual(list.spaces[0].updatedDate, Date(timeIntervalSince1970: 1_793_448_000))
    }

    func testSpaceCommandsEncode() throws {
        let refresh = try encodedObject(.spaceRefresh(SpaceRefresh(id: "roadmap")))
        XCTAssertEqual(refresh["type"] as? String, "space.refresh")
        XCTAssertEqual(refresh["id"] as? String, "roadmap")
        let rename = try encodedObject(.spaceRename(SpaceRename(id: "roadmap", title: "Plan")))
        XCTAssertEqual(rename["type"] as? String, "space.rename")
        XCTAssertEqual(rename["title"] as? String, "Plan")
        let remove = try encodedObject(.spaceRemove(SpaceRemove(id: "roadmap")))
        XCTAssertEqual(remove["type"] as? String, "space.remove")
    }

    func testArtifactCreatedCarriesOptionalSpace() throws {
        let base = """
            {"type":"artifact.created","chat":1,"seq":4,"artifact":{"id":"x1","kind":"file","location":"/spaces/roadmap.md",
             "media":"markdown","title":"Roadmap","source":"tool","open":false\(",\"space\":\"roadmap\"")},"ts":"2026-10-31T12:00:00Z"}
            """
        let withSpace = base
        guard case .artifactCreated(let created) = try decodeServer(withSpace) else { return XCTFail("not artifact.created") }
        XCTAssertEqual(created.artifact.space, "roadmap")
        let without = withSpace.replacingOccurrences(of: ",\"space\":\"roadmap\"", with: "")
        guard case .artifactCreated(let plain) = try decodeServer(without) else { return XCTFail("not artifact.created") }
        XCTAssertNil(plain.artifact.space)
    }

    // MARK: - settings and sending

    func testViewerSettingsSentAfterHelloAndOnChange() {
        let (model, sent) = model()
        model.apply(.hello(hello()))
        XCTAssertEqual(viewerSettingsFrames(sent), [ViewerSettings(canSee: true, checkHTML: true)].map { $0 }, "sent once, after hello")
        XCTAssertEqual(sent.types().last, "viewer.settings", "after the opens hello owes")

        model.settings.viewerAgentChecksHTML = false
        XCTAssertEqual(viewerSettingsFrames(sent).count, 2)
        XCTAssertEqual(viewerSettingsFrames(sent).last?.checkHTML, false)
        XCTAssertEqual(viewerSettingsFrames(sent).last?.canSee, true)

        model.settings.viewerAgentCanSee = false
        XCTAssertEqual(viewerSettingsFrames(sent).count, 3)
        XCTAssertEqual(viewerSettingsFrames(sent).last, ViewerSettings(canSee: false, checkHTML: false))
    }

    func testViewerSettingsNotSentToAGatewayWithoutViewerDefaults() {
        let (model, sent) = model()
        model.apply(.hello(hello(defaults: nil)))
        model.settings.viewerAgentCanSee = false
        XCTAssertTrue(viewerSettingsFrames(sent).isEmpty, "a pre-v0.12 gateway has no such message")
    }

    func testDeploymentDefaultUntilPersonChanges() {
        let (model, sent) = model()
        model.apply(.hello(hello(defaults: ViewerDefaults(agentCanSee: false, agentChecksHTML: true, actHosts: []))))
        XCTAssertNil(model.settings.viewerAgentCanSee)
        XCTAssertFalse(model.agentCanSee, "the deployment says off")
        XCTAssertEqual(viewerSettingsFrames(sent).last, ViewerSettings(canSee: false, checkHTML: false))

        model.settings.viewerAgentCanSee = true
        XCTAssertTrue(model.agentCanSee, "the person's choice wins")
        XCTAssertTrue(model.agentChecksHTML, "the HTML default now applies")
        XCTAssertEqual(viewerSettingsFrames(sent).last, ViewerSettings(canSee: true, checkHTML: true))

        // A new gateway with other defaults does not move a choice the person made.
        model.apply(.hello(hello(defaults: ViewerDefaults(agentCanSee: false, agentChecksHTML: false, actHosts: []))))
        XCTAssertTrue(model.agentCanSee)
    }

    func testCheckHTMLOffWhenCanSeeOff() {
        let (model, sent) = model()
        model.apply(.hello(hello()))
        model.settings.viewerAgentChecksHTML = true
        model.settings.viewerAgentCanSee = false
        XCTAssertFalse(model.agentChecksHTML)
        XCTAssertEqual(viewerSettingsFrames(sent).last, ViewerSettings(canSee: false, checkHTML: false))
        model.sendViewerSettings()
        XCTAssertEqual(viewerSettingsFrames(sent).last, ViewerSettings(canSee: false, checkHTML: false))
    }

    func testViewerSettingsPersist() {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = Settings(defaults: defaults)
        XCTAssertNil(first.viewerAgentCanSee)
        XCTAssertTrue(first.spacesNotify)
        first.viewerAgentCanSee = false
        first.spacesNotify = false
        let when = Date(timeIntervalSince1970: 1_793_448_000)
        first.spacesLastOpened["roadmap"] = when
        let second = Settings(defaults: defaults)
        XCTAssertEqual(second.viewerAgentCanSee, false)
        XCTAssertNil(second.viewerAgentChecksHTML)
        XCTAssertFalse(second.spacesNotify)
        XCTAssertEqual(second.spacesLastOpened["roadmap"], when)
        second.viewerAgentCanSee = nil
        XCTAssertNil(Settings(defaults: defaults).viewerAgentCanSee, "nil goes back to the deployment default")
    }

    // MARK: - spaces

    func testSpacesListFillsModelAndActsReachHandler() {
        let (model, _) = model()
        var acts: [ViewerAct] = []
        model.viewerActHandler = { acts.append($0) }
        model.apply(.spacesList(SpacesList(spaces: [space("a"), space("b")])))
        XCTAssertEqual(model.spaces.map(\.id), ["a", "b"])
        model.apply(.viewerAct(ViewerAct(id: "x", chat: 1, action: .look)))
        XCTAssertEqual(acts.map(\.id), ["x"])
    }

    func testSpaceCommandsSend() {
        let (model, sent) = model()
        model.refreshSpace("a")
        model.renameSpace("a", to: "Plan")
        model.removeSpace("a")
        XCTAssertEqual(sent.types(), ["space.refresh", "space.rename", "space.remove"])
    }

    func testHasNewAfterUpdateClearedOnOpen() {
        let (model, _) = model()
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: "2026-10-31T12:00:00Z")])))
        XCTAssertTrue(model.hasNew("a"), "never opened")

        model.setOpenSpace("a")
        XCTAssertEqual(model.openSpace, "a")
        XCTAssertFalse(model.hasNew("a"), "opening clears it")

        // The file changes after the person opened it.
        let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: later)])))
        XCTAssertTrue(model.hasNew("a"))
        model.setOpenSpace("a")
        XCTAssertFalse(model.hasNew("a"))
        XCTAssertFalse(model.hasNew("unknown"))
    }

    func testNoDotWhenNotifyOff() {
        let (model, _) = model()
        model.settings.spacesNotify = false
        model.apply(.spacesList(SpacesList(spaces: [space("a")])))
        XCTAssertFalse(model.hasNew("a"))
    }

    func testOpenSpaceDroppedWhenItLeavesTheList() {
        let (model, _) = model()
        model.apply(.spacesList(SpacesList(spaces: [space("a")])))
        model.setOpenSpace("a")
        model.apply(.spacesList(SpacesList(spaces: [])))
        XCTAssertNil(model.openSpace)
    }
}
