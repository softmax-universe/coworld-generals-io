import
  std/os,
  generals/[common, options, players, settings]

template rejects(body: untyped) =
  ## Requires invalid game-level options to raise the public exception.
  block:
    var failed = false
    try:
      body
    except GeneralsError:
      failed = true
    doAssert failed, "Expected a Generals command-line error."

echo "Testing default and game-specific command-line options"
block:
  let parsed = parseOptions(@[])
  doAssert parsed.settings.config == defaultConfig()
  doAssert parsed.game.seed == 1
  doAssert parsed.game.maximumTicks == DefaultTurns
  doAssert parsed.game.seconds == DefaultTurns div 2
  doAssert parsed.game.speed == 1
  doAssert parsed.game.vsync
  doAssert parsed.game.windowWidth == 1280
  doAssert parsed.game.windowHeight == 900
  doAssert parsed.game.capture.path.len == 0
  doAssert parsed.game.capture.frames == 30
  doAssert not parsed.startGame
  doAssert parsed.humanPlayer == (if defined(headless): -1 else: 0)
  doAssert parseOptions(@["--help"]).showHelp
  doAssert parseOptions(@["--config", "/missing/file", "-h"]).showHelp
  when not defined(headless):
    doAssert not parseOptions(@["--play", "true"]).startGame
  doAssert parseOptions(@["--start"]).startGame
  let legacy = parseOptions(@[
    "--players=3", "--seed=7", "--turns=100", "--seat-bot=2:bots/scout.bas",
    "--seat-name=2:Scout", "--mmr=2:37", "--player-info=off"
  ])
  var config = defaultConfig(7, 3)
  config.maxTurns = 100
  doAssert legacy.settings.config == config
  doAssert legacy.settings.botFiles[1] == absolutePath("bots/scout.bas")
  doAssert legacy.settings.resolvedRoster().displayName(1) == "Scout"
  doAssert legacy.settings.resolvedRoster().playerMmr(1) == 37
  doAssert not legacy.settings.roster.exposePlayerInfo

echo "Testing standard bot groups and inferred FFA counts"
for count in 2 .. MaxPlayers:
  let parsed = parseOptions(@["--bot", "bots/scout.bas:" & $count])
  doAssert parsed.settings.config.players == count
  doAssert parsed.settings.config == defaultConfig(1, count)
  doAssert parsed.humanPlayer == -1
  doAssert parsed.startGame
  doAssert parsed.game.botGroups.len == 1
  doAssert parsed.game.botGroups[0].count == count
  for seat in 0 ..< count:
    doAssert parsed.settings.botFiles[seat] == absolutePath("bots/scout.bas")
  for seat in count ..< MaxPlayers:
    doAssert parsed.settings.botFiles[seat].len == 0
block:
  let parsed = parseOptions(@[
    "--bot:bots/first.bas:2", "--bot=bots/second.bas", "--seed", "23"
  ])
  doAssert parsed.settings.config == defaultConfig(23, 3)
  doAssert parsed.settings.botFiles[0] == absolutePath("bots/first.bas")
  doAssert parsed.settings.botFiles[1] == absolutePath("bots/first.bas")
  doAssert parsed.settings.botFiles[2] == absolutePath("bots/second.bas")
  let split = parseOptions(@["--bot", "123:3"])
  doAssert split.settings.config.players == 3
  doAssert split.game.botGroups.len == 1
  doAssert split.game.botGroups[0].path == "123"
  doAssert split.settings.botFiles[2] == absolutePath("123")

echo "Testing common bot aliases have identical path and count semantics"
for flag in ["--bot", "--bots"]:
  for flags in [@[flag, "123:3"], @[flag & "=123:3"], @[flag & ":123:3"]]:
    let parsed = parseOptions(flags)
    doAssert parsed.settings.config.players == 3
    doAssert parsed.game.botGroups.len == 1
    doAssert parsed.game.botGroups[0].path == "123"
    doAssert parsed.game.botGroups[0].count == 3
  for flags in [@[flag, "C:\\bots\\scout.bas:2"],
      @[flag & "=C:\\bots\\scout.bas:2"],
      @[flag & ":C:\\bots\\scout.bas:2"]]:
    let parsed = parseOptions(flags)
    doAssert parsed.game.botGroups[0].path == "C:\\bots\\scout.bas"
    doAssert parsed.game.botGroups[0].count == 2

