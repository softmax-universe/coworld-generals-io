# Generals modes and leagues

The game is displayed as **generals.io**. One `generals-competition` Coworld
carries every mode; each bot mode runs as its own Softmax league. The display-name
override preserves the manifest identity, version history, and existing links.
New releases are maintained in `Metta-AI/coworld-generals-io`.

**FFA (3–8 players) is the recorded default landing league.**
The [Generals page](https://softmax.com/generals), its Play button,
and [play.md](https://softmax.com/generals/play.md) select the FFA league.
Classic and Build stay available through their explicit league addresses.
Game-of-the-Week selection and the default league are separate platform settings;
re-check both after publishing a release. The settings and hosted status below
reflect the release readbacks recorded here; source `main` can contain later changes.

## Modes

| Variant | Seats | Rules | Turn cap |
| --- | --- | --- | --- |
| `competition` | 2 | Classic rules, neutral castles | 2,000 |
| `ffa` | 4 | Polyworld maps, Survival outcomes and hosted adjudication | 50,002 |
| `ffa-3`, `ffa-5` through `ffa-8` | 3, 5–8 | Corresponding Polyworld FFA | 50,002 |
| `castles` | 2 | Build castles on owned plain land; no starting neutral castles | 2,000 |
| `human`, `ffa-human`, `castles-human` | 2, 4, 2 | Corresponding rules, 500 ms minimum tick and 1 s deadline | 1,200 |
| `ffa-3-human`, `ffa-5-human` through `ffa-8-human` | 3, 5–8 | Corresponding paced FFA | 1,200 |

Human variants keep 1,200 turns: at two turns per second, 2,000 turns would take
at least 17 minutes and risk Softmax's 20-minute hosted episode deadline. Every
mode disables Deathtouch and resolves moves in generals.io's order (see README).
FFA uses Survival ordering: a kill or win qualifies a player for the upper
partition, then each partition sorts by reverse elimination order. Caps
adjudicate remaining players by army, land, and seat rather than drawing.
The official long-game threshold completes engine tick 50,002. Two engine
ticks correspond to one full official game turn. Softmax's accelerated bot
clock, finite job deadline, and unverified exact star parameters remain differences.
See README and the player protocol for surrender, inactivity, and scoring.

## Leagues

| League | Variant | League ID | Division |
| --- | --- | --- | --- |
| [Classic 1v1](https://softmax.com/observatory/v2?detail=league:league_8c189954-be68-479c-a092-eeb79c436d12) | `competition` | `league_8c189954-be68-479c-a092-eeb79c436d12` | Competition `div_5ee4b276-f330-42e8-b8e4-a6097c779d99` |
| [FFA (3–8 players)](https://softmax.com/observatory/v2?detail=league:league_f189ad01-2700-4fc8-ba89-f9de477099e4) | `ffa`, `ffa-3`, `ffa-5` through `ffa-8` | `league_f189ad01-2700-4fc8-ba89-f9de477099e4` | FFA `div_ac86d8a0-7b43-41bb-b6e7-1867f7b47d08` |
| [Build 1v1](https://softmax.com/observatory/v2?detail=league:league_b371d42e-bed5-4f33-ac02-fca229860ddf) | `castles` | `league_b371d42e-bed5-4f33-ac02-fca229860ddf` | Castles `div_ede858f5-6c57-4d03-b16d-a843a35e8bc2` |

All three are public and use the platform commissioner. FFA uses OpenSkill
Plackett-Luce (mu 50, sigma 50/3); Classic and Build retain Elo. All follow the
canonical Coworld version: a certified upload moves every league to it without
league changes. Classic and Build use Swiss-neighbor scheduling.

FFA uses `random_fill`, `num_episodes: 8`, `insufficient_players: do_not_run`,
and `variant_rotation: ["ffa-8"]`. Its seed's default variant is also `ffa-8`;
the planner derives the seat count from that default before checking rotation.
Each episode selects eight distinct champions, balancing appearances across the
round and shuffling seats. Fewer than eight champions waits for more entrants.
OpenSkill, the thirty-minute cadence, and retry settings remain unchanged.

The November 5, 2026 repair replaced the `scaling_roster` / `roster_overflow: sample`
configuration, which sampled once and repeated the same lineup across all eight episodes.
Rounds 4821–4823 each contained one distinct lineup. Preserve other stored settings
using a conditional replacement from `/settings/snapshot`. Default-variant changes
require paused rounds, locked submissions, and no active rounds; restore the
previous pause and submission state after the change.

Verification round `round_4d9f19e9-d679-448d-9874-62580817c38f` (4827) completed
all eight episodes on 0.7.4 at 01:27 UTC. It used seven distinct lineups;
all twelve eligible champions appeared five or six times. Scheduling is owned
by the platform and did not require a game rebuild.

The FFA and Build leagues were created on September 17 (20:24 UTC) by the
Softmax team, after Matej's account was refused with HTTP 403
`Only Softmax team members may set the default variant`. Matej owns the classic
league; setting a league's default variant remains team-only.

## Validation and maintenance

The same engine, server, player bridge and replay renderer implement all modes.
New rules or visuals require one Coworld build; league scheduler configuration
is managed separately. Add focused checks when changing elimination, fog,
build receipts, player counts, or browser queues. Certify the container and run
hosted verification for each affected mode; classic-only certification does not
prove FFA or building works.

Local smoke/full matches (omit `--max-turns` for the hosted mode budget):

```bash
python -m integrations.softmax.local --variant ffa --seed 7
python -m integrations.softmax.local --variant castles --seed 7
GENERALS_BROWSER_TESTS=1 pytest tests -q
```

These baseline matches validate integration, not playing strength or draw-rate
balance. Release 0.4.0 shields WebSocket cleanup from cancellation. Release 0.4.2
drains terminal messages before shutting down the game server.

## Releases

Ignored deployment logs, manifests, replay artifacts and exact API responses are
kept in `local-output/release-<version>/`.

### 0.7.5 — November 5, 2026 (UTC)

- Release source: `0640434e8b80b6ed6a609bbdb16f72b2252fa968`, including merged
  `46d3926cb8c686accb7ecb9c286f0d3c1e134ba6` and the capture-fixture repair in
  [PR 34](https://app.graphite.dev/github/pr/softmax-universe/coworld-generals-io/34).
  Full-width unsigned 64-bit seeds now use SplitMix64 maps; BASIC has the merged
  memory/work budgets, and completed replays hold the winner screen before looping.
- [Source CI](https://github.com/softmax-universe/coworld-generals-io/actions/runs/41948983959)
  passed, including Linux BASIC sandbox and browser cases. Local native suites,
  manifest checks, capture/replay, full-width seed and winner-pause browser checks passed.
  The changed generator required seed 7 for the existing surrender capture scenario;
  its assertions remain unchanged and reject an early-neutralization mutation.
- [Release workflow](https://github.com/softmax-universe/coworld-generals-io/actions/runs/41950408524)
  passed native AMD64 certification across all modes and all ten hosted checks.
  Hosted certification completed at 01:51 UTC under `main-a863ab36887f`.
- Canonical Coworld: `cow_cba82314-5d9e-4779-a45b-125788c98a70`.
  Manifest: `sha256:a3a2eb93bc5e556ef65cdbcbc238b0ee60edc3310262e56a319813504e44009b`.
  Game image: `sha256:67c6b7cee3bc8e6a107c77dd9ee400c1fd7dab3860d0cf9539569d7f27cd0fe3`.
  The workflow's source commit records provenance; the manifest retains the legacy
  repository alias's mutable `main` source URL.
- FFA verification round `round_d7d2ea99-0704-4400-9db5-fc1c87082189` (4828)
  completed all eight episodes at 01:56 UTC, with eight distinct lineups and all
  twelve champions appearing five or six times. The league remains unpaused with
  submissions open, eight-seat `random_fill`, OpenSkill, and a thirty-minute cadence.
- [Hosted replay](https://softmax.com/episode-requests/ereq_94ac36de-7a25-4320-8c6b-d8214a30eebd/watch)
  rendered in isolated headless Chromium at 1280×720.
  [Screenshot](https://softmax.nexus/artifacts/d5288cf8-97b8-4891-bc3b-cb31142c51a6).
  Native inspection of its decompressed recording confirms eight players, 729 ticks,
  seed `10812957718315239762`, and final state hash `F8097FD4437082FC`.

### 0.7.4 — November 3, 2026 (UTC)

- Release inputs: source `f1ed54e935508839f29f30d8c33dcea923fb5276`, Coworld SDK 0.1.68,
  floating Polyworld `main` resolved to `872774b9f593e7f771b215f0d5c1dd65031f05e7`.
  [PR 29](https://app.graphite.dev/github/pr/Metta-AI/coworld-generals-io/29) adds compact binary replays and
  responsive viewing; [PR 31](https://app.graphite.dev/github/pr/Metta-AI/coworld-generals-io/31) unifies policies.
- [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41730488030) owns native AMD64
  certification, publication and hosted certification. Use its `generals-release` manifest and the
  [release verification record](https://softmax.nexus/activity/note%3A1c16c4ad-5110-4e3b-8287-1f502ab79098)
  for the published artifact identities, canonical readback and hosted match results.
- Standalone and hosted BASIC use one policy host and decision limits. Existing row/column policies and the
  unchanged upstream Scout work. BASIC, container and human seats share the actual Polyworld MessageHub,
  including names, skill, private mail, public chat and game events. A build reserves the same action slot
  before engine legality checks for both BASIC and socket players. Private messages never enter replays.
- The final source passes both complete CI runs, the imported Nim suite, 46 server checks, 18 browser/rules/handoff
  checks, six Linux system cases and 40 native ARM64 container checks. All three current BASIC champions pass
  strict native compilation and finish a bounded real-image FFA at tick 457, with zero timeouts.
  An actual human/Docker message exchange completes 80 ticks with zero timeouts. Its compact replay retains
  public chat at its recorded tick and excludes both private texts; rewind hides later chat and the result.
- The first workflow attempt was cancelled during build before its publish step when the additional policy
  unification was requested. This release uses the final merged source; historical uploads remain unchanged.

### 0.7.3 — November 3, 2026 (UTC)

- Released `59e5d87d03132a670f696ece51b62a764507ad98` from `main` after
  [PR 27](https://app.graphite.dev/github/pr/Metta-AI/coworld-generals-io/27).
  BASIC Frontier evaluates at most 128 movable tiles per decision and preserves
  its scan cursor. Worker limits and policy-failure behavior remain unchanged.
- [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41705720872)
  passed all nine native AMD64 fixtures (90 checks) and ten hosted checks.
  Canonical Coworld: `cow_5f94983e-d47c-4f3c-8737-7d159a2f83e7`, certified
  under `main-a98aacd5bfdb`, job `e4630607-960e-4ddf-840f-1b3af40e0c42`.
  Hosted certification completed at 20:01:04 UTC.
- [Source CI](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41703412815)
  passed 235 tests, skipped one private-reference check, and passed the additional
  published-viewer browser check. Polyworld `main` was rechecked at
  `872774b9f593e7f771b215f0d5c1dd65031f05e7` before dispatch.
- Public package readback verifies the exact merged BASIC bytes. Classic, FFA,
  and Build participation guides all resolve to this version. League settings
  are unchanged; all three leagues are unpaused. Existing uploaded policy files
  retain their contents; this release updates the bundled starter.
- Artifact digests (SHA-256): game
  `bcd5ede2f14821b44cdfe42dae606c27f06270be86c9009cec7befb0a11b8132`;
  container baselines
  `136de2cb03cda4de8f6bb5cadfd7915c591db7e8848966ea62a3ff62e3ab2c66`;
  BASIC `3111ee777f1192f3ee54aea823ec79fc2921b21f1eab96b0ca440c52e8fd4bd1`;
  viewer `ed605fa1b0027eaf5eea289d733105e796dec8cb0fe7fd6c9acebab147e847b3`;
  manifest `c27a0e8617d25db32701c9667bf97e98e372d8b2711b3f82aa52b2b815ce1431`.
  [Readback proof, verification script, and check summaries](https://softmax.nexus/artifacts/428edf20-9e8f-4e1d-bbf1-067193cbe9a5).

### 0.7.2 — November 3, 2026 (UTC)

- Released source `98eb024c47814c0c16dd3006387d0472ad9f9821` after
  [PR 25](https://app.graphite.dev/github/pr/Metta-AI/coworld-generals-io/25) and the upstream refresh in
  [PR 26](https://app.graphite.dev/github/pr/Metta-AI/coworld-generals-io/26).
  Polyworld floating `main` resolved to `872774b9f593e7f771b215f0d5c1dd65031f05e7`.
  Later source changes on `main` are separate from this immutable release.
- [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41702523681) passed all nine
  native AMD64 fixtures (90 checks) and all ten hosted checks. Canonical Coworld:
  `cow_6352c5a2-927e-483e-af46-4fa2826e2ca8`; certification request
  `f6de8515-b482-43ac-8225-5a014646ce26`, job `4f208a0d-f8fc-4ba9-a210-c4de0f243d6f`.
  Game image SHA-256: `2a7f61b6341f447bad7e812fb6c00272f2cf1de81a48801e5c9c2d6756557c76`.
  Release manifest SHA-256: `55eff24b71a727c74ba377dba20b2d981477405fbfef160a865231bf495341b6`.
- Live matches enable `COWORLD_PLAYER_RATINGS=true`. Public leaderboard scores reach browser cards, socket
  observations, BASIC queries, and saved native replays. Launch snapshots are labeled separately from the
  replay viewer's current standings. Unrated players display —.
- [Platform PR 30441](https://app.graphite.dev/github/pr/Metta-AI/metta/30441) deployed as
  `f52548967adf87ade8a7ee0cde34ebd430dd717c`. The API, dispatcher, and orchestrator were ready on that revision.
  The dispatcher and a real round worker used coordinator SHA-256
  `960120cf023534fc788c00eab6c61a6814fefe0c61e45a8f9b53a736d3c4166e`.
  The mixed-roster fix preserves file-player failure attribution without looking up a nonexistent container pod.
- Resumed the existing FFA league through `rounds-paused` at 19:42:35 UTC after certification and deployment.
  Normal scheduling created **round 4765** (`round_da917e09-0bf1-4620-a5e9-6952c69236c4`) at 19:43:13 UTC.
  It completed at 19:46:28 UTC: all **16/16 episodes** used 0.7.2 and completed without job errors.
  The nine-player roster used the existing partitioning rules. Scoring excluded no episodes and applied the
  ladder update; all seven previously rated players advanced by one round. Existing cadence, policy budgets,
  retry limits, and OpenSkill settings were preserved.
- [Production replay](https://softmax.com/generals/episodes/afe7ee03-a02d-408d-9c64-d16db53eb98d) uses the new
  Polyworld viewer and real skill scores. At 1440×1000, the result appeared at tick 3446 and disappeared after
  rewinding to tick one; all replay state hashes validated. The saved tape retains its match-start score array.
  [Round and standings screenshot](https://softmax.nexus/artifacts/61212441-f6bf-48a5-af89-2305556712ff) and
  [native replay screenshot](https://softmax.nexus/artifacts/f1198701-5846-409b-a1a9-b464ce882be6) show production data.

### 0.7.1 — November 3, 2026 (UTC)

- Released `94714fea76247bcb60779237952cac71d7793f11` from `main` after
  [PR 23](https://app.graphite.dev/github/pr/Metta-AI/coworld-generals-io/23).
  The native replay reveals the winner/reason only at its end and hides them
  after rewind. The player column is 240 logical pixels; grid gaps are two pixels.
  Player and event text are larger.
- [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41580761750)
  passed all nine native AMD64 fixtures (90 checks) and ten hosted checks.
  Canonical Coworld: `cow_41063b1f-d001-4d19-92fb-3a2d6550647f`, certified
  under `main-0027dbc916f3`, job `15b6c25d-5df4-4d73-963d-54abb1cfd9a2`.
- Current leaderboard skill display is implemented in the viewer, enabled through
  `COWORLD_REPLAY_PLAYER_RATINGS=true`. Actual values require the companion
  [platform PR 30441](https://app.graphite.dev/github/pr/Metta-AI/metta/30441),
  awaiting merge authorization at this release. Until deployment, seats show —.
  The platform uses the normal leaderboard's published score and player identities;
  local API/Postgres/storage proof covers policy seats, ranked humans and retries.
  These are current standings, not historical pre-match ratings.
- Fresh hosted Classic, FFA8 and Build checks completed 80 ticks with zero player
  timeouts, using existing registered container/file policies. These shortened
  packaging checks do not establish playing strength. Public episodes:
  [Classic](https://softmax.com/generals/episodes/45b926c4-5a35-400c-a4b9-0f8e8742c8cb),
  [FFA8](https://softmax.com/generals/episodes/df841f0c-0cc9-4fce-a6c5-b8a967b6e9bf),
  [Build](https://softmax.com/generals/episodes/614db5e1-8e86-45e1-bc10-5ac231ca0474).
  The production FFA8 viewer was checked at 1440×1000: no initial result,
  the winner at tick 80, and no result after rewind. Older episodes retain
  their release's immutable viewer.
- Artifact digests (SHA-256): game
  `be20a96aeab1ad4580ddcdb35d7e45a065930dd4217dd4b1529d62cc4925164c`;
  container baselines
  `a5f1dee334660bf7c56f8f6b3d9e8e9ea9df699e41f716c30505563cf067a342`;
  BASIC `5c6988224b71a16c5d60313bd3b9b9837951c45897ff30a1235456028c9c8bc7`;
  viewer `ad5edca41e11fb705d627f1f3aae243a6ffb505feb753af9094b4ffd46175cf3`;
  manifest `d949c1c1bc2d0ba80489a1494d80b9659d12ccb8073e742f907f62328ec7c87d`.
  Upstream sync still follows `main`; the release records its imported source
  `500a98d66777f53e6dd1ca1f2127ebb826018f4a` for provenance.

### 0.7.0 — November 3, 2026 (UTC)

- Released `e9a22e69c79344fe0f72891e61eec7547fce7ff6` from `main` with
  Coworld SDK 0.1.68 after merging
  [PR 21](https://app.graphite.dev/github/pr/Metta-AI/coworld-generals-io/21).
  Dispatch: `gh workflow run coworld-release.yml --ref main -f version=0.7.0`.
  [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41560770570)
  passed all nine native AMD64 fixtures (90 checks) and all ten hosted checks.
- Canonical Coworld: `cow_71c0969f-50b9-4061-8cbc-d0105def089f`.
  Hosted certification reports `certified` under contract `main-dd69cce1df37`,
  job `279b8aa4-4f0a-49b3-92d4-fdf9072f1a43`.
- The game uses the Polyworld Nim engine and native Silky WebAssembly replay
  viewer. Hosted recordings contain command tapes with per-command state hashes.
  All 173 upstream files were imported from `main` at
  `500a98d66777f53e6dd1ca1f2127ebb826018f4a`, rechecked before release.
  The sync command follows upstream `main`; recorded revisions preserve provenance.
- All sixteen variants and the same three leagues remain available. Readback
  preserves all 21 champion memberships: thirteen distinct registered versions,
  ten container policies and three file policies. FFA remains the default league.
  All league version locks are unset, so they follow the canonical release.
- Three ad hoc hosted checks used existing registered policies, seed 7, and an
  80-tick cap. Classic, mixed eight-player FFA and Build completed with zero
  timeouts. Their saved recordings use `polyworld-generals-hosted` format 1.
  These checks verify compatibility and packaging, not playing strength.
- Public replay pages display the native viewer for all three checked episodes.
  FFA playback, seeking to tick 80, fog perspectives and resizing from 1440×1000
  to 390×844 were verified in an isolated browser.
  [Production screenshot](https://softmax.nexus/artifacts/b79dc9e6-b260-4131-9ca4-d08e0636f471),
  [mobile](https://softmax.nexus/artifacts/acdd8dbb-66a8-46c4-bc2e-9ad5f06aca97),
  [recording](https://softmax.nexus/artifacts/fb58bb8c-3a34-4b19-b5de-869103a3ecb9).
- FFA scheduling was already automatically paused at 00:45 UTC, before this
  release, after exhausting retries. That pause remains unchanged. The ad hoc
  checks did not change league memberships, ratings or scheduler settings.

Hosted verification:

| Mode | Experience request | Public episode |
| --- | --- | --- |
| Classic | `xreq_35df4802-b367-40b2-ac8e-bdd1d514c0cf` | [Replay](https://softmax.com/generals/episodes/04c862fe-0652-44c3-b472-c2f7b1ec2c0b) |
| FFA8 | `xreq_d408cfba-0e67-48a2-bfcb-984bb347ee97` | [Replay](https://softmax.com/generals/episodes/0de65c46-dae3-40a5-8ae2-3c2562e63c36) |
| Build | `xreq_5f4affda-1af0-4801-a09d-7bcfa2c6fe20` | [Replay](https://softmax.com/generals/episodes/353b434f-6983-4f13-850b-821424c09c52) |

Published artifact identities:

- Manifest: `sha256:81019fc77fec337a2dc0a15c9a5a5cb4ae4e49f394537fbc0bc777d59916f8d1`.
- Game image: `sha256:4d83b80ad9cfada26062a14a0f7e1fa25551bf32481612388e8cbd7cc7812e44`.
- Player image: `sha256:79c27f800e4bb5a46e7a56846e7e67b86bfc41100056d2ea776ad021f18e2f68`.
- Replay bundle: `sha256:dc55ae6e53e95dffaea665a2a4b344d11f6dc5064c07f1b655dffb9efe4a3ddf`.

### 0.6.5 — November 2, 2026 (UTC)

- Released `03b151c30d3cbcdf65372f2ff73a0da26e5867e4` with Coworld SDK 0.1.68.
  Built from the `relh/generals-game-docs` worktree branch with
  `gh workflow run coworld-release.yml --ref relh/generals-game-docs -f version=0.6.5`.
  [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41542963247)
  passed all nine native AMD64 fixtures (90 checks) and all ten hosted checks.
- Canonical Coworld: `cow_a083d120-69e0-4119-b516-358feb473703`.
  Public API readbacks confirm Classic, FFA, and Build resolve both current and
  canonical Coworld IDs to this release. Hosted certification reports `certified`
  under contract `main-10663a413cd0`.
- The manifest now embeds `docs/README.md`, the player-facing game guide,
  instead of the developer integration runbook. It covers controls, BASIC and
  container players, rules, Survival scoring, deadlines, and replays.
  Public readback matches the source README byte for byte.
- The website mirror and Generals Docs link are tracked in
  [Metta PR #30377](https://app.graphite.dev/github/pr/Metta-AI/metta/30377).
  They use the public docs area because community wiki routes are unavailable
  in the newer play experience.
- The full local engine/integration/browser suite passed 223 tests, with four
  skipped, in 424.92 seconds. Manifest consistency and ten native arm64
  container checks passed. No rules, player protocols, or runtime code changed.

Published artifact identities:

- Manifest: `sha256:26012ea2dec8c33995f604c079f5989ae3ee21eb1e6e677ac81db0bb09b3afd8`.
- Game image: `sha256:a48daec0883854ff667bafa6cc6c7a6c679c21b96eae61cb08b46b23254dc86f`.
- Player image: `sha256:726b5a28be40a940bac90b6e52459b151a71110fb80a1c0f31749d8e56fd5950`.
- BASIC baseline: `sha256:5c6988224b71a16c5d60313bd3b9b9837951c45897ff30a1235456028c9c8bc7`.
- Replay bundle: `sha256:a705ceb7abc0297232a8e9b65d9171aedb0d0ec88121f4022f9a9f35e1b3293e`.
- README: `sha256:c72e3a716b6c67739d2189c469876c58ff5a80dad999ce01f5a838cb8c2ddd0c`.

### 0.6.4 — November 2, 2026 (UTC)

- Released `4b761975030c6f9260ab7697d2671009af1cd021` with Coworld SDK 0.1.68.
  Dispatch: `gh workflow run coworld-release.yml --ref main -f version=0.6.4`.
  [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41527330470)
  passed all nine native AMD64 fixtures (90 checks) and all ten hosted checks.
- Canonical Coworld: `cow_eedfa858-bac6-419e-89da-b86d6605a1ba`.
  Public API readbacks confirm Classic, FFA, and Build resolve both current and
  canonical Coworld IDs to this release. Hosted certification reports `certified`
  under contract `main-713fc262f557`.
- Live boards and new replay bundles use the official player, terrain, fog,
  and grid colors. Generals and captured castles retain their owner's color.
  Existing episodes retain their pinned historical viewers.
- The full local engine/integration/browser suite passed 223 tests, with four
  skipped. Manifest consistency and ten native arm64 container checks passed.
- Loaded the deployed static viewer with an existing seven-player recording.
  It rendered 648 tiles and played the replay with the new palette. The deployed
  `board.css` matches the tested source SHA-256 below.
  [Hosted screenshot](https://softmax.nexus/artifacts/0c7d18a2-5c1b-4c13-95f8-482ebe672003)
  is available to staff. This checks the new viewer against a saved recording;
  the hosted certification separately exercised a new real game episode.

Published artifact identities:

- Manifest: `sha256:d2e0aed10c19b9013733939a5d14c30877c279cec3e87324aa9c087f17e7d970`.
- Game image: `sha256:5da7b3ab792f575aa83529f40c84319d7ef57c8a8904ec5314e75e5c90967ba0`.
- Player image: `sha256:046b8371e6b0386c59c92900fec1a9e020046a67a70dca6b2335a00c8f26b403`.
- BASIC baseline: `sha256:5c6988224b71a16c5d60313bd3b9b9837951c45897ff30a1235456028c9c8bc7`.
- Replay bundle: `sha256:a705ceb7abc0297232a8e9b65d9171aedb0d0ec88121f4022f9a9f35e1b3293e`.
- Deployed board stylesheet: `sha256:8e52d2d000d07e06ff835af9773367c898132480abb1d35cc901885b6070629a`.

### 0.6.2 — October 31, 2026 (UTC)

- Released `c174984c68d36ad7de54ff90de873e435c00d849` with Coworld SDK 0.1.68.
  Dispatch: `gh workflow run coworld-release.yml --ref main -f version=0.6.2`.
  [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41223308984)
  passed all nine native AMD64 fixtures (90 checks) and all ten hosted checks.
- Requires platform revision `8038ecc4441271b9641682165751401a6cd50de4`.
  Hosted certification used contract `main-8038ecc44412`.
  The manifest declares `player_runtime: [platform-hosted, game-hosted]`;
  BASIC files, existing container policies, and human seats share the game.
- Canonical Coworld: `cow_bcffbcdf-2248-4758-abce-87eaaa90f65f`.
  Public API readbacks confirm Classic, FFA, and Build resolve both current and
  canonical Coworld IDs to this release. FFA remains default and uses OpenSkill;
  all three leagues remain public, enabled, and unpaused.

Published artifact identities:

- Manifest: `sha256:b18dfdd683ab892d6712f6bf1bb3235b54f40f01cafd1a03cb4359bed9996f56`.
- Game image: `img_ab6a925f-5233-4c53-ae88-ef71a7b35343`.
- Player image: `img_fb43b580-85aa-419f-8611-026c4538380d`.
- BASIC baseline: `sha256:5c6988224b71a16c5d60313bd3b9b9837951c45897ff30a1235456028c9c8bc7`.
- Replay bundle: `sha256:ba5a1447ce4d265d9d35f47bd85a4af742e9758bd9ac1806a68574018c258470`.

### 0.6.1 — October 30, 2026 (UTC)

- Released `69d95a0faadf9b98b9126e1855a8ac175d2f18c8` with SDK 0.1.60.
  [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41130338045)
  passed all eight native fixtures and all ten hosted certification checks.
- Canonical Coworld: `cow_14c35330-f928-44a7-a3cd-a8e48577a195`. Readbacks confirm all three
  leagues use it. FFA remains public/default, uses OpenSkill, runs eight episodes
  per round, and has resumed scheduling. Game and scoring rules match 0.6.0.
- Browsers subscribe to recording delivery with
  `{"type":"subscribe","replay":true}` on the established WebSocket. This removes
  the optional query-field dependency exposed by the hosted global-viewer hop.
  Bot connections retain bounded result-only terminal messages.
- Request `xreq_36f6e1f6-e100-4821-9c8a-3d9c1cf044c8` ran the four existing
  league policies with ordinary FFA settings. It ended by general capture at
  tick 710 with zero timeouts, placements `[3, 1, 2, 4]`, and kill counts
  `[0, 2, 1, 0]`. The spectator was connected before play and transitioned
  LIVE → REPLAY, retaining all 711 frames in its downloadable recording.
  [Public episode](https://softmax.com/generals/episodes/ad59ddbf-08c9-4243-865f-f8d3d692233a).
- Actual hosted review covered 1440×1000 and 390×844, seek 710 → 512, fog,
  result/kill information and the official counter. No browser errors were
  recorded in the live-handoff session.
  [Desktop](https://softmax.nexus/artifacts/979aecac-a394-415c-a940-7f6f38be6319),
  [mobile](https://softmax.nexus/artifacts/cfbab280-24cf-48de-a079-f9924942c18e),
  [live-to-replay recording](https://softmax.nexus/artifacts/3bd18325-2c7a-456b-9ab0-572e1a0f33e1).
- The unchanged engine's 0.6.0 public eight-player recording also loaded on
  desktop and mobile. Keyboard seeking reached frame 50,002 and returned to 0.
  [Final frame](https://softmax.nexus/artifacts/c2ad2609-86f1-495e-8bbf-e15e5b33cc7e),
  [mobile](https://softmax.nexus/artifacts/0427da13-1fb0-484f-b02e-90e8c43bde4a).
- The complete local handoff system workflow now strips optional query fields
  before the game receives them and retires HTTP access before checking player
  and spectator replay/download behavior. All 57 affected checks passed,
  including the four additional variant-browser checks. The two message-count
  helpers were updated to distinguish subscription metadata from game actions.
- [Final source CI](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41131274567)
  passed 223 tests with one private reference skipped at `c01f5ba`. The only
  change from released runtime source `69d95a0` is a browser test helper update.

Published artifact identities:

- Manifest: `sha256:0a32a0c9ca8c86948039328468827bc25fea44423b71aef51f2c157264dac1ce`.
- Game image: `sha256:0812e86838ffa5bb9eac2c3aa626315d41fdaef6a8511f3f5b2a1871c8c16b79`.
- Player image: `sha256:1bba9b311c9eb7011f310544f1930e7de6a73189a21a1871af379d668f827568`.
- Replay bundle: `sha256:ba5a1447ce4d265d9d35f47bd85a4af742e9758bd9ac1806a68574018c258470`.

### 0.6.0 — October 30, 2026 (UTC)

- Released source `66050e3c2239ff14189186ed254af6c1aefc9f8e` using Coworld SDK
  0.1.60. [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41127614548)
  passed all eight native AMD64 fixtures and all ten hosted certification checks.
- Canonical Coworld: `cow_adf51684-c097-4f0c-ba02-c1d8e138b61b`. All three
  leagues resolve to it. FFA remains the game's public default, with three-to-eight
  seats and eight episodes per round.
- FFA now uses official Survival ordering, kill credit, the 50-tick surrender
  capture window, initial inactivity rules, and idle/long-game adjudication.
  Ordinary bot FFA permits tick 50,002; human variants retain their hosted budget.
  The viewer displays two engine ticks per full official turn.
- The existing FFA league migrated from Elo to OpenSkill Plackett-Luce, with
  initial mu 50 and sigma 50/3. Its four entrants, round history, episode results,
  score tallies and round counts were preserved. Elo's pairwise win/draw/loss
  counters restarted because OpenSkill counts whole episodes. Scheduling was
  paused only during the validated commissioner-state/settings migration.
  Round 4610 (`round_f0188358-99ae-41ce-b3c9-bfe38a6b2905`) then completed
  eight games under the preceding game version: every skill estimate updated,
  uncertainty shrank, and historical round counts advanced normally.
- [Source CI](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41127075348)
  passed 223 checks with one private reference skipped. All 224 checks passed
  locally, including the identical terminal-board reference. Scoped Ruff,
  JavaScript syntax, manifest consistency and diff checks passed.
- Against the supplied live Game methods, all 600 generated Survival cases and
  all 600 surrender/neutralization cases matched across three through eight
  players. These are method comparisons, not full live rated-game validation.
- Eight real local bots completed 50,002 ticks with zero timeouts. The recording
  is 31,224,836 bytes raw and 1,529,805 bytes gzip. The retained system workflows
  cover play beyond 2,000 ticks, idle adjudication, capture during surrender,
  exact neutralization timing, Survival ordering and browser replay seeking.
- Manual browser proof covers 1440×1000 and 390×844 long replay views, seeking
  from tick 49,000 back to 512, fog, scorecards and the official counter.
  A real human FFA lobby at 1440×1200 verifies Surrender after automatic passes.
  [Desktop](https://softmax.nexus/artifacts/f7cd7be7-868d-480c-a151-dffed2b34e7a),
  [mobile](https://softmax.nexus/artifacts/dc479421-1397-442d-8657-de3b608d0109),
  [seeking recording](https://softmax.nexus/artifacts/202ea31c-ff6a-48da-acea-a5915ce9f75b),
  [surrender recording](https://softmax.nexus/artifacts/9366e77d-5ac1-47ac-9d36-9c041473f6b6).
- Public wiki rules now describe Survival, exits, inactivity, timing and OpenSkill.
  Exact official star parameters, accelerated bot execution and hosted deadlines
  remain differences; the release does not claim exact star-rating parity.

Hosted verification:

- Ordinary eight-seat request `xreq_6daee53b-7f81-41bf-ae34-28400c853b8b`
  completed all 50,002 ticks with zero timeouts and a 37,028,185-byte recording.
  [Public episode](https://softmax.com/generals/episodes/a9aa3f7d-089c-461b-bc1a-68631ea1ef8c).
- Round 4611 (`round_c605f9af-da26-4e68-a232-bdd8811680e1`) completed all eight
  ordinary four-player games on 0.6.0 and updated the same league's OpenSkill
  standings. Its scores distinguish every Survival placement. One checked game
  completed at tick 853 with zero timeouts and placements `[4, 1, 2, 3]`.
  [League episode](https://softmax.com/generals/episodes/c3bb4623-5ac5-4619-b14c-13ee4f4857ed).
- The hosted live spectator reached tick 50,002, but its query-based recording
  opt-in was lost through Kubernetes proxying. Saved public replays load correctly.
  Release 0.6.1 replaces the query opt-in with a WebSocket subscription.

Published artifact identities:

- Manifest: `sha256:332b08f2ad85a58302d9b8bfffb7ae0aad124e23a49a111716f6bec15ca78e23`.
- Game image: `sha256:5c868067edf7be25d83d4e449315b1f16e61cc865ba7cbfb7c870c094236fa7a`.
- Player image: `sha256:f4a9a936436febd8886a5687e859d3ee38245ccc40e68314d1f5c400174d7c43`.
- Replay bundle: `sha256:517da0eac26ad3603739a584a8e14b740a843527716092ddfabd1867e8f142ec`.

### 0.5.0 — October 30, 2026 (UTC)

- Released from `00f6cf90f47ff388c245b36ea782a96585d985b2` with Coworld SDK
  0.1.60. [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/41116286701)
  passed all ten container checks separately for classic, each FFA size from
  three through eight, and castle-building. Hosted certification passed all ten.
- Canonical Coworld: `cow_48f4d81a-2fa5-4db2-a72e-ed50c0648b3f`.
  All three leagues follow it. FFA is the game's default league and is displayed
  as **FFA (3–8 players)**. Its stored scheduler is the `scaling_roster`
  configuration above; the current four entrants play four-seat episodes.
- Source CI passed 221 tests, with the private-reference check skipped.
  All 222 checks passed locally, including that check, using separate module
  invocations. The official map comparison matched all 600 cases.
- Full-length eight-seat verification request
  `xreq_697778af-acd8-4eac-9634-9e5cd38bb519` completed 2,000 turns on a
  26×25 board with zero timeouts. The baseline bots drew at the turn cap.
  [Public episode](https://softmax.com/generals/episodes/204000b2-594c-422d-82ca-e6504abfbe8c).
- Public replay verification covered eight scorecards, colors, perspectives,
  seeking, fullscreen, and 1440×1000 / 390×844 viewports. Public wiki rules were
  updated while preserving its existing public upstream source links.

Published artifact identities:

- Manifest: `sha256:deef8c8222c0a41a124358bd49283f0fa764d83f2fc6070cb14852ad69654f95`.
- Game image: `sha256:cdf332ca17c59462f11708e4ae98ec7575959abe63b5cf88e31bd2e2da88fdd6`.
- Player image: `sha256:6e1c0aec94017fb4ba7e8d23743e227750c3cb4b4a179f56796e2a06473b6604`.
- Replay bundle: `sha256:b2f38687adf05c23ab48c9bd02ff257925c226a2b2abd65a239e84e248e00d80`.

### 0.4.2 — October 30, 2026 (UTC)

- Rebuilt native AMD64 from `2d6d9ccdd8f67932dcf2d5b847a710e08cdb3453`
  using Coworld SDK 0.1.60. This includes the completion handoff and full-height
  replay layout. The source suite passed 220 tests, with one private-reference
  check skipped.
- [Release workflow](https://github.com/Metta-AI/coworld-generals-io/actions/runs/40980596045)
  passed ten container certification checks separately for classic, FFA, and
  castle-building, then uploaded and passed hosted certification.
- Coworld `cow_20f616ae-1c0e-4bb5-9dc3-b2ac495a9d94` is canonical. All three
  leagues resolve both their current and canonical game to this version.
- The displayed name is now `generals.io`, set through the game's persistent
  display-name override. It remains set after canonical promotion.
- Full-length hosted verification requests, using the existing Expander and
  Builder policies with the ordinary 2,000-turn variants:
  classic `xreq_99f9eb5e-f810-4d18-b121-ebc87a174c0d`,
  FFA `xreq_87ef68d2-648d-4091-bb40-676b82fc7edf`,
  castles `xreq_b3b5f437-f458-464b-842f-79dc9b2b9db9`.

Published artifact identities:

- Manifest: `sha256:e15438ac084168328bf87f53474ac57f9e84ebba0462412261b81a771c36d100`.
- Game image: `img_3285aced-b80c-4c10-952e-0e6b33cf8e34`.
- Player image: `img_2f64f485-4bca-4935-a666-0c9c06143684`.
- Replay bundle: `sha256:f7a67556ab61c57a0ea8a3c228768e28d608b9d49d8a19dfd886bf3a8a843ef9`.

### 0.3.3 — September 27, 2026

- Documentation only: the embedded README states per-mode turn caps, the
  generals.io move order and the three leagues. Release source `f65fb55`.
- Coworld `cow_8f61ead9-f3c6-4be0-95ed-7ad0de6c961e`, canonical; all three leagues
  moved to it. Local and hosted certification passed. The live wiki was updated
  from `WIKI.md` the same day.

### 0.3.2 — September 27, 2026

- FFA and castle-building bot variants raised to 2,000 turns; human variants
  stay at 1,200. Release source `04e76ba` on `softmax`.
- Coworld `cow_08589716-ac45-4575-b3de-7e4cab635fc8`; all three leagues moved
  to it. Hosted certification passed ten checks and five smoke episodes.
- Full 2,000-turn FFA and castles games passed locally, in container
  certification and hosted (69 s and 49 s), all with zero timeouts:
  [FFA](https://softmax.com/generals-competition?e=78143037-11fc-4c4c-b6ca-2c62dbd90712),
  [castles](https://softmax.com/generals-competition?e=4a5bd1d4-8638-402b-91b8-228ecff085c9).

### 0.3.1 — September 27, 2026

- Master's replay-verified generals.io rules and faster simulator merged into
  `softmax` (`46c48c4`); general trade stays off, as in master's default env.
- Richard's PR #141 merged (`2f731fe`): classic bot games to 2,000 turns, replay
  viewer up to 2,001 frames. Release source `555622d`.
- Coworld `cow_cc72cd7d-5c39-469e-bae2-d79ecb8aebd3`. 207 tests plus 7 Chromium
  checks passed; local and hosted certification passed. Hosted full-length games
  in every mode completed with zero timeouts:
  [classic, 2,000 turns](https://softmax.com/generals-competition?e=5962de96-e834-48b4-9677-1d20db5722d1),
  [FFA](https://softmax.com/generals-competition?e=b657da12-19be-4bfe-bb59-dca60368d9f7),
  [castles](https://softmax.com/generals-competition?e=0368e1e7-ca3e-455c-8aec-574833f3a9e5).

### 0.3.0 — September 17, 2026

- Added `ffa`, `castles` and their human variants. Coworld
  `cow_8c336ec5-413c-4cfc-99b5-fbe2c1f71b5d`; release source `7632640` on
  `softmax` (implementation `3af20af`).
- 188 tests passed, including real Chromium checks. All three local container
  certification fixtures passed their ten checks. Hosted certification passed
  ten checks and five classic smoke episodes.
- Two full-length hosted episodes per new mode completed at turn 1,200 with
  zero timeouts and valid results/replays; building episodes contained eight
  and five construction actions. Requests: FFA
  `xreq_18150375-c866-4f82-a766-cc7a885bd79a`, castles
  `xreq_2d7c9001-a5cc-46a1-bb5d-ab2dbf817014`. Website replays:
  [FFA](https://softmax.com/generals-competition?e=ca3ebdc5-b9e5-413e-8169-7df02c54f692),
  [castles](https://softmax.com/generals-competition?e=933f9bbf-9338-4f9f-b00d-4a0d7d574079).

Hosted verification uses the baselines `strakam-generals-expander:v2`
(`c2c6eb89-51ff-4fba-928d-e35dfa278357`) and `strakam-generals-builder:v1`
(`0d7a26da-c81a-4173-906e-ee1fff21ffc4`), registered for 0.3.0 on the uploaded
lightweight player image. They are not league entrants.

### 0.2.x — early browser integration

These historical notes were previously embedded in the adapter README.

- 0.2.0 replaced the 0.1.0 competition modifiers with classic capture-only play,
  retaining the `generals-competition` game name and `competition` variant ID.
  The research competition preset remained separate.
- 0.2.1 accepted the hosted proxy's complete player WebSocket URL in `address`,
  while local links continued to use `slot` and `token`.
- 0.2.2 served live assets and completed replays under the proxied `/client/` path.
- 0.2.3 preserved mounted tile icons and queue arrows across turn updates.
- 0.2.4 sent automatic passes earlier and allowed human lobbies a one-second
  network deadline, retaining a 500 ms minimum tick interval and steady idle status.
- 0.2.5 kept independent queued routes separate, so one failed route did not
  cancel other routes.
