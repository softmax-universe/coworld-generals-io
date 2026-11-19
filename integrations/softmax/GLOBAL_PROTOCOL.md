# Generals Coworld global protocol v1 and replay formats

`GET /client/global` serves the public score viewer. Connect to `/global` for
JSON text updates. No spectator credential is required, so **this stream must
be safe for either competing player to read**. Incoming messages never mutate
the game. WebSocket ping receives a matching pong.

Updates contain `type: "global"`, `protocol_version: 1`, `phase`, `turn`,
`max_turns`, two to eight `players` display names, per-slot `army`, `land`, `eliminated`, `has_kill`, and `neutralize_in` arrays,
`ruleset`, `player_ratings`, `result`, `board`, public `chats` and game `events`.
Chat/event histories contain at most 128 entries. Private inboxes and pending
messages are never exposed. Public chat uses `{tick,player,text}`; game events
use `{tick,kind,player,target,text}`.
`player_ratings` is the public match-start leaderboard snapshot, shared with player
observations: `{league, label, players:[{slot, score}]}`, or null when unavailable. During the match, `board` and `result` are null. Phases
are `waiting`, `playing`, `resolving`, `saving`, `finished`, and `failed`;
brief transitional phases need not each be delivered to a slow viewer.

Only `finished` reveals a board and result. `GET /replay.json` returns HTTP 409
until then. The game server exits after completing the hosted episode; hosted
replay viewing uses the static bundle, independent of the game container.

The saved Polyworld replay uses upstream's `POLYWORLDREPLAY` binary container
(file format version 2), Generals' packed move stream and 64-bit tick hashes.
Ordinary moves occupy four bytes; passes need no action record. Extended words
preserve construction and rejected commands without losing replay semantics.

The versioned game identifier is `generals_hosted`, game version 3. Its typed
setup records the full unsigned 64-bit seed, generated dimensions, castle preset, public
roster, match-start skill labels and final outcome. Small per-tick markers retain
the order of steps, surrenders and delayed neutralization. Accepted public chat is stored inline in the same bounded action stream as moves,
in admission order after the completed tick. Tick-zero messages and repeated
text are retained. Playback and seeking use one cursor for movement and chat.
No JSON command objects, board frames, private messages, policy source, private logs, credentials or upload URLs
are persisted in the binary tape. Timeout counts and scoring remain in the
separate authoritative results artifact.

The WebAssembly viewer runs the same `polyworld_hosted.nim` transitions as the
game process. It checks the initial fingerprint and every completed tick,
including seeks, and rejects divergence. It reveals the result only at the end;
rewinding hides it again. Current standings supplied by the platform are loaded
as separate viewer metadata, leaving the downloaded replay bytes unchanged.
`/client/replay.data` returns the saved bytes with `application/octet-stream`.
`/replay.json` retains completed diagnostic frames for observation/scoring tools.
Both return HTTP 409 during play.

The standalone `generals` version 6 and older published JSON recordings
keep their own readers in their pinned releases. Hosted binary tapes add the
castle/surrender rules without reinterpreting those historical formats.

The retained JAX runtime saves its JSON frame recording:

- `format: "generals-coworld"`, `version: 2`, `ruleset: "classic"` or `"build_castles"`.
  Archived release 0.1.0 replays use `ruleset: "competition"` instead.
- Actual `seed`, `height`, `width`, and two to eight display names in `players`.
- `frames`: the initial board and every completed tick. Each frame includes
  `turn`, public `army`, `land`, `eliminated`, `kills`, and `neutralize_in`.
  The first frame and every 256th frame contain full `type_grid`, `owner_grid`,
  and `army_grid` arrays. Other frames contain `grid_delta`: an array of
  `[flat_cell_index, type, absolute_owner, army]` replacements. Use the nearest
  preceding full frame and apply changes in order. Seeking needs at most 255
  delta applications; it never expands the complete recording.
- Replay owners are absolute: 0 neutral, otherwise slot + 1. Replay types use
  the player type codes without fog. The viewer retains the published v1 full-frame
  reader for historical saved recordings; pinned old bundles remain unchanged.
- `turns`: each attempted tick's `turn`, `actions`, per-seat `timed_out`,
  `forfeited` (explicit FFA surrenders/disconnects or classic timeout forfeits),
  and `applied`. Apply these surrenders before the tick's moves. FFA additionally
  applies initial inactivity at tick 121, delayed neutralization after growth,
  and idle/long-game adjudication. A terminal classic forfeit can stop before
  the move/growth tick (`applied: false`), with a final frame at the same tick.
- `result`: the same final scoring object sent to players.

There are no tokens or presigned upload URLs in replays. Board frames allow
browser playback without resimulating JAX. Seed and action history additionally
allow deterministic resimulation against the recorded ruleset release.

The static viewer loads a replay URL from `#replay=`, falling back to `?replay=`.
The native viewer accepts binary tapes or gzip identified by magic bytes. Internal assets use
relative URLs and replay fetching needs CORS when hosted on a different origin.
The viewer sends `coworld-replay` loading/phase/ready/error messages to its
embedding parent, autoplays, loops, and exposes pause, seek, speed and restart.

Release 0.4.0 enables mutual general trades in classic mode. For resimulation,
use the episode’s pinned source revision: older classic releases disabled this
rule. Stored board frames remain the authoritative playback data.

The browser player client accepts local binary/gzip tapes and retained JAX JSON files on its entry screen. During
replay, its perspective selector derives each player's 3×3 territory visibility
from the recorded board frame. Hidden castles and mountains appear as obstacles;
hidden generals, ownership, and armies remain concealed. This is a playback
option only; the public live stream never sends hidden board data.

Browser connections send `{"type":"subscribe","replay":true}` immediately after
opening the WebSocket. This opt-in crosses proxies without depending on URL query
forwarding. Their successful
terminal update includes `replay: {encoding: "gzip+base64", data: "..."}`,
the complete saved recording compressed once for bounded delivery. It is sent only
after replay and result artifacts are saved. The browser renders those bytes
in its preloaded native viewer without another HTTP request, because the hosted live proxy can retire immediately
after completion. Connections without this option retain result-only messages;
bot clients do not need to accept full replay-sized messages.

Finished and failed global updates close the spectator socket cleanly. Hosted
shutdown waits for its owned terminal sends to finish before stopping the server.
