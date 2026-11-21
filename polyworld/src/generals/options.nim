import
  polyworld/cli,
  common, players, settings

export cli.GameOptions

const SupportedFlags* = AllCommonFlags - {
  VerboseFlag, LlmModeFlag, ServerFlag, RoomFlag
}

type Options* = object
  settings*: Settings
  game*: GameOptions
  assets*: string
  autoTurns*: int
  headless*, startGame*, showHelp*: bool
  humanPlayer*: int

proc failOption(message: string) {.noreturn.} =
  ## Raises one game-specific command-line error.
  raise newException(GeneralsError, message)

proc initialSettings(arguments: seq[string]): Settings =
  ## Loads the final config before applying explicit command-line overrides.
  result = defaultSettings()
  var
    path = ""
    index = 0
  while index < arguments.len:
    let argument = arguments[index]
    if argument.splitFlag().name == "--config":
      path = arguments.flagValue(index, argument)
    inc index
  if path.len > 0:
    result = loadSettings(path)

proc resolve(options: var Options, explicitCount, seatBots: bool) =
  ## Assigns human and bot controllers once the complete CLI is known.
  var groupCount = 0
  for group in options.game.botGroups:
    if group.count < 1 or group.count > MaxPlayers:
      failOption("A bot group must contain 1 to 10 players.")
    groupCount += group.count
    if groupCount > MaxPlayers:
      failOption("A match supports at most 10 bots.")
  if groupCount > 0 and seatBots:
    failOption("Choose grouped --bot paths or explicit --seat-bot seats.")
  if groupCount > 0 and not explicitCount:
    discard options.settings.applySetting(
      "--players=" & $(groupCount + int(options.game.playerSlot > 0))
    )
  elif not explicitCount and groupCount == 0 and
    options.game.playerSlot > options.settings.config.players.int32:
      discard options.settings.applySetting(
        "--players=" & $options.game.playerSlot
      )
  let count = options.settings.config.players
  if options.game.playerSlot < 0 or options.game.playerSlot > count.int32:
    failOption("--player must be between 1 and " & $count & ".")
  if options.headless and options.game.playerSlot > 0:
    failOption("--player requires the graphical client.")
  options.game.capture.validateCapture(
    graphical = not options.headless and not defined(emscripten)
  )
  options.humanPlayer =
    if options.game.playerSlot > 0:
      options.game.playerSlot.int - 1
    elif options.headless or groupCount > 0 or
      options.settings.botFiles[0].len > 0:
        -1
    else:
      0
  if groupCount > 0:
    if groupCount != count - int(options.humanPlayer >= 0):
      failOption("Bot groups must fill all " &
        $(count - int(options.humanPlayer >= 0)) & " nonhuman seats.")
    options.settings.botFiles = default(BotFiles)
    var seat = 0
    for group in options.game.botGroups:
      for instance in 0 ..< group.count:
        if seat == options.humanPlayer:
          inc seat
        discard options.settings.applySetting(
          "--bot=" & $(seat + 1) & ":" & group.path
        )
        inc seat
  elif options.game.playerSlot > 0 and
    options.settings.botFiles[options.humanPlayer].len > 0:
      failOption("The human --player seat also has a BASIC bot configured.")
  if options.game.replayPath.len > 0:
    var hasBots = groupCount > 0
    for path in options.settings.botFiles:
      hasBots = hasBots or path.len > 0
    if hasBots or options.game.playerSlot > 0 or
      options.game.recordPath.len > 0:
        failOption("--replay cannot combine with --bot, --player, or --record.")
    options.humanPlayer = -1
    options.startGame = true
  if groupCount > 0 or options.game.playerSlot > 0:
    options.startGame = true
  if options.game.playerName.len > 0:
    if options.humanPlayer < 0:
      failOption("--name requires a human player; use --seat-name for bot names.")
    let seat = options.humanPlayer
    discard options.settings.applySetting(
      "--name=" & $(seat + 1) & ":" & options.game.playerName
    )
  discard options.settings.resolvedRoster()

proc parseOptionsImpl(arguments: seq[string]): Options =
  ## Delegates common values to Polyworld and keeps only Generals extensions.
  result.headless = defined(headless)
  if "--help" in arguments or "-h" in arguments:
    result.showHelp = true
    return
  result.settings = initialSettings(arguments)
  result.game = GameOptions(
    seed:
      if result.settings.config.seed <= int32.high.uint64:
        result.settings.config.seed.int32
      else:
        0,
    tickRate: 2,
    maximumTicks: result.settings.config.maxTurns.int32,
    seconds: result.settings.config.maxTurns.int32 div 2,
    windowWidth: 1280,
    windowHeight: 900
  )
  var
    explicitCount = false
    seatBots = false
    index = 0
  while index < arguments.len:
    let
      argument = arguments[index]
      flag = argument.splitFlag()
    if flag.name in ["--size", "--turns"]:
      let name = if flag.name == "--size": "--windowSize" else: "--ticks"
      var canonical = arguments
      canonical[index] = name & (if flag.attached: "=" & flag.value else: "")
      discard result.game.takeCommonFlag(canonical, index, canonical[index])
    elif result.game.takeCommonFlag(arguments, index, argument):
      discard
    else:
      case flag.name
      of "--headless", "--start":
        if flag.attached:
          failOption(flag.name & " does not take a value.")
        result.startGame = true
        if flag.name == "--headless":
          result.headless = true
      of "--config":
        discard arguments.flagValue(index, argument)
        explicitCount = true
      of "--players", "--seat-name", "--mmr", "--seat-bot", "--player-info":
        let
          value = arguments.flagValue(index, argument)
          setting =
            case flag.name
            of "--seat-name": "--name"
            of "--seat-bot": "--bot"
            else: flag.name
        if flag.name == "--players":
          explicitCount = true
        if flag.name == "--seat-bot":
          seatBots = true
        discard result.settings.applySetting(setting & "=" & value)
      of "--at":
        result.autoTurns = boundedNumber(
          arguments.flagValue(index, argument), "Starting tick", 0, 100_000
        )
      of "--assets":
        result.assets = arguments.flagValue(index, argument)
      else:
        failOption("Unknown argument: " & argument)
    inc index
  result.game.rejectUnsupportedFlags(SupportedFlags)
  result.game.validateGameOptions()
  if result.headless:
    result.game.validateHeadlessOptions()
  elif HeadlessTickRateFlag in result.game.specifiedFlags:
    failOption("--headless-tick-rate requires headless mode.")
  if SeedFlag in result.game.specifiedFlags:
    discard result.settings.applySetting(
      "--seed=" & $cast[uint64](result.game.seed.int64)
    )
  if result.game.specifiedFlags * DurationFlags != {}:
    discard result.settings.applySetting("--turns=" & $result.game.maximumTicks)
  if result.game.windowWidth notin 1'i32 .. 7680'i32 or
    result.game.windowHeight notin 1'i32 .. 7680'i32:
      failOption("Window dimensions must be between 1 and 7680.")
  result.resolve(explicitCount, seatBots)

proc parseOptions*(arguments: seq[string]): Options =
  ## Reports shared and game-specific parsing failures through the game error.
  try:
    result = parseOptionsImpl(arguments)
  except CliError, ScreenshotError:
    failOption(getCurrentExceptionMsg())
