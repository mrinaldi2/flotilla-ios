import XCTest
@testable import Flotilla

/// The browser, commands and conversations parsing and logic, against frames
/// shaped as Gravity's docs/protocol.md describes them.
final class BrowserTests: XCTestCase {
    private func tabs(active: String?, open: Bool = true, bot: String = "b1") -> BrowserTabs {
        BrowserTabs([
            "bot_id": bot, "open": open, "active": active as Any, "following": false,
            "tabs": [["id": "t1", "title": "Pricing", "url": "https://a.example/pricing"],
                     ["id": "t2", "title": "", "url": "https://b.example/"]],
        ])
    }

    private func frame(tab: String, bot: String = "b1") -> BrowserFrame {
        BrowserFrame(["bot_id": bot, "tab_id": tab, "data": Data([0xFF, 0xD8, 0xFF]).base64EncodedString(),
                      "width": 1280, "height": 800])!
    }

    func testTabsParse() {
        let parsed = tabs(active: "t2")
        XCTAssertTrue(parsed.open)
        XCTAssertFalse(parsed.following)
        XCTAssertEqual(parsed.tabs.map(\.id), ["t1", "t2"])
        XCTAssertEqual(parsed.activeTab?.id, "t2")
        // A tab without a title goes by its address.
        XCTAssertEqual(parsed.activeTab?.label, "https://b.example/")
        // A daemon that leaves `following` out follows the bot.
        XCTAssertTrue(BrowserTabs(["bot_id": "b1", "open": false, "tabs": []]).following)
    }

    func testClosedBrowserCarriesItsReason() {
        let closed = BrowserTabs(["bot_id": "b1", "open": false, "tabs": [], "reason": "win-pc is offline"])
        XCTAssertFalse(closed.open)
        XCTAssertEqual(closed.reason, "win-pc is offline")
    }

    func testOnlyTheTabOnShowIsDrawn() {
        XCTAssertTrue(frame(tab: "t1").belongs(to: tabs(active: "t1")))
        XCTAssertFalse(frame(tab: "t1").belongs(to: tabs(active: "t2")), "a frame from the tab just left is stale")
        XCTAssertFalse(frame(tab: "t1").belongs(to: tabs(active: "t1", open: false)))
        XCTAssertFalse(frame(tab: "t1", bot: "b2").belongs(to: tabs(active: "t1")), "another bot's frame")
        XCTAssertFalse(frame(tab: "t1").belongs(to: nil))
    }

    func testFrameKeepsItsSizeAndRejectsBadData() {
        let parsed = frame(tab: "t1")
        XCTAssertEqual(parsed.width, 1280)
        XCTAssertEqual(parsed.height, 800)
        XCTAssertEqual(parsed.jpeg, Data([0xFF, 0xD8, 0xFF]))
        XCTAssertNil(BrowserFrame(["bot_id": "b1", "tab_id": "t1", "data": "not base64!", "width": 1, "height": 1]))
    }

    private func action(_ turn: String, _ step: String, trigger: JSONDict, chrome: Bool = false) -> BrowserAction {
        BrowserAction(["turn_id": turn, "step_id": step, "at": "2026-10-02T09:00:00Z",
                       "browser": chrome ? "owners_chrome" : "own", "title": "Opened \(step)",
                       "subtitle": "https://example.com", "status": "ok", "trigger": trigger])
    }

    func testActivityGroupsConsecutiveActionsByTurn() {
        let task: JSONDict = ["kind": "bus", "from": "lead", "msg_kind": "task", "num": 7, "text": "Compare the pricing tiers"]
        let owner: JSONDict = ["kind": "owner", "via": "chat", "text": "Check the login page"]
        let groups = BrowserTurnGroup.group([
            action("turn-2", "s4", trigger: owner, chrome: true),
            action("turn-1", "s3", trigger: task),
            action("turn-1", "s2", trigger: task),
            action("turn-0", "s1", trigger: task),
        ])
        XCTAssertEqual(groups.map(\.turnId), ["turn-2", "turn-1", "turn-0"])
        XCTAssertEqual(groups[1].actions.map(\.stepId), ["s3", "s2"], "newest first, as the daemon sent them")
        XCTAssertEqual(groups[0].why, "You")
        XCTAssertEqual(groups[0].ask, "Check the login page")
        XCTAssertTrue(groups[0].actions[0].ownersChrome)
        XCTAssertEqual(groups[1].why, "Task from lead")
        XCTAssertEqual(groups[1].ask, "Compare the pricing tiers")
        XCTAssertFalse(groups[1].actions[0].ownersChrome)
    }

