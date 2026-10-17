import Foundation

// The board's typed requests (hermes.board.v1 in binary frames, ADR-001) for
// the 0.19 kanban (K7): watching a project's board, moves, drafts,
// attachments and the owner's answer to a lead's proposal. The protocols let
// the view models run in tests without a daemon.

/// Reading and moving a project's board, live.
@MainActor
protocol BoardService: AnyObject {
    /// The snapshot `board_event` pushes continue from; pushes then reach `listen`ers.
    func watchBoard(projectId: String) async throws -> BoardSnapshot
    func listen(projectId: String, _ handler: @escaping (BoardEvent) -> Void) -> UUID
    func stopListening(projectId: String, _ token: UUID)
    func moveCheck(itemId: String) async throws -> Flotilla_Board_V1_MoveCheck
    func move(_ move: Flotilla_Board_V1_ItemMove) async throws -> Flotilla_Board_V1_MoveResult
}

/// A draft's life: created with its files, discussed, reviewed, finalized or discarded.
@MainActor
protocol DraftService: AnyObject {
    func createItem(_ create: Flotilla_Board_V1_ItemCreate) async throws -> Flotilla_Board_V1_EditResult
    func upload(_ chunk: Flotilla_Board_V1_AttachmentUpload) async throws -> UInt64
    func attach(_ attach: Flotilla_Board_V1_ItemAttach) async throws -> BoardItemDetail
    func draftChanges(itemId: String, markSeen: Bool) async throws -> Flotilla_Board_V1_DraftChanges
    /// Invites a bot to discuss a draft (`item_invite`), or, with `remove`, ends its discussion.
    func invite(itemId: String, botId: String?, remove: Bool) async throws -> BoardItemDetail
    /// The draft as the daemon has it (`item_get`).
    func item(_ id: String) async throws -> BoardItemDetail
    func finalize(itemId: String, version: UInt64, column: String?) async throws -> Flotilla_Board_V1_MoveResult
    func discard(itemId: String, version: UInt64, reason: String) async throws -> Flotilla_Board_V1_EditResult
    /// Takes back one revision (`item_draft_undo`, K5): the owner's alone.
    func undo(itemId: String, version: UInt64, revision: Int64) async throws -> Flotilla_Board_V1_EditResult
}

extension AppStore: BoardService, DraftService {
    /// One board request and its response, or the service's refusal as an error.
    func boardCall(_ request: Flotilla_Board_V1_BoardRequest.OneOf_Request, name: String) async throws
        -> Flotilla_Board_V1_BoardResponse.OneOf_Response {
        var board = Flotilla_Board_V1_BoardRequest()
        board.request = request
        let envelope = try await client.request(.boardRequest(board), name: name)
        guard case .boardResponse(let response)? = envelope.body, let answer = response.response else {
            throw DaemonError(code: "decode", message: "The Flotilla service did not answer \(name).")
        }
        return answer
    }

    private func unexpected(_ name: String) -> DaemonError {
        DaemonError(code: "decode", message: "The Flotilla service answered \(name) with something else.")
    }

    // MARK: Watching

    func watchBoard(projectId: String) async throws -> BoardSnapshot {
        var watch = Flotilla_Board_V1_BoardWatch()
        watch.projectID = projectId
        guard case .board(let snapshot) = try await boardCall(.boardWatch(watch), name: "board_watch") else { throw unexpected("board_watch") }
        return snapshot
    }

    func listen(projectId: String, _ handler: @escaping (BoardEvent) -> Void) -> UUID {
        let token = UUID()
        boardListeners[projectId, default: [:]][token] = handler
        return token
    }

    /// The last listener gone, the connection stops watching the project.
    func stopListening(projectId: String, _ token: UUID) {
        boardListeners[projectId]?[token] = nil
        guard boardListeners[projectId]?.isEmpty ?? true else { return }
        boardListeners[projectId] = nil
        guard status == .connected else { return }
        var unwatch = Flotilla_Board_V1_BoardUnwatch()
        unwatch.projectID = projectId
        Task {
            // Another screen of the project (a card pushed over the board) may watch it by now.
            guard boardListeners[projectId] == nil else { return }
            _ = try? await boardCall(.boardUnwatch(unwatch), name: "board_unwatch")
        }
    }

    /// A binary push: a board event goes to the screens watching its project.
    func envelopePushed(_ envelope: Flotilla_Wire_V1_Envelope) {
        guard case .boardPush(let push)? = envelope.body, case .boardEvent(let event)? = push.push else { return }
        for handler in (boardListeners[event.projectID] ?? [:]).values { handler(event) }
    }

    // MARK: Moves

    func moveCheck(itemId: String) async throws -> Flotilla_Board_V1_MoveCheck {
        var check = Flotilla_Board_V1_ItemMoveCheck()
        check.id = itemId
        guard case .moveCheck(let result) = try await boardCall(.itemMoveCheck(check), name: "item_move_check") else { throw unexpected("item_move_check") }
        return result
    }