echo "Testing common seed range, exact speed, and silent audio options"
block:
  for seed in [int32.low, -1'i32, 0'i32, int32.high]:
    let parsed = parseOptions(@["--seed:" & $seed])
    doAssert parsed.game.seed == seed
    doAssert parsed.settings.config.seed == cast[uint64](seed.int64)
  when not defined(headless):
    doAssert parseOptions(@["--speed", "3"]).game.speed == 3
  doAssert parseOptions(@["--mute"]).game.soundMuted
  doAssert not parseOptions(@["--mute", "false"]).game.soundMuted
  doAssert not parseOptions(@["--unmute"]).game.soundMuted

when not defined(headless):
  echo "Testing --name belongs to the selected human seat"
  for flags in [@["--name", "Scout"], @["--name=Scout"], @["--name:Scout"]]:
    let parsed = parseOptions(@["--player", "2"] & flags)
    doAssert parsed.settings.resolvedRoster().displayName(1) == "Scout"
    doAssert parsed.humanPlayer == 1
  let named = parseOptions(@["--name", "2:Scout"])
  doAssert named.settings.resolvedRoster().displayName(0) == "2:Scout"

when not defined(headless):
  echo "Testing every selectable human seat with ordered bot expansion"
  for seat in 1 .. MaxPlayers:
    let
      parsed = parseOptions(@["--player:" & $seat])
      config = defaultConfig(1, max(DefaultPlayers, seat))
    doAssert parsed.settings.config == config
    doAssert parsed.humanPlayer == seat - 1
    doAssert parsed.game.botGroups.len == 0
    for path in parsed.settings.botFiles:
      doAssert path.len == 0
  for count in 2 .. MaxPlayers:
    for seat in 1 .. count:
      let parsed = parseOptions(@[
        "--player:" & $seat, "--bot:bots/scout.bas:" & $(count - 1)
      ])
      doAssert parsed.settings.config.players == count
      doAssert parsed.game.playerSlot == seat.int32
      doAssert parsed.humanPlayer == seat - 1
      doAssert parsed.startGame
      for index in 0 ..< count:
        doAssert parsed.settings.botFiles[index] ==
          (if index == seat - 1: "" else: absolutePath("bots/scout.bas"))
  for flags in [
    @["--player", "--bot", "bots/scout.bas"],
    @["--player=1", "--bot:bots/scout.bas"],
    @["--player", "1", "--bot:bots/scout.bas"]
  ]:
    let parsed = parseOptions(flags)
    doAssert parsed.settings.config.players == 2
    doAssert parsed.humanPlayer == 0
  let parsed = parseOptions(@[
    "--player=2", "--bot:bots/first.bas", "--bot:bots/second.bas"
  ])
  doAssert parsed.settings.botFiles[0] == absolutePath("bots/first.bas")
  doAssert parsed.settings.botFiles[1].len == 0
  doAssert parsed.settings.botFiles[2] == absolutePath("bots/second.bas")
  doAssert parseOptions(@["--seat-bot=1:bots/scout.bas"]).humanPlayer == -1

when not defined(headless):
  echo "Testing Polyworld transport, window, and boolean forms"
  block:
    for flags in [
      @["--play", "false", "--speed", "4", "--windowSize", "800x400",
        "--vsync", "off"],
      @["--play=false", "--speed=4", "--windowSize=800X400", "--vsync=off"],
      @["--play:false", "--speed:4", "--windowSize:800x400", "--vsync:off"]
    ]:
      let parsed = parseOptions(flags)
      doAssert parsed.game.pauseOnStart
      doAssert parsed.game.speed == 4
      doAssert parsed.game.windowWidth == 800
      doAssert parsed.game.windowHeight == 400
      doAssert not parsed.game.vsync
      doAssert parsed.game.headlessTickRate == 0
      doAssert not parsed.game.waitForLlm
    for value in ["true", "1", "yes", "on"]:
      doAssert not parseOptions(@["--play=" & value]).game.pauseOnStart
    for value in ["false", "0", "no", "off"]:
      doAssert parseOptions(@["--play=" & value]).game.pauseOnStart
    let parsed = parseOptions(@["--", "--size", "1024x576"])
    doAssert parsed.game.windowWidth == 1024
    doAssert parsed.game.windowHeight == 576
    doAssert not parsed.game.waitForLlm