    func testATurnSplitByAnotherIsTwoGroups() {
        let trigger: JSONDict = ["kind": "routine", "name": "nightly", "text": "Check prices"]
        let groups = BrowserTurnGroup.group([
            action("a", "1", trigger: trigger), action("b", "2", trigger: trigger), action("a", "3", trigger: trigger),
        ])
        XCTAssertEqual(groups.map(\.turnId), ["a", "b", "a"])
        XCTAssertEqual(Set(groups.map(\.id)).count, 3, "each group has its own id")
        XCTAssertEqual(groups[0].why, "Routine nightly")
    }
}

final class CommandsTests: XCTestCase {
    private func command(_ id: String, status: String, background: Bool = false, exit: Int? = nil,
                         description: String? = nil, ended: String? = nil) -> BotCommand {
        var row: JSONDict = ["id": id, "command": "npm test\n--watch=false", "background": background,
                             "status": status, "started_at": "2026-10-02T09:00:00Z"]
        if let exit { row["exit_code"] = exit }
        if let description { row["description"] = description }
        if let ended { row["ended_at"] = ended }
        return BotCommand(row)
    }

    func testSectionsKeepRunningApart() {
        let commands = [command("1", status: "running", background: true), command("2", status: "done"),
                        command("3", status: "failed", exit: 1), command("4", status: "stopped")]
        let sections = BotCommand.sections(commands)
        XCTAssertEqual(sections.running.map(\.id), ["1"])
        XCTAssertEqual(sections.finished.map(\.id), ["2", "3", "4"])
    }

    func testDurations() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(BotCommand.elapsed(from: start, to: start.addingTimeInterval(12)), "12s")
        XCTAssertEqual(BotCommand.elapsed(from: start, to: start.addingTimeInterval(243)), "4m 03s")
        XCTAssertEqual(BotCommand.elapsed(from: start, to: start.addingTimeInterval(3900)), "1h 05m")
        XCTAssertEqual(BotCommand.elapsed(from: start, to: start.addingTimeInterval(-5)), "0s")
    }

    func testWhenShowsTheDurationOnceEnded() {
        let format: (Date) -> String = { _ in "09:00" }
        XCTAssertEqual(command("1", status: "running").when(format), "09:00")
        XCTAssertEqual(command("2", status: "done", ended: "2026-10-02T09:01:05Z").when(format), "09:00 · 1m 05s")
    }

    func testTitleAndOutcome() {
        XCTAssertEqual(command("1", status: "done").title, "npm test", "the command's first line")
        XCTAssertEqual(command("1", status: "done", description: "Run the tests").title, "Run the tests")
        XCTAssertNil(command("1", status: "running").outcome)
        XCTAssertEqual(command("1", status: "done", exit: 0).outcome, "done")
        XCTAssertEqual(command("1", status: "failed", exit: 2).outcome, "exit 2")
        XCTAssertEqual(command("1", status: "stopped").outcome, "stopped")
    }

    func testOnlyARunningBackgroundCommandIsPolled() {
        XCTAssertTrue(BotCommand.needsPolling([command("1", status: "running", background: true)]))
        XCTAssertFalse(BotCommand.needsPolling([command("1", status: "running")]))
        XCTAssertFalse(BotCommand.needsPolling([command("1", status: "done", background: true)]))
    }
}

final class ConversationsTests: XCTestCase {
    private func message(_ num: Int, from: String = "a", body: String = "hi") -> AgentMessage {
        AgentMessage(["id": "m\(num)", "num": num, "from_bot_id": from, "to_bot_id": from == "a" ? "b" : "a",
                      "kind": "task", "body": body, "task": ["id": "t1", "state": "open"],
                      "created_at": "2026-10-02T09:00:00Z"])
    }

    func testPairKeyIgnoresOrder() {
        XCTAssertEqual(AgentConversations.key(["b", "a"]), AgentConversations.key(["a", "b"]))
    }

    func testPagesMergeByIdOldestFirst() {
        let loaded = [message(5), message(6)]
        let older = [message(3), message(4), message(5)]
        XCTAssertEqual(AgentConversations.merge(loaded, older).map(\.num), [3, 4, 5, 6])
        XCTAssertEqual(AgentConversations.merge([], []).count, 0)
    }

    func testTheBotHigherInTheListSitsLeft() {
        let order = ["lead", "dev", "qa"]
        XCTAssertEqual(AgentConversations.sides(["qa", "lead"], order: order).left, "lead")
        XCTAssertEqual(AgentConversations.sides(["lead", "qa"], order: order).left, "lead")
        // A bot no longer listed goes after one that is.
        XCTAssertEqual(AgentConversations.sides(["gone", "dev"], order: order).left, "dev")
    }

