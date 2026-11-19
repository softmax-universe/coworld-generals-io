# Organization-owned Generals

This document preserves source provenance and release-specific evidence.
Use [the adapter guide](README.md) for the current implementation and commands,
and [VARIANTS.md](VARIANTS.md) for mode IDs, leagues, and published releases.
Versioned validation sections below describe the release tested at that time.

## Paired platform rollout and FFA recovery

Live skill snapshots require the platform changes in
[Metta PR 30441](https://app.graphite.dev/github/pr/Metta-AI/metta/30441).
That rollout also fixes mixed-roster file faults losing seat attribution in the Kubernetes coordinator.
A BASIC work-budget failure remains a policy fault; do not raise its budget to recover scheduling.

After both PRs merge:

1. Deploy the matching platform backend/coordinator bundle and verify the running coordinator digest.
2. Refresh Polyworld from its floating `main` with the documented sync command; record the resolved revision.
   Build and certify the resulting source before publishing. Do not dispatch another release while one is running.
3. Rebuild and upload a new version through `coworld-release.yml`, await hosted certification, and verify the canonical
   `generals-competition` version. Source commits and older successful uploads do not establish this release's state.
4. Read the current FFA pause and latest round before resuming only
   `league_f189ad01-2700-4fc8-ba89-f9de477099e4` through the platform's `rounds-paused` API.
   Keep the league's OpenSkill settings, thirty-minute cadence, and retry limits.
5. Verify a fresh FFA round starts and completes using the intended version. Inspect its planned episodes,
   any policy-failure attribution, and published skill standings. Record the release and round IDs in VARIANTS.md.

The November 3 outage exhausted three attempts on version 0.6.5. Production debug artifacts showed
`BASIC work limit exceeded` in a file seat, followed by an unattributed coordinator `StopIteration` during a pod lookup.
A certified upload does not clear that durable league pause. Do not report recovery until a new round completes.

## Provenance

The repository was renamed from `Metta-AI/cogame-gen-generals-io` to
`Metta-AI/coworld-generals-io` on October 15, 2026. Its implementation is imported
from `strakam/generals-bots` branch `softmax`, commit
`0fcb5a00226387670624d2f326f6d5ad61914584`. Both Git histories and the upstream
MIT attribution are retained. The import's first parent preserves the Nim tree.

The old `gen-generals-io` 0.1.1 release points to
`8fe03eabe41c2eacd666029b0bef1377faf937ce`. Its image and replay viewer remain
pinned; the new Python game does not interpret its `COWLDGEN` binary replays
or accept its prompt-plan players. No old episodes or leagues are migrated.

At import, the active game `generals-competition` had been published as 0.3.3 from
`strakam/generals-bots` commit `f65fb55d90a1a3397ca89a9591b296b899cca127`.
The import retained that game name and the original six variant IDs.
Later releases added ten FFA seat-count variants; the manifest now has sixteen.
The current BASIC worker is Nim code, distinct from the archived Nim game.
See [the mode table](VARIANTS.md#modes).

## Official-engine alignment

The privately supplied engine is not included or licensed by this repository.
The original live-game bundle still lacks GameOptions, BadWords.js,
good-words.json, and dependency/bootstrap files. A separately supplied replay
core now includes Map and an updated MoveResolver, with its own smaller
Constants module. Keep the original live-game Constants separate.

The [private reference adapter](../../paper/validation/README.md#privately-supplied-replay-core)
can export base-game boards without the missing EventGameOptions or
EventReplaySimulation wrappers. This unblocks board comparison, not full live
engine, fog, event-statistics, or castle-building certification. Keep reference
source outside the checkout and all distributed artifacts. Record source hashes
and comparison results before claiming parity.

Use identical initial boards and action streams to compare complete games,
including FFA captures, simultaneous general trades, rounding, move dependencies,
growth, fog observations, surrender, and replay outcomes. Compare map generation
separately; identical numeric seeds across different generators are not equivalent.
Upstream replay-validation claims are historical evidence, not certification of
this release against the supplied engine revision.

## External-server bridge

`generals/remote` already connects a bot to a generals.io lobby. The deployment
bridge still needs the official lobby handoff/authentication agreement, bot/seat
identifiers, reconnect and cancellation behavior, and completion/replay callbacks.
Do not use the existing indefinite auto-force-start loop for human tournaments.
Diplomacy offer/accept events await the official update; agreements do not
restrict subsequent attacks or require either player to honor them.

## Release validation

Run the imported version before changing rules. Validate complete local FFA,
human play, standalone replay, container certification, and hosted operation.
Record release-specific commands and outcomes here before publishing.

### Ordered chat source validation — November 18, 2026

- Source branch `replay/ordered-chat` starts from
  `8b40ddce89de837ac806026ed3a1bfb1fc0270f7`. Standalone replay game version 6
  and hosted game version 3 store public chat inline with moves. The tape
  format is version 5; older readers remain with their published releases.
- Dependency locks are unchanged. The complete native suite, hosted bridge
  check and graphical check passed with all 29 exact locked revisions,
  including Polyworld `552e7cd9f013de898e3cae3768260f4e6b3eca2b` and
  Silky `3c5dd562924c044bfd4417331f82132fa0a0afdb`, using Nim 2.4.0 on macOS ARM64.
- Seven real hosted system checks passed. The chat case sends actual player
  socket traffic through the mailbox broker and binary codec, verifies ordered
  move/chat/chat entries across three ticks, preserves identical messages, and
  excludes private inbox text from public artifacts. The existing 16,384-message
  recording budget and private-mail exclusion remain unchanged.
- Three Chromium WASM cases passed for FFA8, FFA4 and castle building, including
  desktop/mobile seeking and divergence rejection. A separate real chat tape
  restored exactly six repeated messages through two end/start/end cycles,
  with no duplicate or private text and no browser errors.
- Local container build used Coworld SDK `0.1.68`, Nim `2.2.10`, Emscripten
  `5.0.7`, ARM64, and validation-only version `0.0.0`. The generated manifest
  and all eight release-workflow mode fixtures passed certification: 90/90
  steps across the default mixed fixture, Classic, FFA3 through FFA8, and Build.
  The mode fixtures use seed 7, 40 ticks, a 0.05-second interval, and one BASIC
  player against Expander or Builder. No images or hosted release were uploaded.
- Game image: `sha256:f42fd0f77a8959b6930fb7ae69dfe773059d1e3bad0062274ff47a6f7dc8501f`.
  Player image: `sha256:7e99b2c9d25338aee2bccc62a19648ca6e737411c3754057ecd50d84c0ded5e6`.
  Runtime patch SHA-256 against the source base:
  `c4ef72db16e9613bf815c00006eb3e14010f667e63a35982f05885e1c70fc72c`.
  This hashes `git diff --binary` for `messages.py`, `polyworld_bridge.nim`,
  `polyworld_engine.py`, `server.py`, `generals/replays.nim` and
  `generals/views.nim`, in that order, under their existing source directories.

### 0.7.1 preparation — November 3, 2026 (UTC)

- Runtime source `cad29c1a671f50ec5b4ced146efdff8e71579c32` hides the final
  result until the last replay tick and hides it again after seeking backward.
  Player names use 240 rather than 184 logical pixels; score/event typography
  is larger and board grid lines use two pixels.
- The Skill column preserves decimal and negative published MMR/Elo values.
  The manifest opts into public platform metadata with
  `COWORLD_REPLAY_PLAYER_RATINGS=true`. The companion
  [platform PR](https://app.graphite.dev/github/pr/Metta-AI/metta/30441) matches
  exact seat identities and excludes private standings. Ratings are current
  public standings, not historical pre-match snapshots; unavailable seats show —.
- Validation passed 42 core cases, four native system cases, the native live
  replay handoff, two browser cases using the image-built viewer, the full
  imported Nim suite, and 40 ARM64 certification checks across four fixtures.
  The early-result mutant fails the browser check; restored source passes.
- Real API, Postgres and Floci checks cover duplicate display names, reversed
  standings, unavailable scores, private boards, best-row-per-player behavior
  and a ranked Classic/Elo board overriding the default FFA/OpenSkill board.
  Native browser proof covers 1440×1000 and 390×844 viewports.
- Build: `GENERALS_ARCH=arm64 coworld build --project integrations/softmax
  --version 0.7.1`. Certify the generated manifest and Classic, FFA8 and Build
  fixtures with `coworld certify MANIFEST --no-open-report --timeout-seconds 180`.
  Native AMD64 and hosted qualification use the existing release workflow:
  `gh workflow run coworld-release.yml --ref main -f version=0.7.1`.
  Historical episodes retain their pinned viewer bundles.

### 0.7.0 — November 3, 2026 (UTC)

- Imported all 173 tracked files from Polyworld `main` at
  `500a98d66777f53e6dd1ca1f2127ebb826018f4a`. The sync command follows `main`;
  the recorded revision identifies the imported source rather than constraining updates.
- The published runtime uses the Nim engine and actual Silky WebAssembly replay
  viewer. Hosted command tapes verify a state hash after every command, including
  construction, surrender, neutralization and terminal adjudication.
- Current checks: 52 affected core/server/legacy-browser cases; five native replay
  cases; five FFA/legacy-handoff cases; three Linux mixed-player cases; and two
  browser cases using the image-built viewer passed. The full imported Nim suite
  passes with the updated dependency lock. Mac source checks skip six Linux-only
  BASIC cases; the Linux image checks cover the three Polyworld cases.
- The native browser checks use real completed FFA8 and Build episodes, gzip,
  desktop/mobile viewports, seeking, changed-hash rejection and replay download.
  The surrender fixture captures within its 50-tick window, then verifies later
  neutralization and Survival placement in both the game and native viewer.
  A live human/container episode remains replayable after its HTTP proxy retires.
- ARM64 container certification passed 40/40 steps across Classic, mixed FFA4,
  FFA8 and Build. The qualification image config digest is
  `sha256:bd0324df81aab48e9164b908152fdb3287a847cf2913737cc89728b3dd7e2749`.
  The release workflow subsequently passed all 90 native AMD64 checks and
  all ten hosted certification checks; see [the release record](VARIANTS.md#070--november-3-2026-utc).
- The isolated full local platform built its coordinator/certifier and passed
  API/certifier health checks. AMD64 emulation fails Rosetta allocation under the
  BASIC worker's existing address-space sandbox; that limit remains unchanged.
  Native release-runner certification is the AMD64 qualification path.

See [PR 21](https://app.graphite.dev/github/pr/Metta-AI/coworld-generals-io/21)
for exact commands, current CI and native viewer review media.

### 0.4.0 preparation — October 15, 2026

- Imported FFA baseline: `python -m integrations.softmax.local --variant ffa
  --seed 7 --port 18380`; 2,000 turns, four zero timeout counts.
- Final FFA with the same command/seed: 2,000 turns, identical result and zero
  timeouts. The generated replay contains all four seats.
- `GENERALS_BROWSER_TESTS=1 python -m pytest -q`: 217 passed in 174.47 seconds.
  Existing browser coverage starts a real game, clicks a player move, waits for
  completion, and checks standalone desktop/mobile replay, gzip, and seeking.
- New complete-game regression walks two players across a generated map, exchanges
  generals, verifies both move receipts and survival, and validates saved results
  and replay. Disabling the trade rule fails this regression; restored behavior passes.
- The imported focused suite initially had 52 passing and two failing tests.
  Both failures were cancelled WebSocket cleanup. Shielding the owned-task join
  fixes them; the full suite above includes both checks.
- `python -m integrations.softmax.tools.manifest --check` and Python compilation pass.
- An amd64 image builds, but local emulation fails JAX's AVX guard. Use native
  arm64 certification on Apple Silicon, then rebuild amd64 for hosted validation.
- Full local platform startup was delayed by Nix downloads and disk exhaustion;
  no shared stack was stopped. Real game/browser checks above are independent of it.

The 0.4.0 rule change enables mutual general trades only for classic modes.
Castle-building retains its previous rules. The transition and action receipts
share the same resolver. Historical JSON replay frames still render directly;
resimulation must use each episode's pinned source revision.

Native arm64 container certification passed all ten checks for classic, FFA,
and castle-building. Container testing also exposed host-umask-dependent source
permissions; both image stages now make application sources readable before
starting unprivileged players.

The existing `Coworld release` workflow is retained with a new Python-game build
path and SDK 0.1.60. Dispatch it with the release version to build native amd64,
certify all modes, and publish using the repository's existing `SOFTMAX_TOKEN`.
It never skips certification or cancels an in-progress release. Local upload on
Apple Silicon cannot certify the amd64 JAX wheel because emulation lacks AVX.

### Hosted completion handoff — October 29, 2026

The live HTTP proxy can retire after results are saved. Browser clients now
request `replay=1` and receive the completed recording on their existing socket.
Both player and spectator views enter replay mode without another HTTP request.
Bot connections retain result-only terminal messages. Shutdown waits for owned
socket senders to finish instead of relying on a fixed delay. Hidden frames remain
unavailable until both replay and result artifacts are saved.

Validation for the next release, using Coworld SDK 0.1.60:

- `GENERALS_BROWSER_TESTS=1 python -m pytest -q`: 220 passed, one private-reference
  check skipped. This includes real player controls, reconnect, and static replay.
- The new system workflow returns HTTP 410 immediately after completion. Human
  play and spectating still reach replay, then seek and retain their download
  after server shutdown. The original implementation fails this workflow;
  restoring the change passes it.
- `python -m integrations.softmax.tools.manifest --check` and JavaScript syntax
  validation pass.
- Native arm64 build for version 0.4.2 and all ten container certification steps
  pass separately for classic, FFA, and castle-building.
- Certified game image:
  `sha256:54ecdc06342e19fb3609fb642dad0bd5ea9f32c304adeb35b175d864b1fc2357`.
  Certified player image:
  `sha256:8b1679a7981f945f1fa0fd97d432011c6bd2de4a6b4c103abb4493f3611265b8`.

Validation includes the full-height replay layout merged from main at `84a2005`.

These are local validation results. Publishing a canonical amd64 release still
uses the existing release workflow. Late navigation to an expired live URL is
owned by the platform proxy, which must resolve the episode's recorded replay.

### Ranked FFA map alignment — 0.5.0 preparation

FFA now accepts three through eight players. The new startup sampler follows
base-game ranked map generation, including squared-uniform dimensions,
player-count-dependent spacing and city budgets, mountain draws with replacement,
fair city placement, and rejection of blocked or city-starved spawns.
Four-player maps have 20–26 tiles per side; eight-player maps have 25–33.

The reference was the developer-supplied `GeneralsIOProbablyAllYouNeedInitially.zip`
(Constants version 31.4.4), with the separately supplied base Map. The supplied
JavaScript files remain external to this repository and distributed artifacts.
A local loader exercised the real `Game.tryInitializeGame`, `Terrain`, Map,
shuffle, and city-placement methods. Unavailable chat/options imports were
bypassed; options were supplied directly. This validates base FFA map sampling,
not the unavailable live server or its authentication and event wrappers.

With identical random-draw streams, all 600 generated boards matched tile for
tile, including the draw count: 100 seeds for each of 3, 4, 5, 6, 7, and 8 seats.
The comparison includes city-placement fallback and rejected-map retries.
[Comparison report](https://softmax.nexus/artifacts/9d7631a8-adef-42a9-b0ae-f82edcecd81b).

Reference SHA-256 identities:

| Input | SHA-256 |
| --- | --- |
| Original archive | `58de1a86022a97fc79a9905da0c27996fb86d104b7e34fd1cbf1994ce781e8f5` |
| Game.js | `3f93ed25346cec357414c8a3ab894938437c13bff747539f4c015e7945290c41` |
| Terrain.js | `a73ba43eb3e14b88b3bf9e285625bf9099fde67aaab3675bd3cbefced7ca803e` |
| Utils.js | `c8aba8420162a5df73035abe47b37d6f6c5eb0d2dba2560501adf64cc4d6711b` |
| Original Constants.js | `ce4d795ce1fd5c860a05276daa8987f21059795a8c135237bdde794f6cbe5c30` |
| Separate Map.js | `08a06a43751020f1c68aa84b0c3c39940c90871f9451a0508a340af554b11276` |
| Separate Constants.js | `ee1df1683c38f941ff6548e3fb29313405dd151c28f871f4e029f6ef75e8fc14` |
| Comparison report | `f9e9b1946ff39a5c9e9f57f5376feeff06f1ba4d4f8e02f58efff8c13933d451` |

The real eight-bot workflow exposed compilation exceeding the launcher's
60-second readiness window. Keeping move ordering and general-trade resolution
as compiled loops, rather than unrolling player pairs, reduced a fresh eight-seat
Match startup to 8.23 seconds on the validation host. The same workflow then
completed and rendered all eight players, colors, fog perspectives, and seeking
on desktop and mobile.

The bot turn cap, winner-only scoring, action deadlines, and timeout-neutralization
policy remain Softmax hosting choices. Map alignment does not establish parity
for those policies or the public ladder's rating system.

### 0.5.0 hosted completion — October 30, 2026 (UTC)

Released source `00f6cf90f47ff388c245b36ea782a96585d985b2` using the existing
`coworld-release.yml` workflow with `version=0.5.0`. All eight native AMD64
certification fixtures passed; hosted certification passed its ten checks.
The version, image identities, verification request, and public replay are
recorded in [VARIANTS.md](VARIANTS.md#050--october-30-2026-utc).

Validation used Python 3.12, the locked runtime dependencies, and Chromium:

- `GENERALS_BROWSER_TESTS=1 pytest -q` in source CI: 221 passed, one private
  reference check skipped. Both the implementation and release-source runs passed.
- The same complete suite passed all 222 checks locally, running modules in
  separate processes with `GENERALS_BROWSER_TESTS=1`,
  `GENERALS_REFERENCE_ENGINE` pointing outside the checkout, and CPU JAX.
- Manifest consistency, scoped Ruff, both browser JavaScript syntax checks,
  and `git diff --check` passed.
- The ordinary hosted `ffa-8` variant completed 2,000 turns on a 26×25 board
  with eight real policy containers and zero timeouts. Its saved recording
  contains 2,001 frames and all eight seats. This validates runtime operation,
  not baseline playing strength or match balance.
- The public default league, persistent seed name, canonical version, scheduler,
  and all three leagues' resolved game versions were read back after rollout.
  The scheduler replacement preserved every other stored setting and used the
  snapshot revision in `If-Match` for validation and persistence.

The public episode route opens hosted replay without signing in. The theater's
league-filtered `?e=` route does not select an out-of-league verification request;
use the episode's public page or its Replay link for these runs.

### Further ranked FFA alignment — 0.6.0

The supplied live Game defines the primary `ffa` ladder as FFA Survival.
The [official version history](https://generals.io/versions) documents its
kill/win partition. This release records elimination sequence, credited killers,
and enemy army destroyed inside the authoritative transition. FFA outcomes now
follow that partition and reverse elimination order. Scores preserve the ordering
for Softmax; its OpenSkill implementation remains separate from the omitted official updater.

The adapter follows the live source's 50-tick surrender capture window,
neutralization credit, inactivity check at tick 121, and army/land/seat
adjudication after more than 2,000 idle ticks or the 50,000-tick long-game
threshold. Bot FFA permits the resulting terminal tick 50,002. Transport misses
are passes; explicit surrender and disconnect are game events. FFA's initial
input window is 1.5 seconds, as in the official pre-game delay. Accelerated bot
execution, human budgets, network deadlines, and the platform job deadline remain
hosting constraints. Two engine ticks correspond to one full official game turn.

The shared base engine now pays the final tick's growth, including on a capture
or surrender ending. The external comparison includes that final board rather
than exempting its income difference. Historical episode frames and pinned source
revisions remain unchanged.

Replay format 2 uses a full keyframe every 256 frames and sparse tile replacements
between them. Python and browser readers reconstruct a single sought frame from
its nearest keyframe. Published v1 full-frame recordings retain their explicit
reader. Browser terminal handoff uses one gzip/base64 recording after artifact
persistence, so long recordings do not require a new request after proxy retirement.
Observations are batched and converted to host arrays once per tick; the player
wire format and fog masks remain unchanged.

The retained real-session workflows exercise play past the old 2,000-tick cap,
idle adjudication and replay seeking, and a surrendered general captured within
the window. That killer then surrenders and must outrank a later kill-less survivor.
The existing reference workflow now requires an identical terminal board too.

The replay/live clock also follows the official client counter: `floor(tick / 2)`
with a dot on odd ticks. Network actions and the replay seek slider still address
engine ticks. The initial 1.5-second input window prevents eight stdio subprocesses
from being mistaken for disconnects while initializing, matching the supplied
live game's pre-game delay. Live kill information is a boolean `has_kill`, as in
the official score stream; exact counts are recorded only for completed replays/results.

The official copyright page identifies OpenSkill for stars and matchmaking.
The public `strakam/generals-bots` tree at
`954927f508aa47899019d66317cc313af3e9cc19` contains no rating updater.
The user requested continuation of the existing league under OpenSkill. Its
settings API requires an explicit typed-state migration rather than interpreting
Elo numbers as OpenSkill. Scheduling was paused with zero pending, claimed or
running rounds. The commissioner-state compare-and-swap moved standings aside,
settings were conditionally replaced, and all four typed OpenSkill standings
were restored before resuming. No round, episode or membership was deleted.
Round attribution, round counts, score tallies and policy bookkeeping were kept.
The old pairwise Elo win/draw/loss counters were restarted because OpenSkill
counts whole episodes. Ratings start at mu 50 and sigma 50/3; future results
establish their estimates. Plackett-Luce uses the library-scaled beta and tau
defaults; exact official star parameters remain unverified.
The pre-migration state is backed up in
[Nexus](https://softmax.nexus/artifacts/b1792b0d-0d9e-46be-a0b7-2d06d2ea0c60).

Pre-release checks: 600 generated Survival-order cases and 600 surrender/neutralization
cases matched the supplied live Game methods across three through eight seats.
These compare isolated official methods on valid states, not live rated games.
The ordinary local eight-bot variant completed 50,002 ticks with zero timeouts
and a 30 MB recording. Two deliberate regressions (one-tick neutralization and
the old 2,000-tick cap) each failed the corresponding retained system workflow.

Manual browser proof used the saved eight-seat recording on
`http://127.0.0.1:18995/#replay=long.json`, at 1440×1000 and 390×844.
Seeking from tick 49,000 back to 512, changing to Maroon fog, the official
clock, scorecards and result all rendered without browser errors.

All 224 checks passed locally, including the private terminal-board reference,
all browser modules and both new real-session FFA system cases. Modules ran in
separate processes with CPU JAX and four-core affinity. The benchmark-only
`test_performance.py` collects zero tests. One concurrent live-handoff attempt
failed when its baseline player hit an initial timeout; the isolated complete
workflow subsequently passed with zero timeouts.

The real human FFA check used `--human --players 4 --seed 7 --max-turns 80`
on port 18991, at 1440×1200. Clicking Surrender after automatic passes eliminated
the seat while leaving its general owned. Surrender is independent of the action
deadline and is accepted during collection or resolution.
[Browser proof](https://softmax.nexus/artifacts/450cfc72-af66-4461-a9c8-74f0ad87d1d3).

Released source `66050e3c2239ff14189186ed254af6c1aefc9f8e` passed source CI
(223 passed, one private reference skipped), all eight native AMD64 container
fixtures and all ten hosted certification checks. Coworld
`cow_adf51684-c097-4f0c-ba02-c1d8e138b61b` is canonical. Readbacks confirm all
three leagues resolve to it and the default FFA still uses OpenSkill, the seat
rungs and eight episodes per round. Public wiki revision
`wrv_759ca94a-7055-4ed6-bbfe-b2891855ee6a` contains the current rules.
Artifact hashes and hosted verification are recorded in VARIANTS.md.

The supplied live `Game.js` used for the additional method comparisons has
SHA-256 `3f93ed25346cec357414c8a3ab894938437c13bff747539f4c015e7945290c41`.
[Survival comparison](https://softmax.nexus/artifacts/afee369d-ff06-4bd2-aa77-271c4236a1d9)
and [neutralization comparison](https://softmax.nexus/artifacts/9dd16b42-132d-46cb-aa2e-3031f053c858)
retain the case counts, source hash, external adapter hash and validation limits.
The private JavaScript remains outside the repository, game image and viewer.

The ordinary hosted eight-seat 0.6.0 run completed 50,002 ticks with zero
timeouts and persisted a 37,028,185-byte recording. Its live spectator reached
the final result but missed the recording opt-in: Kubernetes proxying can strip
optional query fields, while the player bridge restores only its known fields.
The 0.6.1 browser therefore subscribes to replay delivery with an explicit
WebSocket message. Both player and global connections handle that subscription;
bots retain their bounded terminal messages. The complete live-handoff system
workflow now strips optional query parameters and requires both browsers to keep
the recording after HTTP proxy retirement. No game or scoring rules changed.

Release 0.6.1 from `69d95a0faadf9b98b9126e1855a8ac175d2f18c8` passed
all eight native fixtures and all ten hosted checks. It is canonical as
`cow_14c35330-f928-44a7-a3cd-a8e48577a195`. A spectator connected before play
on the ordinary four-seat variant transitioned LIVE → REPLAY after tick 710,
with all 711 frames, placements and zero timeouts in its downloadable recording.
The same session rendered desktop/mobile, fog and backward seeking without
browser errors. The saved public eight-seat recording also seeks to 50,002
and back to 0. VARIANTS.md links the exact episodes, hashes and browser proof.
All three leagues resolve to the patch; FFA remains default/OpenSkill and runs
eight episodes per round. The transport fix changes no game or rating rules.

Final CI at test-only follow-up `c01f5ba` passed 223 checks with the private
reference skipped. The runtime source is identical to released `69d95a0`;
subsequent commits record documentation evidence only.

### Live skill scores (companion to Metta PR 30441)

The live game now displays the public launch-time rating next to every name.
Socket players receive the same typed `player_ratings` metadata in `hello` and
observations. BASIC reads integer hundredths with `playerSkill(slot)` and checks
availability with `playerRated(slot)`. A null score remains unrated; names are
never used as identity keys. The persisted native recording retains launch scores.
The platform opt-in is `COWORLD_PLAYER_RATINGS=true`; existing published replay
versions retain their original flag and immutable bundles.
