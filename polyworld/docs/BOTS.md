# BASIC bots and player settings

Each seat can use a local BASIC policy through the shared Polyworld host.
Seats without a bot file keep the native policy in headless matches.
Use Polyworld's `--bot PATH[:COUNT]` groups and `--player[:SEAT]` for normal
controller setup. See [command-line flags](CLI.md) for roster inference,
spectator matches, and the explicit per-seat assignment syntax below.

```sh
./out/generals --headless --players=2 --seat-bot=1:examples/scout.bas \
  --seat-name=1:Scout --mmr=1:37 --seat-name=2:Opponent --record=out/scout.replay
```

CLI seats are numbered **1 to 10**. BASIC player IDs and tile indices are
**zero-based**. Names use the supplied name, then the bot filename without
`.bas`, then `Player N`. An unknown MMR is `-1` and displays as `?`; zero is
a valid supplied rank. Names must be valid UTF-8 and at most 128 bytes.

`--player-info=off` disables BASIC name and MMR queries for every player.
The UI still shows the public roster. Names in host-generated mailbox
prefixes and game notices become `Player N`. The default is `on`.

## Engine configuration

`--config=PATH` accepts JSON with the same player-list convention as GotA:

```json
{
  "players": [
    {"name": "Scout", "mmr": 37, "bot": "../examples/scout.bas"},
    {"name": "Opponent", "mmr": -1}
  ],
  "seed": 7,
  "maxTicks": 4000,
  "width": 23,
  "height": 19,
  "exposePlayerInfo": true
}
```

Omitted fields use local game defaults. A supplied player list must contain
2 to 10 entries. `max_ticks` and `expose_player_info` are also accepted.
The config file is limited to 1 MiB. Explicit map dimensions must be 13 to
61. Omitted dimensions, or a value of `0`, use seeded dimensions based on
the player count. Changing the seed or player count recalculates these
automatic dimensions while keeping any explicit dimension. The seed must
be 0 to 18446744073709551615, and `maxTicks` must be 1 to 100000.
The shared `--seed` command-line override uses a signed 32-bit value.

Config bot paths are relative to the config file. CLI bot paths are relative
to the working directory. Explicit CLI options override config values
regardless of where `--config` appears. Repeated options use their last
value. The last `--config` selects the file.

## Player and clock queries

| Function | Result |
| --- | --- |
| `selfPlayer()` | This bot's zero-based player ID. |
| `playerCount()` | Number of active match seats. |
| `playerInfoEnabled()` | `1` when name and MMR queries are enabled, otherwise `0`. |
| `playerName$(id)` | Public name, or an empty string when disabled or invalid. |
| `mailboxName$(id)` | Alias for `playerName$(id)`. |
| `playerMmr(id)` | Supplied rank, or `-1` when unknown, disabled, or invalid. |
| `worldTick()` | Completed simulation ticks; each tick is half a second. |
| `worldTurn()` | Whole displayed turns, equal to `floor(worldTick() / 2)`. |

These are in-game values. No account identifier or external run identifier
is exposed by the game host.

## Board queries and moves

The board is a flat grid. Tile `(x, y)` has index `y * width() + x`.
All board queries respect this bot's fog of war.

| Function | Result |
| --- | --- |
| `width()`, `height()`, `tileCount()` | Board dimensions and total cells. |
| `selfGeneral()` | This bot's current general tile. |
| `visible(tile)` | `1` for a visible tile, otherwise `0`. |
| `terrain(tile)` | Plain `0`, mountain `1`, city `2`, general `3`. |
| `owner(tile)` | Zero-based owner, or `-1` for neutral or hidden land. |
| `army(tile)` | Visible army count, or `0` under fog. |
| `send(source, target, half)` | Queues one cardinal move; `half` must be `0` or `1`. |

Hidden mountains and cities both report terrain `-2`; other hidden cells
report `-1`. Out-of-range tiles return `visible = 0`, `terrain = -1`,
`owner = -1`, and `army = 0`.

`send` returns `1` when the order is accepted, or `0` when rejected. It
requires owned land with more than one army and an adjacent traversable
destination. Acceptance does not guarantee winning the battle. A policy
can submit at most one accepted move per decision. Omitting a move passes.

The program runs once before each tick and its variables persist between
decisions. Each decision allows 2,000,000 instructions and 4,000,000 work
units, with 8 MiB available for persistent BASIC memory.
A compile error aborts match setup. A runtime error reports the failing
seat and makes that policy pass for the remainder of the match.

## Messages

| Function | Result |
| --- | --- |
| `sendChat(target, text$)` | Queues one message; returns recipient count or `0` if rejected. |
| `pullMailbox$()` | Consumes the oldest message, or returns an empty string. |
| `mailboxId()` | Channel or sender ID of the last consumed message. |
| `mailboxCount()` | Number of messages waiting in this inbox. |
| `mailboxSelf()`, `mailboxPlayers()` | Aliases for the current ID and player count. |

Use target `-2` for global chat, or a zero-based player ID for a direct
message. `mailboxId()` returns `-2` for global chat and system events, the
sender's ID for direct messages, or `-3` when the mailbox was empty.

Every seat can queue one nonempty message per tick. Messages are delivered
in seat order after all policies decide and the simulation tick completes,
so no policy sees another seat's same-tick message early. Text is normalized
and limited to 140 characters. Each inbox holds at most 100 messages.
Capture, victory, and draw notices also arrive through the global channel;
these notices replace the oldest message when an inbox is full.

Global chat appears in the event log. Replays save up to 16,384 global
messages; later messages still deliver normally during the live match.
Direct messages stay in recipient inboxes. Replay playback uses recorded
actions, roster information, and global chat; it does not execute bot code.
