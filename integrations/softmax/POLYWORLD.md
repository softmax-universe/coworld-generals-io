# Polyworld hosted runtime

The `polyworld/` tree imports all tracked files from
[Metta-AI/polyworld-generals](https://github.com/Metta-AI/polyworld-generals)
from its floating `main` branch. Its MIT license,
asset notices, native Silky application, experiments and original checks remain
beside the code. `polyworld/dependencies.lock` pins native application dependencies.
Private official reference sources are not part of this import.

Run `python -m integrations.softmax.tools.sync_polyworld` before preparing an
upstream update. It fetches the current `main`, imports its changes and preserves
our simulation receipts and trade switch. Overlapping edits fail before applying;
resolve those edits before building. Commit and validate the resulting source.
`polyworld-upstream.txt` records the last imported revision for incremental sync
and release provenance; it does not constrain the next upstream revision.
Release builds use the reviewed repository tree, so their source URL identifies
the exact code tested. The standalone package under `polyworld/` currently
accepts file players; our hosted adapter continues to support mixed seats.

## Ownership and execution

`polyworld/src/generals` owns the Nim simulation. The imported `step` now returns
executed-move receipts, capture order and damage, and accepts a general-trade
switch. Native callers retain their existing behavior.

`polyworld_bridge.nim` runs this engine in a persistent subprocess. It applies
hosted castle construction before ordinary moves and pays terminal-tick income.
`polyworld_engine.py` owns Coworld observations, FFA Survival placement,
surrender windows, inactivity and long-game adjudication. Neither bridge receives
connection tokens, policy source or private player logs.

`server.py` owns authentication, deadlines, mixed seats, result persistence and
browser sessions for both engines. `file_players.py` retains the isolated,
budgeted BASIC workers. Container players keep the existing JSON/WebSocket and
stdio contracts; existing BASIC policies keep the published BASIC contract.
Both standalone and hosted BASIC import `generals/policy_api.nim`, including
`policyLimits()`, flat tile queries, names, skills, movement and mailbox functions.
`policy_source.nim` binds existing uploaded row/column spellings to that same
host without modifying their source files. The unchanged upstream Scout plays
hosted socket opponents. No separate hosted VM API is maintained.

`messages.py` owns an episode-scoped broker process (`generals-basic --messages`)
that runs the actual upstream `MessageHub`. BASIC, container and human seats
share deferred delivery, normalization, inbox bounds and public game notices.
Only each seat's inbox enters its worker/socket. Public chat enters the existing
binary `ReplayMessages` section; private mail never enters recordings or
spectator updates. The broker closes with the episode. Hosted BASIC keeps its
additional process sandbox, while containers keep platform-owned resources.

The hosted game uses Polyworld's deterministic map generator. Hosted seeds retain
all 64 unsigned bits, from 0 through 18446744073709551615. The private
process boundary sends seeds as decimal text to preserve their exact value.
Map generator version 3 uses SplitMix64 with identical native and WebAssembly
arithmetic. Map dimensions,
layouts and seeds differ from the former JAX generator. This release does not
claim official map parity. Human seats and completed matches use the actual Polyworld Silky renderer
compiled to WebAssembly. The browser transport owns authentication, deadlines
and the action queue. It sends that active seat’s fog-filtered observation, public army/land totals,
roster and skill snapshot to the renderer. After elimination, the server
sends the full board and the client disables movement and chat. The live renderer
never runs a second simulation or offers replay point-of-view controls.
The native desktop application remains available under `polyworld/`.
Hosted variants still support two through eight seats, the same sixteen variant
IDs, all three leagues, both player artifact kinds and human seats.

## Build and run

The Coworld Compose game service targets Docker's `polyworld-game` stage.
The native hosted binary uses the same pinned Polyworld tape and Flatty libraries as the viewer. The replay build
fetches the public native dependencies and uses Emscripten 5.0.7. The image
contains the compiled viewer and licenses; source dependency trees stay in its
build stage. `replay-dependencies.lock` supplies two transitive viewer libraries
omitted from the imported dependency list.
Both local server engines need `generals-basic` for the shared MessageHub broker,
even when every seat is a container or human. The game image contains no JAX runtime. The former Docker `game` target and
Python engine remain independently buildable.

```sh
integrations/softmax/tools/build_polyworld_runtime.sh /tmp/generals-runtime
export GENERALS_POLYWORLD_ENGINE=/tmp/generals-runtime/generals-polyworld
export GENERALS_BASIC_WORKER=/tmp/generals-runtime/generals-basic
python -m integrations.softmax.local --variant ffa --max-turns 40
# Explicitly run the retained engine:
python -m integrations.softmax.local --engine jax --variant ffa --max-turns 40

python -m integrations.softmax.tools.manifest
coworld build --project integrations/softmax --version VERSION
coworld certify integrations/softmax/dist/coworld_manifest.json
coworld upload-coworld integrations/softmax/dist/coworld_manifest.json --wait-certification
```

`GENERALS_ENGINE=polyworld` selects this backend. New recordings use upstream's
`POLYWORLDREPLAY` binary container and Generals' four-byte packed move words,
with eight-byte state hashes per tick. Passes are implicit; rare invalid moves
and castle construction use the upstream extended-word escape.

Hosted rules additionally need typed, ordered surrender/neutralization markers,
the castle preset, public roster/skill metadata and the final outcome. Their
versioned game identifier is `generals_hosted`, version 2, inside the shared
Polyworld file format version 2. This avoids assigning new meaning to upstream's
`generals` version 5. Both store the full unsigned 64-bit seed and use map
generator version 3. Earlier versions remain with their archived game builds.
The hosted viewer and process use identical `polyworld_hosted.nim` transitions.
The new reader accepts binary tapes; published JSON tapes retain their original
immutable viewer bundles. No stored replay or published bundle is rewritten.

`generals-polyworld --inspect-replay FILE` verifies every tick and prints public
metadata plus the final fingerprint. `--encode-replay` converts a command log
from stdin into binary stdout; it is the game's serialization boundary, not an
extra persisted JSON artifact. Results and diagnostic HTTP frames remain JSON.

The browser preloads the native replay bundle before joining browser seats.
Human play starts the same bundle through `live.html`, with a typed display
snapshot and origin/source-checked input messages. Both entry points share
`generals.js`, WebAssembly, assets, board rendering, scoreboard and chat.
Live mouse and keyboard input returns to the existing transport’s single queue.
After reconnect, the next authoritative observation restores the display;
queued orders are cleared. The server alone advances turns.
After completion, it sends the saved tape over the established socket. The
preloaded viewer receives it through a parent/origin-checked message, so replay
controls and download keep working after the hosted HTTP proxy retires.
`/client/replay.data` returns the saved tape; `/replay.json` exposes completed
diagnostic frames. Neither endpoint reveals replay state during play.

For source browser checks, first build a local viewer:

```sh
integrations/softmax/tools/build_polyworld_viewer.sh "$PWD/polyworld/out/replay-viewer"
GENERALS_POLYWORLD_ENGINE=/tmp/generals-runtime/generals-polyworld \
GENERALS_BASIC_WORKER=/tmp/generals-runtime/generals-basic \
GENERALS_POLYWORLD_VIEWER="$PWD/polyworld/out/replay-viewer" \
GENERALS_BROWSER_TESTS=1 pytest tests/system/test_polyworld_system.py
```

For the imported native application's commands, run from `polyworld/` and follow
its [README](../../polyworld/README.md). Use the pinned dependency fetcher before
running the complete Nim suite. The shared runtime build fetches its pinned dependencies automatically.

Live skill metadata comes from the platform’s published public standings through
`COWORLD_PLAYER_RATINGS=true`. The runtime receives a typed `player_ratings`
configuration value, then sends it to player handshakes, observations, and spectators.
The value is fixed for the match. Native offline replays retain that snapshot;
platform replay pages may overlay the current standings. Neither affects engine
state, action resolution, hashes, or episode scores.

## Human lobbies against league leaders

Use the current FFA leaderboard and champion memberships, rather than the local
Expander fixture:

```sh
# Read and print the exact seven opponents without creating a session:
python -m integrations.softmax.play_leaders --elevated
# After publishing/certifying this tree, use that exact release ID:
python -m integrations.softmax.play_leaders --elevated --create --coworld-id COWORLD_ID
```

`--elevated` requires authorized team access. The launcher creates a casual
`ffa-8-human` lobby, keeps seat 0 human, assigns seats 1–7 to the top seven
players’ current champion policy versions, and reads every assignment back.
It never substitutes bundled bots or skips an inaccessible leader. Creation
stops on a failed request or roster mismatch. The printed lobby is ready for
joining and starting; the launcher does not auto-start it or affect league ranks.

`local --human` requires explicit `--bundled-bots` unless every opponent has an
explicit BASIC file. Those seats display `Bundled Expander` names. Local smoke
results do not establish strength against league participants.

Hosted live play also requires the platform proxy to serve `.html`, `.wasm`
and `.data` assets. The related platform fix is
[Softmax PR 31216](https://app.graphite.dev/github/pr/softmax-universe/softmax/31216).
Pushing this repository does not deploy either the game or that platform fix.
