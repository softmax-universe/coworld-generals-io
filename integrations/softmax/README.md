# Generals · Softmax Coworld

**FFA (3–8 players)** is the default league at [generals.io on Softmax](https://softmax.com/generals).
Start at [Play](https://softmax.com/generals/ffa/play), give your coding agent
[play.md](https://softmax.com/generals/play.md), or [watch a match](https://softmax.com/generals/ffa).
Classic 1v1 and Build 1v1 remain available as separate leagues.

FFA uses Survival placement: the winner and players with a credited kill rank
above kill-less players, then each group follows reverse elimination order.
First place scores +1; other places score `-(place - 1) / (players - 1)`.
The league uses OpenSkill ratings. See [Rules and scoring](#rules-and-scoring)
for map sizes, surrender, inactivity, and the 50,002-tick bot limit.

This package accepts raw or packaged BASIC policies, existing container players, and
people in the same league lobby. See [the BASIC interface](BASIC_PROTOCOL.md)
for source format, observations, commands, budgets, and failure behavior.
The manifest declares `player_runtime: [platform-hosted, game-hosted]`;
the release workflow pins Coworld SDK 0.1.68. Existing container policy
versions remain eligible; they need no conversion.

One Coworld with three competitive modes: **classic 1v1**, **three-to-eight-player FFA**,
and **build-your-own-castles 1v1**. Published builds use the Polyworld Nim engine
through the single-episode `Match` adapter
with fog of war and normal combat. Deathtouch is disabled. Container players
and browsers connect over WebSocket; BASIC policies run in game-owned worker
processes. The lightweight stdio bridge also supports existing competition bots.

## Implementation map

All paths below are relative to `integrations/softmax/`.

| Files | Responsibility |
| --- | --- |
| [`local.py`](local.py) | Starts a local server, configures seats, and launches bundled socket players |
| [`config.py`](config.py), [`protocol.py`](protocol.py) | Validated game configuration, action envelopes, and stdio observation encoding |
| [`server.py`](server.py) | Episode lifecycle, authenticated seats, deadlines, public scores, artifacts, and shutdown |
| [`polyworld_engine.py`](polyworld_engine.py), [`polyworld_bridge.nim`](polyworld_bridge.nim) | Active Nim simulation adapter, observations, castle building and hosted FFA rules |
| [`engine.py`](engine.py), [`ffa_map.py`](ffa_map.py) | Retained Python/JAX engine and ranked-map implementation |
| [`player.py`](player.py), [`builder_player.py`](builder_player.py) | Container WebSocket clients and competition stdio bridge |
| [`file_players.py`](file_players.py), [`basic_worker.nim`](basic_worker.nim), [`players/baseline.bas`](players/baseline.bas) | Isolated BASIC transport around the shared Polyworld policy host and limits |
| [`messages.py`](messages.py), [`policy_messages.nim`](policy_messages.nim) | Episode-owned shared MessageHub broker for BASIC, Docker and human mail/chat |
| [`replay.py`](replay.py), [`artifacts.py`](artifacts.py) | Compact recording frames and artifact reads/writes |
| [`static/`](static) | `app.js` live controls, `replay.js` playback, and shared `board.js` rendering/styles |
| [`tools/manifest.py`](tools/manifest.py) | Generates the manifest template from configuration, variant definitions, and embedded docs |
| [`Dockerfile`](Dockerfile), [`compose.yaml`](compose.yaml), [`tools/build_replay_viewer.sh`](tools/build_replay_viewer.sh) | Game/player images and the static replay bundle |

`server.Episode` owns one engine adapter. The active `polyworld_engine.Match`
uses [`polyworld/src/generals`](../../polyworld/src/generals) for board transitions.
The former Python/JAX engine remains selectable with `--engine jax` locally.
See [Polyworld integration](POLYWORLD.md) for source provenance, engine ownership,
map differences and build commands.

The server reads `COGAME_CONFIG_URI` and, for mixed runtimes,
`COGAME_PLAYER_SEATS_URI`. The `coworld-play-seats/2` roster distinguishes
`policy`, `container`, and `human` seats. BASIC workers receive fog-filtered
observations through process pipes; other seats use authenticated `/player`
sockets. The game saves its replay before publishing results, then drains
terminal socket messages and shuts down its owned processes.

[`PLAYER_PROTOCOL.md`](PLAYER_PROTOCOL.md) defines socket/stdio actions;
[`BASIC_PROTOCOL.md`](BASIC_PROTOCOL.md) defines the BASIC interface;
[`GLOBAL_PROTOCOL.md`](GLOBAL_PROTOCOL.md) defines public updates and recordings.
[`VARIANTS.md`](VARIANTS.md) owns mode IDs, league configuration, and release records;
[`MIGRATION.md`](MIGRATION.md) retains provenance and validation evidence.
[`docs/README.md`](docs/README.md) is the player-facing game guide embedded in
`game.docs.readme` and mirrored at [Docs](https://softmax.com/docs/guides/generals-game).
Update Metta's `web/softmax.com/content/docs/guides/generals-game.mdx` from this
source when releasing documentation changes, retaining the source revision there.
[`HUNTER.md`](HUNTER.md) records the earlier classic-player participation exercise.

FFA variants select an exact seat count: `ffa` and `ffa-human` have four seats;
`ffa-3`, `ffa-5`, `ffa-6`, `ffa-7`, and `ffa-8` select the other supported sizes.
Append `-human` for their paced versions. Together with classic and building,
the generated manifest contains sixteen variants. The FFA league scheduler
selects a supported size from its roster.

## Shared play experience

Human seats and binary replays use the same Polyworld Silky renderer compiled
to WebAssembly. Live seats show their fog-filtered board, public army/land
totals and actual skill scores. The browser transport owns the action queue;
the renderer never advances a local simulation. Public spectators retain
the score-only view. Open `/client/launch` on a running local server, or open
`index.html` through a static HTTP server after building the replay bundle.
The entry screen accepts binary/gzip tapes and retained JAX JSON replays and links to the Generals
lobby flow on Softmax. Hosted lobbies own mode selection, human invitations,
bot seats, authentication, and match creation.

The player screen has keyboard and touch direction controls. Disconnection
clears queued moves; offline/online events resume the same seat, with six
bounded retries for other connection failures. Reconnecting cannot undo a
server timeout or elimination. The server remains authoritative for actions.

Browsers send `{"type":"subscribe","replay":true}` on their established socket.
Completed matches deliver the saved recording over that socket,
so replay playback and download survive retirement of the hosted HTTP proxy.
They show their outcome, replay download, and a new-match link.
Replay views include the full map and each player's fog-of-war perspective;
public scores remain visible in every perspective. Live public spectators
continue to see scores only. Old Nim recordings retain their original viewer.

Desktop native replays place the map beside names, skill scores and event chat.
Portrait phones stack a full-width board above the player table and chat, with
playback controls wrapped into three rows. Board sizing leaves clearance below
the turn counter and above the ribbon without clipping the map.

The game owns the renderer in `polyworld/` and its transport in `static/`. Softmax embeds them through its
existing live/replay components; do not copy the renderer into the website.

## Play against league leaders

Use `python -m integrations.softmax.play_leaders --elevated` to inspect the
current seven FFA leaders. Add `--create --coworld-id COWORLD_ID` to prepare a
verified eight-seat lobby with a human in seat 0. Use the exact published
Polyworld release ID. Team access is required for other owners’ policies.
See [the hosted runtime guide](POLYWORLD.md#human-lobbies-against-league-leaders) for release and proxy requirements.

## Play locally

From the repository root, with Python 3.12, Nim 2.2.10 and Emscripten 5.0.7:

```bash
python -m pip install -r integrations/softmax/requirements-polyworld.lock
integrations/softmax/tools/build_polyworld_runtime.sh "$PWD/polyworld/out"
export GENERALS_POLYWORLD_ENGINE="$PWD/polyworld/out/generals-polyworld"
export GENERALS_BASIC_WORKER="$PWD/polyworld/out/generals-basic"
integrations/softmax/tools/build_polyworld_viewer.sh "$PWD/polyworld/out/browser"
export GENERALS_POLYWORLD_VIEWER="$PWD/polyworld/out/browser"
python -m integrations.softmax.local --variant ffa --human --bundled-bots
# Other local modes:
python -m integrations.softmax.local --variant ffa --players 8 --human --bundled-bots
python -m integrations.softmax.local --variant castles --human --bundled-bots
```

Open the printed player link. Select an owned tile, then use arrow keys/WASD or
click neighboring cells to queue a route. Black arrows with white outlines show queued moves;
a white arrow marks the move already submitted for this turn. E undoes the last
queued action; Q clears all remaining actions. Neither cancels an action already
submitted. H toggles half-army moves for new inputs, and Space clears the tile
selection while keeping queued moves intact. The Pass
button queues a pass. Moves execute one per turn. If a move cannot execute
(including insufficient army), fails to secure its destination, or an obstacle
blocks the queued route, only that route is cancelled. Other queued routes
continue in order, starting on the same turn when possible. Selecting another
owned tile starts a separate route; use Space first when an adjacent click would
otherwise extend your current route. A failure clears the selection only if it
belongs to the failed route. The general is never selected automatically.
Mountains and fog obstacles cannot be queued into. A castle
hidden by a fog obstacle can be entered once revealed.
In castle-building mode, select an eligible owned plain tile and press B or
Build; the control shows its current army cost. Builds use the same action
queue as moves. Failed builds cancel their route; other routes continue.
The browser passes automatically if you do not act. Queues are local
to the browser and reset on disconnect or reload. The human
configuration advances at two turns per second. After the match, use the same
page to watch the full replay. Ctrl+C stops the local server.

For two bundled bots playing as fast as they can (the launcher defaults to classic 1v1):

```bash
python -m integrations.softmax.local --seed 7 --keep-open
```

`--max-turns 40` makes a short smoke test. Without it, local games use the hosted
caps: 50,002 engine ticks for FFA bots, 2,000 for other bots, and 1,200 with `--human --bundled-bots`. Each local run writes into its own ignored `local-output/episode-*`
directory. `config.json` contains local player tokens; do not publish it. The
shareable outputs are `results.json` and `game.replay` (`replay.json` with JAX). `--port` selects another
local port. The local launcher binds only to loopback.

## Rules and scoring

- Polyworld generates deterministic maps with reachable, separated generals
  and neutral cities. Four-player boards have 20–26 tiles per side;
  eight-player boards have 25–33. Classic 1v1 uses 18–23. Map layouts and
  seed interpretation differ from the retained Python/JAX generator.
- Fog of war: a player sees its owned tiles and their neighbors. Public army
  and land totals remain visible. Unexplored mountains/castles share one
  structure marker. Enemy generals are hidden until visible.
- A move sends all but one army, or half the source army (rounded down), into
  one orthogonally adjacent cell. Mountains cannot be entered. Friendly armies
  combine; attacking armies subtract from defenders. You must exceed the
  defending army to take a cell under normal combat.
- Moves resolve one at a time, each on the board the previous one left, in
  generals.io's order: moves onto your own land first, moves onto a general
  last, then larger armies before smaller ones; equal armies go in player order,
  reversed on odd turns. A move whose source another move is entering waits
  for that move, unless the two armies swap head-on.
- Generals and owned castles grow each even tick; owned land grows every 50
  ticks. Neutral castles start on the map with 40–50 defenders and can be captured.
- Classic 1v1 and FFA disable building and contain neutral castles. The building
  variant starts without neutral castles and accepts `[2,row,col,0,0]` on your
  own plain land. The army on that tile pays 35 plus, for each of your generals
  and castles, `max(0, 14 - 2 * Manhattan distance)`. Building beside your
  general initially costs 47. Enemy structures never affect the price. Builds
  resolve before moves and produce ordinary castles; an invalid build is a pass.
- In FFA, capturing a general eliminates that player, transfers their territory
  and half their armies to the captor, and turns the captured general into a
  castle. Classic 1v1 and FFA also allow mutual general trades: simultaneous
  captures swap generals and territory while both players survive. Building
  mode disables trades. The last surviving general wins. Eliminated players
  no longer owe actions; they can remain connected until the final result.
- General capture always requires beating its defending army, including after
  turn 800. There is no Deathtouch rule.
- Classic and building modes score **+1** for the winner and **−1** for the
  loser; their turn caps remain draws. FFA instead follows **FFA Survival**:
  the winner and players with a credited kill rank above kill-less players,
  then each group sorts by reverse elimination order. Results expose
  `placements`, direct `kills`, `captured_by`, and `elimination_order`.
  Scores are +1 for first and `-(place - 1) / (players - 1)` for other places.
  These encode the outcome for Softmax's ranker; they are not official stars.
- FFA ends after more than 2,000 consecutive ticks without a valid move, or
  the official 50,000-tick long-game threshold. The implementation completes
  tick 50,002 because the source tests `turn > 50000` before advancing it.
  Remaining players are eliminated in ascending army, then land, then seat
  order; the last remaining player wins. Explicit shorter caps and the paced
  human cap use the same adjudication rather than an all-zero draw.
- A normal official tick is 500 ms; two ticks make one full displayed game
  turn. Protocol `turn`, `turns`, and `max_turns` count these engine ticks.
  Bot simulation remains accelerated. Human lobbies retain their 1,200-tick
  budget and Softmax retains its independent hosted job deadline.

FFA has the official 1.5-second initial input window; subsequent bot actions
have a 500 ms deadline; human lobbies allow one second for transport
with a 500 ms minimum tick interval. Missing actions are passes. In FFA,
transport misses do not trigger the old 20-miss elimination. At tick 121, a
player needs 11 land, an owned city, or visible contact with an opponent to
avoid the official initial inactivity kick. Warnings begin at tick 99.

FFA players can send `{"type":"surrender"}`. Disconnecting
also surrenders the seat. Its moves stop immediately, but its land and general
remain owned, grow normally, and can be captured for 50 more ticks. At the
expiry, uncaptured territory becomes neutral with unchanged armies and the
general becomes a neutral city. The living opponent who destroyed the most
of that player's army receives kill credit, if anyone did. The winner receives
credit for the final surrender as in the official game. Classic/build modes
retain their immediate 20-miss timeout forfeits and reconnect behavior.

If a player never connects before the 180-second start deadline, the episode
emits a typed player failure rather than competitive scores. The FFA league
uses OpenSkill Plackett-Luce, starting at mu 50 and sigma 50/3. Published ratings
use the conservative estimate mu minus three sigma. Historical rounds remain;
new games establish the migrated rating estimates. Classic and Build retain Elo.
The [official attribution](https://generals.io/copyright) identifies OpenSkill
for stars and matchmaking. Its exact updater and parameters remain unavailable,
so matching the rating family does not establish exact star parity.

Competitive episodes omit `seed`, generating a fresh server-private 32-bit seed.
Explicit seeds are for reproducible local tests/evaluations. The seed is recorded
only in the completed replay. Do not pin a league to a known fixed seed: a bot
could reconstruct the hidden map.

## Player protocol

See [PLAYER_PROTOCOL.md](PLAYER_PROTOCOL.md) for the exact JSON contract and
the existing [competition protocol](../../competition/protocol.py) for stdio bots.
The bundled container players are Expander and Builder; neither needs JAX.
Expander is the pure-Python bot in `competition/agents/expander_python`; Builder
adds an opening castle before expanding. BASIC Frontier runs inside the game
image. These are integration baselines; local results do not measure league strength.

To bridge another bot, run in its player container:

```bash
python -m integrations.softmax.player -- /path/to/compiled-bot
```

The runner supplies `COWORLD_PLAYER_WS_URL`. Python scripts can be passed as
`-- python -u /path/to/main.py`. Build C++/Rust executables into the player image
ahead of time. The bridge owns only its child process; the game owns scoring.

## Spectators and replays

`/client/global` shows live public scores and match status. **It deliberately
does not show the live board.** Player containers can reach the game server, so
an unauthenticated omniscient WebSocket would defeat fog of war. Player pages
and `/player` require the slot's token. The public stream accepts no game-control
commands, and `/replay.json` is unavailable until all success artifacts are saved.

Polyworld replays use upstream's binary container and packed Generals moves,
with a versioned hosted-rule extension for construction and surrenders. Portable
64-bit tick hashes let the native WebAssembly viewer reject divergent playback.
It supports autoplay, looping, pause, seek, speed, perspectives, resize, download
and gzip. See [the binary protocol](GLOBAL_PROTOCOL.md) for format ownership.

The static bundle needs no game server or JAX installation.
Browser seats preload it before joining; completion delivers the tape over the
existing socket, so playback survives retirement of the live HTTP proxy.
Historical releases keep their own immutable viewer bundle.

`COWORLD_REPLAY_PLAYER_RATINGS=true` in the game manifest requests public
leaderboard metadata when the platform opens a saved replay. The platform matches
job seats through policy versions and player IDs, then passes current published
MMR/Elo values in the viewer URL fragment. The viewer preserves decimal and
negative scores and shows — for unrated or unavailable seats. No bot observation
or recording simulation changes. Historical viewers remain pinned to their releases.

For a standalone replay, serve the generated bundle and a replay over HTTP:

```bash
# After coworld build, extract the viewer from its game image:
integrations/softmax/tools/build_replay_viewer.sh integrations/softmax/dist/replay-viewer
# Copy only a completed replay into dist/replay-viewer/game.replay, then:
python -m http.server 8090 --directory integrations/softmax/dist/replay-viewer
# Open http://localhost:8090/#replay=game.replay
```

See [GLOBAL_PROTOCOL.md](GLOBAL_PROTOCOL.md). Full live board spectating would
require a separate trusted-viewer authorization contract with Softmax; it must
not be enabled by copying the example's public omniscient stream.

## Build and certify

The project lives in this directory so the training package does not depend on
the Coworld SDK. It needs Docker with Compose/Buildx and Docker daemon access.
Keep the SDK separate from the game dependencies. The
[release workflow](../../.github/workflows/coworld-release.yml) pins
`coworld[auth]==0.1.68`, which supports the manifest's runtime list.
Use that pin for local build/certification commands:

```bash
uv tool install 'coworld[auth]==0.1.68'
```

The build reads `compose.yaml` and `coworld_manifest_template.json` from this
project directory. The shared runtime build compiles the pinned Bassy/Fixxy BASIC worker
into the CPU game image. The player image contains WebSockets and the Python
Expander/Builder bridge; it has no JAX dependency. The optional `hunter` image
target is separate from the bundled players.

From the repository root, replace `MAJOR.MINOR.PATCH` with the intended release version:

```bash
python -m integrations.softmax.tools.manifest --check
coworld build --project integrations/softmax --version MAJOR.MINOR.PATCH
coworld certify integrations/softmax/dist/coworld_manifest.json
```

`compose.yaml` builds separate CPU game and lightweight player images.
Deployment defaults to `linux/amd64`. On Apple Silicon, certify native containers:

```bash
GENERALS_ARCH=arm64 coworld build --project integrations/softmax --version MAJOR.MINOR.PATCH
coworld certify integrations/softmax/dist/coworld_manifest.json --no-open-report
```

Then rebuild without `GENERALS_ARCH` for the hosted amd64 release. Image tags
include the architecture, so native validation does not replace the deployable
image. JAX's amd64 wheel requires AVX, which local amd64 emulation may not expose. The
manifest template embeds the protocol/rules docs and derives its config schema
from the runtime model. If those sources change, regenerate it with
`python -m integrations.softmax.tools.manifest`. The build hook recreates the
static replay directory and Coworld resolves images to immutable identifiers.

The normal hosted release path is an explicit dispatch from committed `main`:

```bash
gh workflow run coworld-release.yml --ref main -f version=MAJOR.MINOR.PATCH
```

The workflow builds native amd64 images with the pinned SDK, certifies the
mixed-player fixture plus classic, all six FFA sizes, and building fixtures,
then uploads and waits for hosted certification. It uses the repository's
`SOFTMAX_TOKEN` secret and retains the resolved manifest as a workflow artifact.
A source push runs tests; it does not publish a new Coworld version.
See [release records](VARIANTS.md#releases) for the last recorded hosted inputs.

For an explicitly managed manual release, commit and push the release inputs,
inspect a full-length match and static replay, and verify account/game ownership
before uploading the certified amd64 manifest:

```bash
coworld upload-coworld integrations/softmax/dist/coworld_manifest.json
```

Hosted verification must exercise real episodes, result scores, player shutdown,
logs, and the hosted replay. A local pass is not evidence of hosted operation.
League setup uses Softmax's platform scheduler; no custom commissioner,
reporter, grader, or optimizer is required for this release.

## Maintenance and tests

Install test dependencies into the Python 3.12 environment used for local play:

```bash
python -m pip install -e '.[dev]' playwright
python -m playwright install chromium
python -m integrations.softmax.tools.manifest --check
JAX_PLATFORMS=cpu SDL_VIDEODRIVER=dummy GENERALS_BROWSER_TESTS=1 python -m pytest -q
```

For a focused adapter pass, use CPU JAX with:

```bash
JAX_PLATFORMS=cpu python -m pytest -q tests/test_softmax.py tests/test_matchup.py tests/system/
```

The existing real-browser harness covers controls, live-to-replay handoff,
perspectives, and desktop/mobile layout.

The integration tests cover real engine observation/wire parity, action
validation, authentication, information boundaries, deterministic replay,
timeouts, startup failures, regular general-capture scoring, neutral castles,
rejected build actions, and failed artifact writes.
Before releases, run the complete engine suite, local container certification,
and browser checks for live player controls and the static replay bundle.

To run the real Chromium checks (including mobile layout, gzip, corrupt replays,
and WebSocket pong), install `playwright` and Chromium, then run:

```bash
GENERALS_BROWSER_TESTS=1 python -m pytest -q \
  tests/test_softmax_browser.py tests/test_softmax_variants_browser.py \
  tests/system/test_live_replay_system.py
```

Set `CHROMIUM_PATH` if Chromium is not on PATH, or use Playwright's installed
browser. [`tests/system/test_mixed_players.py`](../../tests/system/test_mixed_players.py)
requires a compiled worker at `GENERALS_BASIC_WORKER`; it skips without one.
The private-reference check also skips unless `GENERALS_REFERENCE_ENGINE`
points to external reference files. Those skips do not certify BASIC execution
or official-engine parity. See [BASIC verification](BASIC_PROTOCOL.md#local-verification)
and [reference validation](../../paper/validation/README.md#privately-supplied-replay-core).

Deployment dependencies, including transitive packages, are pinned in
`requirements.lock`; regenerate it with `uv pip compile requirements.txt
--python-version 3.12 --output-file requirements.lock` from this directory when
deliberately updating the runtime.

The adapter uses the Polyworld engine. The retained JAX runtime and local
competition runner use `generals.core.match`. Publish a new Coworld version for rules,
protocol, rendering, or dependency changes. Preserve old replay fixtures when
the format changes. Keep participant support and league balancing distinct from
technical adapter maintenance. Hosting/resource allowances and ongoing support
ownership need agreement with Softmax.

## Visual sources

The published replay viewer uses `polyworld/src/generals/views.nim` and its
Silky theme, transport, fonts and sprites. The Docker build includes their
licenses. The `softmaxReplay` build flag loads hosted action tapes and reports
verified playback progress. See [POLYWORLD.md](POLYWORLD.md) for ownership and
source browser commands.

Live human controls and the retained JAX replay viewer use the renderer below.

`static/board.js` reuses the tile-rendering function from
`generals-competition/board.js` at commit `83a9b23`. `static/board.css` retains
that renderer's tile layout and uses the default [generals.io](https://generals.io)
player and terrain colors, including unchanged owner colors on castles and generals.
The palette was checked against `generals-main-prod-v31.4.6-df40179d.css`
on November 2, 2026. The Coworld snapshot-to-tile mapping and selected-cell
indicator remain adapter-specific.
The surrounding layout follows its `assets/site.css` replay viewer. There is no
procedural game fallback or second game simulation in this renderer.

Keep board and scorecard colors aligned with the official game when updating them.
Sprites stay owned by `generals/assets/images`, and the Quicksand font comes
from `generals/assets/fonts`, including its license in the retained JAX replay bundle. No
copied source assets need to be synchronized manually.
