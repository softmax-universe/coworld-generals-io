import
  std/[os, strutils, times],
  polyworld/timings,
  generals/[bots, brains, common, events, messages, players, profiles,
    replays, settings, options, worlds]

when not defined(headless):
  import vmath, generals/views

when defined(coworld):
  import polyworld/coworld, generals/hosts

proc assetDirectory(): string =
  ## Finds bundled graphics beside the project or an installed executable.
  for directory in [
    getCurrentDir() / "assets",
    getAppDir() / "assets",
    getAppDir().parentDir / "assets",
    getAppDir().parentDir / "Resources/assets"
  ]:
    if fileExists(directory / "images/crownie.png"):
      return directory
  raise newException(GeneralsError, "Cannot find assets. Use --assets=PATH.")

proc report(world: World, roster: Roster, elapsed: float64) =
  ## Prints the current match result after simulation or verified playback.
  echo "Seed ", world.config.seed, ", ", world.config.players,
    " players, ", world.turn, " ticks."
  if not world.finished:
    echo "Match in progress."
  elif world.winner >= 0:
    echo "Winner: player ", world.winner + 1
  else:
    echo "Draw."
  for player in 0 ..< world.config.players:
    let
      score = world.totals(player)
      mmr = roster.playerMmr(player)
      rank = if mmr < 0: "?" else: $mmr
    echo roster.displayName(player), " (MMR ", rank, "): ",
      score.land, " land, ", score.army, " armies."
  echo "Simulation CPU seconds: ", formatFloat(elapsed, ffDecimal, 3)

proc simulate(
    config: Config,
    roster: Roster,
    botFiles: BotFiles,
    recordPath: string,
    tickRate: int32
) =
  ## Runs native or BASIC policies and records public actions and messages.
  var
    world = newWorld(config)
    moves = newSeq[Move](config.players)
    scratch: BotScratch
    recorder: ReplayRecorder
    brains: array[MaxPlayers, Brain]
    hub: MessageHub
    log: MatchLog
  for player in 0 ..< config.players:
    if botFiles[player].len == 0:
      continue
    if hub == nil:
      hub = newMessageHub(roster, config.players)
      log.resetLog()
    let source =
      when defined(coworld):
        hostedSource(botFiles[player], player)
      else:
        readSource(botFiles[player])
    brains[player] = newBrain(source, player, hub)
  if recordPath.len > 0:
    recorder = newReplayRecorder(world, roster)
  let started = cpuTime()
  var pacer = initTickPacer(tickRate)
  defer:
    finishProfileTrace()
  while not world.finished:
    if world.turn == ProfileStart:
      startProfileTrace()
    var before: EventSnapshot
    if hub == nil:
      for player in 0 ..< config.players:
        moves[player] = chooseMove(world, player, scratch)
    else:
      before = snapshotEvents(world)
      for player in 0 ..< config.players:
        moves[player] =
          if not world.alive[player]:
            noMove()
          elif brains[player] != nil:
            brains[player].decide(world)
          else:
            chooseMove(world, player, scratch)
    world.tick(moves)
    if recorder != nil:
      recorder.recordTick(world, moves)
    if hub != nil:
      log.recordTick(before, world, moves)
      hub.deliverMessages(log, world.turn)
      for entry in log.entries:
        if entry.turn != world.turn:
          continue
        case entry.kind
        of Capture, Victory, Draw:
          hub.broadcastEvent(entry)
        of Chat:
          if recorder != nil:
            discard recorder.recordChat(entry.player, entry.turn, entry.text)
        of Notice:
          discard
    if profileShouldDump(world.turn - ProfileStart):
      finishProfileTrace()
    pacer.pace()
  world.report(roster, cpuTime() - started)
  if recorder != nil:
    saveReplay(recordPath, recorder.data)
    echo "Saved replay: ", recordPath
  when defined(coworld):
    finishHosted(world)

proc replay(path: string, tickRate: int32) =
  ## Reconstructs and verifies every recorded tick without invoking any bots.
  let
    data = loadReplay(path)
    player = newReplayPlayer(data)
    started = cpuTime()
  var
    world = newReplayWorld(data)
    moves: array[MaxPlayers, Move]
    pacer = initTickPacer(tickRate)
  while player.replayTick(world, moves):
    pacer.pace()
  world.report(data.header.setup.roster, cpuTime() - started)
  echo "Verified ", data.hashes.len, " replay ticks in lockstep."