echo "Testing headless pacing and unsupported visual controls"
for flags in [@["--headless-tick-rate", "24"],
    @["--headless-tick-rate=24"], @["--headless-tick-rate:24"]]:
  doAssert parseOptions(@["--headless"] & flags).game.headlessTickRate == 24
  when not defined(headless):
    rejects:
      discard parseOptions(flags)
when not defined(headless):
  rejects:
    discard parseOptions(@["--headless-tick-rate", "0"])
for flags in [@["--play", "false"], @["--speed=3"],
    @["--windowSize:800x600"], @["--vsync", "false"], @["--frames", "3"]]:
  rejects:
    discard parseOptions(@["--headless"] & flags)

echo "Testing durations follow the native half-second tick"
for (flags, expected) in {
  @["--seconds", "60"]: 120,
  @["--seconds=60"]: 120,
  @["--seconds:60"]: 120,
  @["--minutes", "3"]: 360,
  @["--minutes=3"]: 360,
  @["--minutes:3"]: 360,
  @["--ticks", "481"]: 481,
  @["--ticks=481"]: 481,
  @["--ticks:481"]: 481,
  @["--turns", "99"]: 99,
  @["--minutes", "3", "--ticks=7"]: 7,
  @["--ticks=7", "--seconds", "3"]: 6
}:
  let parsed = parseOptions(flags)
  doAssert parsed.settings.config.maxTurns == expected
  doAssert parsed.game.maximumTicks == expected.int32
  doAssert parsed.game.seconds == expected.int32 div 2

echo "Testing replay and retained asset capture aliases"
block:
  for flags in [@["--replay", "out/match.replay"],
    @["--replay=out/match.replay"], @["--replay:out/match.replay"]]:
      let parsed = parseOptions(flags)
      doAssert parsed.game.replayPath == "out/match.replay"
      doAssert parsed.startGame
      doAssert parsed.humanPlayer == -1
  let parsed = parseOptions(@[
    "--headless", "--record", "out/match.replay", "--seed", "9"
  ])
  doAssert parsed.game.recordPath == "out/match.replay"
  doAssert parsed.headless and parsed.humanPlayer == -1
  when not defined(headless):
    let capture = parseOptions(@[
      "--start", "--assets", "assets", "--screenshot", "out/game.png",
      "--at", "200", "--size", "1024x576"
    ])
    doAssert capture.assets == "assets"
    doAssert capture.game.capture.path == "out/game.png"
    doAssert capture.game.capture.frames == 30
    doAssert capture.autoTurns == 200

when not defined(headless) and not defined(emscripten):
  echo "Testing shared screenshot options without opening a window"
  for flags in [
    @["--screenshot", "out/first frame.png", "--frames", "1",
      "--windowSize", "640x360"],
    @["--screenshot=out/first frame.png", "--frames=1",
      "--windowSize=640x360"],
    @["--screenshot:out/first frame.png", "--frames:1",
      "--windowSize:640x360"]
  ]:
    let parsed = parseOptions(flags)
    doAssert parsed.game.capture.path == "out/first frame.png"
    doAssert parsed.game.capture.frames == 1
    doAssert parsed.game.capture.framesSpecified
    doAssert parsed.game.windowWidth == 640
    doAssert parsed.game.windowHeight == 360
    doAssert not parsed.startGame
    doAssert parsed.game.recordPath.len == 0
  let windowsPath = parseOptions(@["--screenshot:C:\\captures\\frame.png"])
  doAssert windowsPath.game.capture.path == "C:\\captures\\frame.png"

