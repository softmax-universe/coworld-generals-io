# Command-line flags

Generals uses Polyworld's shared command-line parser, with Generals'
half-second simulation ticks. Every valued flag accepts `--flag VALUE`,
`--flag=VALUE`, and `--flag:VALUE` with identical behavior.

Play against one BASIC opponent:

```sh
./out/generals --player --bot examples/scout.bas --seed 7
```

Control the tenth seat against nine BASIC opponents:

```sh
./out/generals --player:10 --bot:examples/scout.bas:9 --seed 7
```

Watch four BASIC bots, initially paused:

```sh
./out/generals --bot examples/scout.bas:4 --play=false --speed 4
```

Record a headless match and watch its replay:

```sh
./out/generals --headless --bot examples/scout.bas:4 --seed 7 \
  --ticks 4000 --record out/match.replay
./out/generals --replay out/match.replay
```

## Players and bots

`--player` controls seat 1. `--player:N`, `--player=N`, and `--player N`
select another one-based seat. Only one human is allowed, and a human
requires the graphical client. Input, fog, chat, and the outcome screen
follow that seat.

`--bot PATH[:COUNT]` and its alias `--bots PATH[:COUNT]` add BASIC bot groups. Repeat
the flag to combine policies. Bots fill seats in order, skipping the human.
Without `--players` or an engine config, the roster size is inferred from
the number of bots plus the human, and must be between 2 and 10. An explicit
roster must have exactly one supplied bot per nonhuman seat.

Bot groups without `--player` start an all-bot spectator match with the
whole board visible. Starting normally without bot groups keeps the local
human-versus-native-bots game. `--player:10 --players 10` also works with
native opponents.

`--seat-bot SEAT:PATH` assigns one BASIC policy to a specific
seat and leaves other seats using their existing native or human control.
Use either grouped bots or per-seat CLI assignments in one invocation.
A human seat cannot also have a bot. Grouped CLI bots replace config bot
assignments while keeping supplied names and MMR values.

`--name TEXT` sets the selected human seat's display name, including the
default local human. It requires a human controller. `--seat-name SEAT:NAME`
sets another roster entry, including a bot.
Names and bot paths never change meaning based on the value separator.

## Shared flags

| Flag | Behavior |
| --- | --- |
| `--replay PATH` | Play a recorded action tape, or verify it when headless. |
| `--record PATH` | Save the live match as a Polyworld action tape. |
| `--seed N` | Set the shared signed 32-bit seed. Negative seeds retain their signed bits in the map's unsigned seed. |
| `--ticks N` | Maximum simulation ticks, from 1 through 100000. |
| `--seconds N` | Set the limit to `N × 2` ticks. |
| `--minutes N` | Set the limit to `N × 120` ticks. |
| `--play true\|false` | Start graphical simulation or replay playing or paused. |
| `--speed N` | Exact positive integer graphical speed; default 1. |
| `--windowSize WxH` | Set the native window dimensions. |
| `--screenshot PATH` | Save a native PNG screenshot and exit. |
| `--frames N` | Render N frames before capture, default 30. |
| `--vsync on\|off` | Enable or disable display synchronization. |
| `--headless-tick-rate N` | Pace headless simulation or playback at N ticks per second; 0 is unlimited. |
| `--mute`, `--unmute` | Accepted for portable launch commands; this client has no audio. |

All three value forms are accepted, including `--seed=7`,
`--replay:out/match.replay`, and `--play false`. Later duration flags replace
earlier ones. Pacing never changes simulation ticks or recorded actions.
`--headless-tick-rate` requires a headless build or the `--headless` launch flag.
Unsupported LLM, relay, and verbose flags report errors rather than silently
accepting a setting this client cannot use.

Replays start at tick zero, playing and looping by default. `--play=false`
changes the initial playing state; `--at N` chooses another starting tick.
Replay playback cannot be combined with bot controllers, a human player,
or recording.

Capture uses the normal desktop executable and does not require a special
build. It renders in a hidden window without display pacing, creates the
output directory when needed, and exits after writing the PNG. Capture,
frame count, and window size accept split, equals, and colon forms:

```sh
./out/generals --screenshot out/menu.png --frames 30 --windowSize 1280x900
./out/generals --start --at 200 --screenshot=out/game.png --frames=1
```

Screenshots keep the requested menu, game, or replay tick still while the
frames render. `--at` selects a game or replay tick before capture. Capturing
does not enable replay recording. Headless and browser builds cannot capture
native screenshots.

## Generals extensions

`--start` skips the menu. `--play true` and `--play false` only choose
the initial transport state, as in every Polyworld game.
`--turns N` aliases `--ticks N`, and `--size WxH` aliases `--windowSize WxH`.

The `--config`, `--players`, `--seat-name`, `--seat-bot`, `--mmr`,
`--player-info`, `--assets` and `--at` flags accept all three value forms.
Engine JSON still supports full unsigned 64-bit seeds; the common command-line
`--seed` has the same signed 32-bit range in every game.
See [BASIC settings](BOTS.md), [maps](MAPS.md), and [replays](REPLAYS.md) for
their contracts. `--help` lists all supported flags.
