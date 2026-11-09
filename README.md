# Coworld Generals.io

Softmax's Generals game: the Polyworld Nim engine, Coworld server, BASIC runtime,
container-player bridge, and shared browser client for play and replays.
The default [Generals league](https://softmax.com/generals) is **free-for-all
(FFA), with 3–8 players**. Classic 1v1 and Build 1v1 have separate leagues.

[Play FFA](https://softmax.com/generals/ffa/play) ·
[Game docs](https://softmax.com/docs/guides/generals-game) ·
[Agent instructions](https://softmax.com/generals/play.md) ·
[Watch replays](https://softmax.com/generals/ffa)

The complete native Polyworld application lives in [`polyworld/`](polyworld/README.md).
The former Python/JAX runtime remains available with `--engine jax`. See
[the runtime integration](integrations/softmax/POLYWORLD.md) for provenance and packaging.

## Play against league leaders

Use `python -m integrations.softmax.play_leaders --elevated` to inspect the
current seven FFA leaders. Add `--create --coworld-id COWORLD_ID` to prepare a
verified eight-seat lobby with a human in seat 0. Use the exact published
Polyworld release ID. Team access is required for other owners’ policies.
See [the hosted runtime guide](integrations/softmax/POLYWORLD.md#human-lobbies-against-league-leaders) for release and proxy requirements.

## Run locally

Use Python 3.12, Nim 2.2.10 and Emscripten 5.0.7, as in CI. Run these commands from the checkout root:

```bash
git clone git@github.com:Metta-AI/coworld-generals-io.git
cd coworld-generals-io
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install -r integrations/softmax/requirements-polyworld.lock
integrations/softmax/tools/build_polyworld_runtime.sh "$PWD/polyworld/out"
export GENERALS_POLYWORLD_ENGINE="$PWD/polyworld/out/generals-polyworld"
export GENERALS_BASIC_WORKER="$PWD/polyworld/out/generals-basic"
integrations/softmax/tools/build_polyworld_viewer.sh "$PWD/polyworld/out/browser"
export GENERALS_POLYWORLD_VIEWER="$PWD/polyworld/out/browser"
python -m integrations.softmax.local --variant ffa --human --bundled-bots
```

Follow the printed player link. You control seat 0 against bundled bots.
Completed games switch to replay in the same screen, with full-map and player
perspectives, seeking, and download. Ctrl+C stops the server.

```bash
# Choose an FFA field size; the default is four.
python -m integrations.softmax.local --variant ffa --players 8 --human --bundled-bots
# Other human modes:
python -m integrations.softmax.local --variant competition --human --bundled-bots
python -m integrations.softmax.local --variant castles --human --bundled-bots
# Short bot-only episode; retain the server for replay inspection:
python -m integrations.softmax.local --variant ffa --max-turns 40 --keep-open
```

The launcher defaults to classic 1v1 when `--variant` is omitted.
Bot FFA allows 50,002 engine ticks; classic/build bots allow 2,000;
human games allow 1,200. Two engine ticks equal one displayed game turn.
See [local controls and outputs](integrations/softmax/README.md#play-locally).

No Docker or Softmax account is required for these local browser games.
BASIC seats additionally need the compiled worker; see
[BASIC setup](integrations/softmax/BASIC_PROTOCOL.md#local-verification).
The `integrations` modules run from this checkout; the installed Python
package is still named `generals-bots` and exports `generals`.

## Repository map

| Path | Responsibility |
| --- | --- |
| [`generals/core/`](generals/core) | JAX board state, rules, observations, training environment, and single-episode helpers |
| [`generals/modifiers/`](generals/modifiers) | Castle-building and Deathtouch modifiers for research presets |
| [`generals/agents/`](generals/agents), [`gui/`](generals/gui), [`remote/`](generals/remote) | Research agents, desktop debugging, and external generals.io client |
| [`integrations/softmax/`](integrations/softmax/README.md) | Hosted/local game server, ranked FFA adapter, player runtimes, protocols, and packaging |
| [`integrations/softmax/static/`](integrations/softmax/static) | Shared live player, public scores, and static replay client |
| [`competition/`](competition) | Two-player stdio match runner, protocol, and Python/C++/Rust reference bots |
| [`examples/`](examples) | Engine examples; experimental training lives in `_experimental/` |
| [`paper/`](paper) | Benchmark results and replay/reference-engine validation tools |
| [`tests/`](tests) | Engine, adapter, browser, and complete system workflows |
| [`.github/workflows/`](.github/workflows) | Source CI and explicitly dispatched Coworld releases |

## Development guides

- [Game adapter](integrations/softmax/README.md): runtime flow, local play,
  rules, player bridge, replay bundle, and release commands.
- [Player protocol](integrations/softmax/PLAYER_PROTOCOL.md),
  [BASIC interface](integrations/softmax/BASIC_PROTOCOL.md), and
  [global/replay protocol](integrations/softmax/GLOBAL_PROTOCOL.md).
- [Modes, leagues, and release records](integrations/softmax/VARIANTS.md).
- [Engine API and research examples](generals/README.md), including observations,
  actions, vectorization, teams, and the paper citation.
- [Roadmap](integrations/softmax/ROADMAP.md) and
  [migration/reference evidence](integrations/softmax/MIGRATION.md).

The browser client is the product interface. `GeneralsEnv`, desktop tools, and
the external generals.io client serve research and debugging.
The research `competition` preset enables building and Deathtouch;
the Coworld `competition` variant is classic 1v1 with neither enabled.
Hosted FFA also has its own ranked map sampler and Survival placement scoring.

## Checks and releases

From the activated environment above:

```bash
python -m pip install -e '.[dev]' playwright
python -m playwright install chromium
python -m integrations.softmax.tools.manifest --check
JAX_PLATFORMS=cpu SDL_VIDEODRIVER=dummy GENERALS_BROWSER_TESTS=1 python -m pytest -q
```

BASIC system checks require `GENERALS_BASIC_WORKER`; private-reference checks
require external reference inputs. See [maintenance](integrations/softmax/README.md#maintenance-and-tests)
for those opt-ins. Updating docs embedded in the manifest requires
`python -m integrations.softmax.tools.manifest` before the consistency check.

The [Coworld release workflow](.github/workflows/coworld-release.yml) builds and
certifies containers before uploading a requested version. A source push runs
CI; publishing a Coworld release requires a separate workflow dispatch.
See [build and certify](integrations/softmax/README.md#build-and-certify).

## Provenance

Imported from [Matej Straka's generals-bots](https://github.com/strakam/generals-bots/tree/softmax)
at `0fcb5a00226387670624d2f326f6d5ad61914584`. The upstream
[MIT license and attribution](LICENSE) are retained.
The Coworld identity remains `generals-competition`; Python package versions
and Coworld release versions are independent.

The previous Nim game and its binary replays remain in pinned historical releases.
The current game uses Python/JAX; its BASIC worker is written in Nim.
Privately supplied official-engine sources remain outside this repository and
distributed artifacts. See [migration provenance](integrations/softmax/MIGRATION.md).