echo "Testing config precedence and explicit roster counts"
block:
  let path = getTempDir() / ("generals-cli-" & $getCurrentProcessId() & ".json")
  writeFile(path, """{"players":[{"name":"A","bot":"old.bas"},
    {"name":"B","mmr":37},{"name":"C"}],"seed":9,"width":35}""")
  defer:
    removeFile(path)
  for flags in [
    @["--seed", "7", "--config", path, "--bot:new.bas:3"],
    @["--config=" & path, "--bot:new.bas:3", "--seed=7"]
  ]:
    let parsed = parseOptions(flags)
    doAssert parsed.settings.config.players == 3
    doAssert parsed.settings.config.seed == 7
    doAssert parsed.settings.config.width == 35
    doAssert parsed.settings.config.height == defaultConfig(7, 3).height
    for seat in 0 ..< 3:
      doAssert parsed.settings.botFiles[seat] == absolutePath("new.bas")
    doAssert parsed.settings.resolvedRoster().displayName(0) == "A"
    doAssert parsed.settings.resolvedRoster().playerMmr(1) == 37
  rejects:
    discard parseOptions(@["--config", path, "--bot:new.bas:2"])
  rejects:
    discard parseOptions(@["--config", path, "--replay", "out/match.replay"])
  writeFile(path, """{"players":[{},{}],"seed":18446744073709551615}""")
  doAssert parseOptions(@["--config", path]).settings.config.seed == uint64.high

echo "Testing invalid controller combinations and bounded expansion"
for flags in [
  @["--headless", "--player"],
  @["--headless", "--name", "Scout"],
  @["--bot", "bots/scout.bas:2", "--name", "Scout"],
  @["--replay", "out/match.replay", "--name", "Scout"],
  @["--headless", "--screenshot=out/game.png"],
  @["--replay=out/match.replay", "--record=out/again.replay"],
  @["--replay=out/match.replay", "--bot:bots/scout.bas:2"],
  @["--replay=out/match.replay", "--seat-bot=2:bots/scout.bas"],
  @["--replay=out/match.replay", "--player"],
  @["--replay=out/match.replay", "--seed", "3"],
  @["--replay=out/match.replay", "--seconds", "3"],
  @["--replay=out/match.replay", "--ticks", "3"],
  @["--player=11"],
  @["--players=4", "--player=5"],
  @["--player", "--seat-bot=1:bots/scout.bas"],
  @["--bot:bots/scout.bas:2", "--seat-bot=2:bots/other.bas"],
  @["--bot:bots/scout.bas"],
  @["--players=4", "--bot:bots/scout.bas:2"],
  @["--bot:bots/scout.bas:10", "--bot:bots/other.bas"],
  @["--bot:bots/scout.bas:0"],
  @["--bot:bots/scout.bas:-1"],
  @["--bot:bots/scout.bas:11"],
  @["--bot:bots/scout.bas:999999999999999999999999999999999999999"],
  @["--bot::2"],
  @["--seed=2147483648"],
  @["--seed=-2147483649"],
  @["--seconds=50001"],
  @["--minutes=1000"],
  @["--ticks=0"],
  @["--speed=0"],
  @["--speed=2147483648"],
  @["--player", "--player:2"],
  @["--player=invalid"],
  @["--play=invalid"],
  @["--vsync:invalid"],
  @["--windowSize=0x400"],
  @["--windowSize=800x400x200"],
  @["--headless-tick-rate=-1"],
  @["--llm-mode=invalid"],
  @["--llm-mode=async"],
  @["--llm-mode=barrier"],
  @["--server=ws://localhost:9911/ws"],
  @["--room=ABCDEF"],
  @["--verbose"],
  @["--windowSize=8000x400"],
  @["--seat-name", "5:Outside"],
  @["--bot"],
  @["--replay", "--seed", "7"],
  @["--screenshot="],
  @["--screenshot"],
  @["--screenshot:"],
  @["--screenshot", "--frames", "1"],
  @["--frames=0"],
  @["--frames:-1"],
  @["--frames=invalid"],
  @["--frames=2147483648"],
  @["--frames="],
  @["--frames"],
  @["--assets="],
  @["--replay="],
  @["--unknown"]
]:
  rejects:
    discard parseOptions(flags)

echo "Command-line option checks passed"