    func move(_ move: Flotilla_Board_V1_ItemMove) async throws -> Flotilla_Board_V1_MoveResult {
        guard case .moved(let result) = try await boardCall(.itemMove(move), name: "item_move") else { throw unexpected("item_move") }
        return result
    }

    // MARK: Drafts and attachments

    func createItem(_ create: Flotilla_Board_V1_ItemCreate) async throws -> Flotilla_Board_V1_EditResult {
        guard case .edited(let result) = try await boardCall(.itemCreate(create), name: "item_create") else { throw unexpected("item_create") }
        return result
    }

    func upload(_ chunk: Flotilla_Board_V1_AttachmentUpload) async throws -> UInt64 {
        guard case .upload(let progress) = try await boardCall(.attachmentUpload(chunk), name: "attachment_upload") else { throw unexpected("attachment_upload") }
        return progress.received
    }

    func attach(_ attach: Flotilla_Board_V1_ItemAttach) async throws -> BoardItemDetail {
        guard case .item(let detail) = try await boardCall(.itemAttach(attach), name: "item_attach") else { throw unexpected("item_attach") }
        return detail
    }

    func draftChanges(itemId: String, markSeen: Bool) async throws -> Flotilla_Board_V1_DraftChanges {
        var changes = Flotilla_Board_V1_ItemDraftChanges()
        changes.id = itemId
        if markSeen { changes.markSeen = true }
        guard case .draftChanges(let result) = try await boardCall(.itemDraftChanges(changes), name: "item_draft_changes") else {
            throw unexpected("item_draft_changes")
        }
        return result
    }

    func invite(itemId: String, botId: String?, remove: Bool) async throws -> BoardItemDetail {
        var invite = Flotilla_Board_V1_ItemInvite()
        invite.id = itemId
        if let botId { invite.bot = botId }
        if remove { invite.remove = true }
        guard case .item(let detail) = try await boardCall(.itemInvite(invite), name: "item_invite") else { throw unexpected("item_invite") }
        return detail
    }

    func finalize(itemId: String, version: UInt64, column: String?) async throws -> Flotilla_Board_V1_MoveResult {
        var finalize = Flotilla_Board_V1_ItemFinalize()
        finalize.id = itemId
        finalize.expectedVersion = version
        if let column { finalize.column = column }
        guard case .moved(let result) = try await boardCall(.itemFinalize(finalize), name: "item_finalize") else { throw unexpected("item_finalize") }
        return result
    }

    func discard(itemId: String, version: UInt64, reason: String) async throws -> Flotilla_Board_V1_EditResult {
        var discard = Flotilla_Board_V1_ItemDiscard()
        discard.id = itemId
        discard.expectedVersion = version
        discard.reason = reason
        guard case .edited(let result) = try await boardCall(.itemDiscard(discard), name: "item_discard") else { throw unexpected("item_discard") }
        return result
    }

    func undo(itemId: String, version: UInt64, revision: Int64) async throws -> Flotilla_Board_V1_EditResult {
        var undo = Flotilla_Board_V1_ItemDraftUndo()
        undo.id = itemId
        undo.expectedVersion = version
        undo.revision = revision
        guard case .edited(let result) = try await boardCall(.itemDraftUndo(undo), name: "item_draft_undo") else { throw unexpected("item_draft_undo") }
        return result
    }

    /// An attachment's bytes, read a chunk at a time (`attachment_read`).
    func attachmentData(_ id: String) async throws -> Data {
        var data = Data()
        while true {
            var read = Flotilla_Board_V1_AttachmentRead()
            read.attachmentID = id
            read.offset = UInt64(data.count)
            guard case .attachment(let chunk) = try await boardCall(.attachmentRead(read), name: "attachment_read") else {
                throw unexpected("attachment_read")
            }
            data.append(chunk.data)
            if chunk.data.isEmpty || UInt64(data.count) >= chunk.total { return data }
        }
    }

    // MARK: Proposals

    /// The owner's answer to a lead's proposed board change (`approve`).
    func ruleProposal(_ id: String, approve: Bool, note: String?) async throws {
        var rule = Flotilla_Board_V1_BoardProposalRule()
        rule.proposalID = id
        rule.approve = approve
        if let note, !note.isEmpty { rule.note = note }
        _ = try await boardCall(.boardProposalRule(rule), name: "board_proposal_rule")
        await refreshDecisions()
    }

    // MARK: Messages

    /// A message pinned to a card or a draft (`send_user_message{item_id}`).
    func sendMessage(botId: String, body: String, itemId: String) async throws {
        let reply = try await client.request("send_user_message", ["to_bot_id": botId, "body": body, "item_id": itemId])
        if let message = reply.dict("message").map(BusMessage.init) { append(message) }
    }
}
