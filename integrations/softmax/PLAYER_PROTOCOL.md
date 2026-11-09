# Generals Coworld player protocol v1

Connect to the runner-provided `COWORLD_PLAYER_WS_URL`, a fully formed URL like
`ws://game:8080/player?slot=0&token=...`. Never log the URL/token. Use WebSocket
JSON text messages. Python `websockets` clients should use `ping_timeout=None`.
The game answers WebSocket ping frames normally. One connection may occupy each
slot; invalid credentials and concurrent duplicate connections are rejected.

The game sends a `hello` with `protocol_version: 1`, your `slot` (0 through player count minus one), board
`height` and `width`, two to eight display names in `players`, and
`ruleset: "classic"` or `"build_castles"`. Wait for an `observation` before sending actions.

Board dimensions vary and may be rectangular. Use the observed `height` and
`width` when allocating encoders and decoding flat action indices. Do not assume a fixed
21×21 whole-board encoding. Pass replies can produce zero timeouts
without expanding; verify moves and land growth when checking a player.

Each observation has:

| Field | Meaning |
| --- | --- |
| `type` | `"observation"` |
| `protocol_version`, `slot`, `height`, `width`, `players` | Same as the handshake |
| `turn` | Current state tick, starting at 0 |
| `last_move_executed` | Whether your preceding turn's move executed; `null` initially or after pass/build. An executed attack need not capture its destination. |
| `max_turns` | Engine-tick cap: 50002 for FFA bots, 2000 for other bots, 1200 for human variants |
| `afk_warning` | FFA initial inactivity warning, ticks 99–120 |
| `turn_timeout_seconds` | Deadline duration from server observation publication |
| `my_land`, `my_army`, `opp_land`, `opp_army` | Public totals; opponents aggregate all other players |
| `player_ratings` | Public leaderboard snapshot at match start: `{league, label, players:[{slot, score}]}`; `null` when unavailable. Scores can be negative/decimal; an unrated seat has `score:null`. Also sent in `hello` and live spectator messages. |
| `public_scores` | Per-slot `army`, `land`, `eliminated`, `has_kill`, and `neutralize_in` arrays |
| `eliminated` | Whether your slot is eliminated; stop sending actions/chat and spectate the full board |
| `ruleset` | Same as handshake |
| `visible_owner_grid` | Fog-masked absolute owners: 0 neutral/unknown, otherwise slot + 1 |
| `build_cost_grid` | Building mode only: cost on owned plain tiles, otherwise 0 |
| `last_build_executed` | Whether preceding build succeeded; null after other actions or initially |
| `type_grid` | H rows of W integers: 0 fog, 1 plain, 2 mountain, 3 castle, 4 general, 5 structure in fog |
| `owner_grid` | H×W, perspective-relative: 0 neutral/unknown, 1 me, 2 any opponent |
| `army_grid` | H×W visible army counts; zero in fog |

Messages and public events are shared with BASIC seats. Each observation adds
`mailbox: {last_id, messages:[{id,text}]}`, public `chats: [{tick,player,text}]`,
and `events: [{tick,kind,player,target,text}]`. Inbox IDs are a zero-based private
sender, −2 for public chat/game events, or −3 after an empty read. Only your
inbox is included. Public histories retain the most recent 128 entries.

Send `{"type":"chat","target":-2,"text":"Hello"}` to broadcast, or target a
zero-based seat for a private message. One pending message per seat is allowed;
text uses Polyworld's 140-character normalization. Messages are delivered in
seat order after all decisions resolve, never during another seat's decision.
Chat also queues during paced resolution, independently of move submission.

Send `{"type":"mailbox","count":3}` to consume three oldest entries. Up to
101 reads are allowed; a read past the empty inbox sets `last_id` to −3.
The next observation carries the remaining inbox and last sender ID. Neither
chat nor mailbox reads consumes the move slot. The final message also carries
the final inbox and public game events. Private messages are excluded from
spectator updates and saved replays. Human controls use these same commands.

Reply with exactly these three fields:

```json
{"type":"action","turn":12,"action":[0,5,8,3,0]}
```

`action` contains five integers `[kind, row, col, direction, split]`:

- `kind`: 0 move, 1 pass, or 2 build only in `build_castles` mode. Building
  uses `[2,row,col,0,0]`; the selected owned plain tile pays its current cost.
  Classic games reject kind 2 without consuming the action slot.