    func testTitlesAndPreviews() {
        let bots = [
            "lead": AgentBot(["id": "lead", "name": "lead", "avatar": "icon:orbit", "deleted": false]),
            "windev": AgentBot(["id": "windev", "name": "windev", "avatar": "", "machine": "win-pc", "deleted": false]),
        ]
        XCTAssertEqual(AgentConversations.title(("lead", "windev"), bots: bots), "lead ↔ windev @ win-pc")
        XCTAssertEqual(AgentConversations.bot("nobody", in: bots).name, "unknown bot")
        let conversation = AgentConversation([
            "bot_ids": ["lead", "windev"], "message_count": 4, "last_at": "2026-10-02T09:00:00Z",
            "last": ["id": "m1", "num": 1, "from_bot_id": "windev", "to_bot_id": "lead", "kind": "done",
                     "body": "Built   the\nupdater", "created_at": "2026-10-02T09:00:00Z"],
        ])
        XCTAssertEqual(AgentConversations.preview(conversation, bots: bots), "windev: Built the updater")
        XCTAssertEqual(conversation.last?.kindLabel, "Result")
        XCTAssertEqual(conversation.messageCount, 4)
    }

    func testMessageParse() {
        let parsed = message(9)
        XCTAssertEqual(parsed.taskState, "open")
        XCTAssertEqual(parsed.kindLabel, "Task")
        XCTAssertNotNil(parsed.createdAt)
    }
}

@MainActor
final class CapabilityTests: XCTestCase {
    private func bot(linked: Bool) -> Bot {
        var row: JSONDict = ["id": "b", "project_id": "p", "name": "dev", "user_chrome": true]
        if linked { row["peer"] = ["id": "peer", "name": "win-pc", "online": true] }
        return Bot(row)
    }

    func testFeaturesFollowTheDaemonsCapabilities() {
        let store = AppStore(defaults: ComputerDefaults(id: "test"))
        XCTAssertFalse(store.hasBrowser(bot(linked: false)))
        XCTAssertFalse(store.hasCommands)
        XCTAssertFalse(store.hasConversations)
        XCTAssertFalse(store.hasTerminal(bot(linked: true)), "a linked bot's terminal needs peer_terminal")
        XCTAssertTrue(store.hasTerminal(bot(linked: false)))

        store.capabilities = ["bot_browser", "bot_commands", "agent_conversations", "restart_bot"]
        XCTAssertTrue(store.hasBrowser(bot(linked: false)))
        XCTAssertFalse(store.hasBrowser(bot(linked: true)), "a linked bot's browser needs peer_browser")
        XCTAssertTrue(store.hasCommands)
        XCTAssertTrue(store.hasConversations)
        XCTAssertFalse(store.canRestart, "restarting changes state: it needs the control grant")
        store.grants = ["read", "control"]
        XCTAssertTrue(store.canRestart)

        store.capabilities.formUnion(["peer_browser", "peer_terminal"])
        XCTAssertTrue(store.hasBrowser(bot(linked: true)))
        XCTAssertTrue(store.hasTerminal(bot(linked: true)))
    }

    func testBotParsesBrowserAccessAndMachine() {
        let linked = bot(linked: true)
        XCTAssertTrue(linked.userChrome)
        XCTAssertEqual(linked.peerName, "win-pc")
        XCTAssertTrue(linked.isLinked)
        XCTAssertFalse(Bot(["id": "x"]).userChrome, "off by default")
    }

    func testBothBusNamesCountAsTheBus() {
        XCTAssertTrue(BusTool.isBus("mcp__hermes-bus__send_message"))
        XCTAssertTrue(BusTool.isBus("mcp__gravity-bus__complete_task"))
        XCTAssertFalse(BusTool.isBus("mcp__playwright__browser_click"))
    }

    func testKindsAndStatesReadInSentenceCase() {
        XCTAssertEqual(["done", "task", "reply", "note", "chat", "mystery"].map(MessageKind.label),
                       ["Result", "Task", "Reply", "Note", "Message", "Message"])
        XCTAssertEqual(["open", "done", "cancelled", "expired"].map(TaskStateLabel.label),
                       ["Open", "Done", "Cancelled", "Expired"])
    }

    func testPermissionToolNamesNeverShowMCP() {
        func request(_ tool: String) -> PermissionRequest { PermissionRequest(["id": "p", "bot_id": "b", "tool": tool]) }
        XCTAssertEqual(request("Bash").toolName, "Bash")
        XCTAssertEqual(request("mcp__hermes-bus__send_message").toolName, "Send message")
        XCTAssertEqual(request("mcp__gravity-bus__complete_task").toolName, "Complete task")
        XCTAssertEqual(request("mcp__playwright__browser_click").toolName, "Playwright: browser click")
        XCTAssertEqual(request("mcp__claude-in-chrome__read_page").toolName, "Claude in chrome: read page")
        XCTAssertEqual(request("WebFetch").toolName, "WebFetch")
    }
}