proc usage() =
  ## Prints the shared Polyworld flags and the local game extensions.
  echo "Polyworld Generals"
  echo "  --player[:SEAT]       Control a human seat, default 1."
  echo "  --bot PATH[:COUNT]    Add BASIC bots in seat order. Repeatable."
  echo "  --bot:PATH[:COUNT]    Equivalent compact bot form."
  echo "  --players N          Set the FFA roster size, 2 through 10."
  echo "  --config PATH        Load engine JSON before CLI overrides."
  echo "  --seed N             Reproduce a map, 0 through 18446744073709551615."
  echo "  --headless           Simulate or verify without a window."
  echo "  --record PATH        Save a Polyworld action replay."
  echo "  --replay PATH        Watch or verify a recorded match."
  echo "  --ticks N            Maximum ticks, default ", DefaultTurns, "."
  echo "  --seconds N          Duration at two ticks per second."
  echo "  --minutes N          Duration at 120 ticks per minute."
  echo "  --play true|false    Start graphical playback playing or paused."
  echo "  --speed N            Initial graphical speed: 1, 2, 4, or 16."
  echo "  --windowSize WxH     Set the native window size."
  echo "  --vsync on|off       Set display synchronization, default on."
  echo "  --headless-tick-rate N  Wall-clock ticks per second, 0 unlimited."
  echo "  --llm-mode async|barrier  Shared policy scheduling selection."
  echo "  --start              Skip the menu; bare --play is also accepted."
  echo "  --name SEAT:NAME     Set a public player name (seats 1-10)."
  echo "  --mmr SEAT:RANK      Set a star rank, or -1 for unknown."
  echo "  --bot=SEAT:PATH      Legacy assignment to one specific seat."
  echo "  --player-info on|off Expose names and MMR to BASIC, default on."
  echo "  --assets PATH        Use another bundled asset directory."
  echo "  --screenshot PATH    Capture the menu or game, then exit."
  echo "  --frames N           Render N frames before capture, default 30."
  echo "  --at N               Fast-forward to a match or replay tick."
  echo "  --turns N            Alias for --ticks."
  echo "  --size WxH           Alias for --windowSize."
  echo "Capture flags accept split, equals, and colon forms."
  echo "Other flags support split and equals forms, including --replay=PATH."

proc main() =
  ## Starts a configured local match or standard Polyworld replay session.
  let parsed =
    when defined(coworld):
      hostedOptions()
    else:
      parseOptions(commandLineParams())
  if parsed.showHelp:
    usage()
    return
  let
    config = parsed.settings.config
    roster =
      when defined(coworld):
        parsed.settings.roster
      else:
        parsed.settings.resolvedRoster()
  if parsed.headless:
    if parsed.game.replayPath.len > 0:
      replay(parsed.game.replayPath, parsed.game.headlessTickRate)
    else:
      simulate(
        config,
        roster,
        parsed.settings.botFiles,
        parsed.game.recordPath,
        parsed.game.headlessTickRate
      )
  else:
    when defined(headless):
      raise newException(GeneralsError, "This build has no graphical viewer.")
    else:
      let assets =
        if parsed.assets.len > 0:
          parsed.assets
        else:
          assetDirectory()
      runGraphics(
        config,
        assets,
        parsed.game.capture,
        parsed.autoTurns,
        parsed.startGame,
        ivec2(parsed.game.windowWidth, parsed.game.windowHeight),
        replayPath = parsed.game.replayPath,
        recordPath = parsed.game.recordPath,
        roster = parsed.settings.roster,
        botFiles = parsed.settings.botFiles,
        autoWidth = parsed.settings.autoWidth,
        autoHeight = parsed.settings.autoHeight,
        humanPlayer = parsed.humanPlayer,
        pauseOnStart = parsed.game.pauseOnStart,
        initialSpeed = parsed.game.speed.int,
        vsync = parsed.game.vsync
      )

when defined(coworld):
  try:
    main()
  except GeneralsError, CoworldError:
    let message = getCurrentExceptionMsg()
    closePlayerOutputs()
    quit("Generals: " & message, 1)
else:
  try:
    main()
  except GeneralsError as error:
    quit("Generals: " & error.msg, 1)
