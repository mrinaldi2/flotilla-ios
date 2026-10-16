# Linked projects: the protocol Flotilla for iPhone expects

Flotilla for iPhone lets you connect two daemons, link a project across them, and
create bots on either machine. The phone uses Gravity's existing peer requests
(`list_peers`, `create_peer_invite`, `add_peer`, `revoke_peer`) and
`create_bot`'s `runtime`. Everything else on this page is an addition to the
Gravity daemon, built on the peer link from `docs/peer-bots.md` in Gravity.
The phone shows these features only when `hello_ok.capabilities` contains
`linked_projects`.

## What a link means: one team, mirrored

Linking project A on one daemon with project B on a peer makes the two projects
one team:

- Every live bot on each side appears on the other side as a linked bot in the
  linked project (the stand-ins of `docs/peer-bots.md`), so bots address each
  other by name across machines and hand off tasks and files as linked bots
  already do.
- The link stays true. A bot created, renamed, changed (description, avatar,
  runtime) or archived on either side is mirrored to its stand-in on the other.
- Unlinking, from either side, archives the stand-ins on both sides (open tasks
  are cancelled, as when a bot is deleted) and removes the link on both sides.
  History is kept. Revoking the peer unlinks every project linked through it.
- A project is linked to at most one project per peer, and the link is recorded
  on both daemons.
- Bot names must stay unique within a project across both sides. A link that
  would clash is refused, naming the clashing bots.
- Stand-ins do not count towards the 12-bot limit; only bots that run on a
  daemon count there.

## Handshake

`hello_ok` adds `"daemon_id"`, the daemon's stable id (the one peers already
learn). A client connected to two daemons uses it to tell which peer row is
which daemon.

## Views

A project gains `links`, always present (empty when unlinked):

```json
"links": [{
  "peer_id": "…", "peer_name": "PC", "online": true,
  "remote_project_id": "…", "remote_project_name": "Aurora Notes",
  "linked_at": "2026-10-02T09:00:00Z"
}]
```

`project_updated` is pushed whenever a project's links change. Bots keep their
existing `peer` (`id`, `name`, `online`) and `runtime` fields.

## Requests

| Request | Grant | Fields | Reply |
|---|---|---|---|
| `list_peer_projects` | read | `peer_id` | `peer_projects`: `peer_id`, `projects: [{ id, name, bot_count, linked_project_id? }]`, where `linked_project_id` is the project here it is already linked with. Asks the peer; `unavailable` when it is offline. |
| `link_project` | control | `project_id, peer_id`, and `remote_project_id` to link an existing project on the peer, or neither to create one there named like this project (`remote_name` overrides the name) | `project` with its `links`. Errors: `not_found`, `unavailable` (peer offline), `conflict` (name clash, or either project already linked through that peer). |
| `unlink_project` | control | `project_id, peer_id` | `project` |
| `create_bot` | control | adds `peer_id?` | With `peer_id`, the project must be linked to that peer (`not_linked` otherwise). The peer creates a real bot in the linked project with the given `name, description, instructions, avatar, runtime` (no `runtime`: the peer's `default_bot_runtime`), and the reply's `bot` is the stand-in here, with `peer` set. |

## Bots creating bots on the other machine

The MCP tool `create_bot` gains an optional `machine` (a peer name, as
`list_bots` reports it). It is allowed only when the bot's project is linked
through that peer: the bot is created on the peer in the linked project and
appears here as a linked bot. The creator can `update_bot` and `delete_bot` it
like any bot it created; those calls are forwarded. The bus section of the
system prompt names the machines the project is linked with.

## Between daemons

New peer requests: `list_projects`, `link_project`, `unlink_project`,
`create_bot`, `update_bot`, `delete_bot`. New peer event: bots added, changed
or archived in a linked project. A peer may act only on projects linked
through it, except `list_projects` and `link_project`: pairing two daemons is
the owner's consent for either side to propose a link.