- `row`, `col`: a source cell within the board bounds.
- `direction`: 0 up, 1 down, 2 left, 3 right.
- `split`: 0 all-but-one, 1 half (rounded down).

Use `[1,0,0,0,0]` to pass. All five values must
be valid integers even when a field is unused. The server rejects booleans,
floats, out-of-range coordinates, invalid directions, stale/future turns,
extra message fields, and malformed shapes before entering JAX. Legally shaped
but impossible game actions are no-ops, as in the regular engine.

Only the **first valid message for the current turn** is accepted. Actions from
all surviving players resolve together using the engine's move-order rules.
In classic mode, simultaneous mutual general captures exchange generals and
territory without eliminating either player. Both moves are acknowledged as
executed. Castle-building mode retains ordinary ordered captures.
The server has no action queue: act only on the newest observation. The browser
player stores premoves locally and submits one action per observation using this
same protocol. The game advances
as soon as all surviving players' actions arrive, subject to the variant's minimum tick interval,
or when the deadline elapses. The human variant's minimum interval is 500 ms,
with a one-second action deadline to allow for proxy transport. Browser clients
send idle passes early; queued inputs after that pass execute on the next tick.
The competitive bot variant has no artificial delay and retains a 500 ms deadline.
FFA starts with the official 1.5-second initial input window. The observation
always advertises the deadline that applies to its tick.

Protocol errors return `{"type":"error","message":"..."}` and do not fill
the action slot. You may correct the action before the deadline. Oversized
messages close the connection. A missed action becomes a pass. In classic/build
modes, 20 consecutive misses forfeit; reconnection preserves accepted actions
and timeout counters. FFA does not eliminate players for transport misses.
Its initial inactivity check at tick 121 requires 11 land, an owned city, or
visible contact with an opponent. Eliminated seats no longer owe actions.

In FFA, send `{"type":"surrender"}` to surrender. This game event is
accepted during action collection or resolution, even after submitting an action.
Disconnecting also surrenders. The seat stops moving, while its owned general
and land remain capturable and keep growing for 50 ticks. Then uncaptured land
becomes neutral and the general becomes a city. `neutralize_in` is the number
of ticks remaining, or -1 when no capture window is pending. A living opponent
who destroyed the most army receives the neutralized player's kill credit.
Classic/build forfeits retain immediate neutralization. A player who never
connects causes an episode failure rather than an opponent win.

The final message is `{"type":"final","result":{...}}`, followed by a clean
close. `winner` is an absolute seat or -1 for a classic/build draw. `reason`
is `general_capture`, `turn_limit`, `idle_limit`, `forfeit`, or `double_forfeit`.
`turns` is the final engine tick; `army`, `land`, and `timeouts` have one entry
per seat. Classic/build `scores` remain +1/-1, or all zeros on a draw.

FFA results also include per-seat `placements`, `kills`, and `captured_by`
(-1 for no credited killer), plus the `elimination_order` seat sequence.
FFA Survival ranks the winner/players with kills ahead of kill-less players,
then uses reverse elimination order. Scores encode this order: +1 for first,
`-(place - 1) / (players - 1)` for others. These are outcomes, not official
star ratings. Idle and long-game limits adjudicate remaining players by army,
then land, then higher seat. Exit cleanly after receiving the final message.
`{"type":"failure","result":null}` means the game failed to complete.

Active seats receive no map seed, hidden board, other player's token, or
opponent action during play. The completed public replay reveals the full match. The baseline
bridge in `player.py` converts these observations to the existing stdio protocol;
its subprocess must respond within the deadline and exit on stdin EOF.

The stdio bridge preserves its relative-owner format in FFA (all enemies are 2).
Bots that need individual opponent identities or build prices should use the
JSON protocol. Active seats retain their fog of war.

Eliminated seats receive the full ongoing board through their authenticated
player observation and become spectators. Movement, public chat and private
chat remain forbidden after elimination. Private inboxes remain private.
Active seats retain fog of war; the unauthenticated global stream still reveals
only public scores until the match ends.

Browser connections send `{"type":"subscribe","replay":true}` immediately after
opening the WebSocket. This opt-in crosses proxies without depending on URL query
forwarding. Their successful
terminal update includes `replay`, the complete saved recording. It is sent only
after replay and result artifacts are saved. The browser renders those bytes
without another HTTP request, because the hosted live proxy can retire immediately
after completion. Connections without this option retain result-only messages;
bot clients do not need to accept full replay-sized messages.
