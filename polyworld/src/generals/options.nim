import
  std/strutils,
  polyworld/cli,
  common, players, settings

export cli.GameOptions

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

proc numeric(text: string): bool =
  ## Identifies nonempty decimal text without parsing or overflowing it.
  if text.len == 0:
    return false
  for character in text:
    if character notin {'0' .. '9'}:
      return false
  true

proc legacyBot(text: string): bool =
  ## Distinguishes an explicit numeric seat from a standard bot path.
  let separator = text.find(':')
  separator > 0 and text[0 ..< separator].numeric()

proc argumentValue(arguments: seq[string], index: var int): string =
  ## Consumes a required value without treating the next flag as its value.
  let name = arguments[index]
  inc index
  if index >= arguments.len or arguments[index].len == 0 or
    arguments[index].startsWith("--"):
      failOption(name & " requires a value.")
  arguments[index]

proc canonicalArguments(arguments: seq[string]): seq[string] =
  ## Normalizes split flags while preserving Polyworld bot and player forms.
  var index = 0
  while index < arguments.len:
    var argument = arguments[index]
    case argument
    of "--config", "--seed", "--players", "--turns", "--ticks",
      "--seconds", "--minutes", "--name", "--mmr", "--bot", "--player-info",
      "--at", "--assets", "--record", "--replay", "--screenshot", "--frames",
      "--size", "--windowSize", "--vsync", "--speed", "--headless-tick-rate",
      "--llm-mode":
        let value = arguments.argumentValue(index)
        if argument == "--bot":
          argument &= ":" & value
        else:
          argument &= "=" & value
    of "--player":
      if index + 1 < arguments.len and arguments[index + 1].numeric():
        inc index
        argument &= "=" & arguments[index]
    of "--play":
      if index + 1 < arguments.len and
        arguments[index + 1].strip().toLowerAscii() in
          ["true", "false", "yes", "no", "on", "off", "0", "1"]:
            inc index
            argument &= "=" & arguments[index]
    else:
      discard
    if argument.startsWith("--bot=") and
      not argument[6 .. ^1].legacyBot():
        argument = "--bot:" & argument[6 .. ^1]
    if argument.startsWith("--players:"):
      argument = "--players=" & argument[10 .. ^1]
    result.add(argument)
    inc index

proc validateBotSpec(specification: string) =
  ## Bounds bot expansion before the shared parser converts its count.
  if specification.len == 0:
    failOption("--bot requires a path.")
  let separator = specification.rfind(':')
  if separator < 0 or separator >= specification.high:
    return
  let suffix = specification[separator + 1 .. ^1]
  if suffix[0] == '-' and suffix[1 .. ^1].numeric():
    failOption("--bot count must be between 1 and " & $MaxPlayers & ".")
  if suffix.numeric():
    if separator == 0:
      failOption("--bot requires a path.")
    discard boundedNumber(suffix, "Bot count", 1, MaxPlayers)

proc commonFlag(options: var GameOptions, argument: string): bool =
  ## Uses Polyworld's parser after adapting retained equals-path aliases.
  var
    arguments = @[argument]
    index = 0
  let
    separator = argument.find({':', '='})
    name = if separator < 0: argument else: argument[0 ..< separator]
    value = if separator < 0: "" else: argument[separator + 1 .. ^1]
  try:
    if options.capture.takeCaptureFlag(arguments, index, argument):
      return true
  except ScreenshotError as error:
    failOption(error.msg)
  case name
  of "--player":
    if options.playerSlot != 0:
      failOption("Only one --player is allowed.")
    if separator >= 0:
      discard boundedNumber(value, name, 1, MaxPlayers)
  of "--play", "--vsync":
    if value.strip().toLowerAscii() notin
      ["true", "false", "1", "0", "yes", "no", "on", "off"]:
        failOption(name & " must be true or false.")
  of "--speed":
    discard boundedNumber(value, name, 1, int32.high.int)
  of "--headless-tick-rate":
    discard boundedNumber(value, name, 0, 10000)
  of "--llm-mode":
    if value.toLowerAscii() notin ["async", "barrier"]:
      failOption("--llm-mode must be async or barrier.")
  of "--windowSize":
    let dimensions = value.toLowerAscii().split('x')
    if dimensions.len != 2:
      failOption("--windowSize must look like 800x400.")
    for dimension in dimensions:
      discard boundedNumber(dimension, name, 1, 7680)
  else:
    discard
  for name in ["--replay", "--record"]:
    if argument.startsWith(name & "="):
      arguments = @[name, argument[name.len + 1 .. ^1]]
      if arguments[1].len == 0:
        failOption(name & " requires a path.")
      break
  options.takeCommonFlag(arguments, index, arguments[0])

proc duration(settings: var Settings, argument: string) =
  ## Converts real seconds and minutes at the game's two simulation ticks.
  let
    separator = argument.find('=')
    name = argument[0 ..< separator]
    count = boundedNumber(argument[separator + 1 .. ^1], name, 1, 100_000)
    scale =
      case name
      of "--seconds": 2
      of "--minutes": 120
      else: 1
    ticks = count * scale
  if ticks > 100_000:
    failOption("Duration must be between 1 and 100000 ticks.")
  discard settings.applySetting("--turns=" & $ticks)

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
    failOption("Choose grouped --bot paths or per-seat --bot=SEAT:PATH.")
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
  try:
    options.game.capture.validateCapture(
      graphical = not options.headless and not defined(emscripten)
    )
  except ScreenshotError as error:
    failOption(error.msg)
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
  discard options.settings.resolvedRoster()
  # Generals uses the full settings seed, not the shared CLI's signed field.
  options.game.seed =
    if options.settings.config.seed <= int32.high.uint64:
      options.settings.config.seed.int32
    else:
      0
  options.game.maximumTicks = options.settings.config.maxTurns.int32
  options.game.seconds = options.game.maximumTicks div 2

proc parseOptions*(arguments: seq[string]): Options =
  ## Parses shared Polyworld flags and the game's existing CLI aliases.
  result.settings = defaultSettings()
  result.game = GameOptions(
    seed: 1,
    maximumTicks: result.settings.config.maxTurns.int32,
    seconds: result.settings.config.maxTurns.int32 div 2,
    speed: 1,
    windowWidth: 1280,
    windowHeight: 900
  )
  result.headless = defined(headless)
  result.humanPlayer = if result.headless: -1 else: 0
  if "--help" in arguments or "-h" in arguments:
    result.showHelp = true
    return
  let canonical = canonicalArguments(arguments)
  result.settings = configuredSettings(canonical)
  var
    explicitCount = false
    seatBots = false
  for argument in canonical:
    if argument.startsWith("--config=") or
      argument.startsWith("--players="):
        explicitCount = true
    if argument.startsWith("--bot="):
      seatBots = true
    if result.settings.applySetting(argument):
      discard
    elif argument in ["--headless", "--start", "--play"]:
      result.startGame = true
      if argument == "--headless":
        result.headless = true
    elif argument.startsWith("--ticks=") or
      argument.startsWith("--seconds=") or
      argument.startsWith("--minutes="):
        result.settings.duration(argument)
    elif argument.startsWith("--at="):
      result.autoTurns = boundedNumber(
        argument[5 .. ^1], "Starting tick", 0, 100_000
      )
    elif argument.startsWith("--assets="):
      result.assets = argument[9 .. ^1]
      if result.assets.len == 0:
        failOption("--assets requires a path.")
    elif argument.startsWith("--size="):
      discard result.game.commonFlag("--windowSize=" & argument[7 .. ^1])
    else:
      if argument.startsWith("--bot:"):
        validateBotSpec(argument[6 .. ^1])
      if not result.game.commonFlag(argument):
        failOption("Unknown argument: " & argument)
  if result.game.speed notin [1'i32, 2, 4, 16]:
    failOption("--speed must be 1, 2, 4, or 16.")
  if result.game.windowWidth notin 1'i32 .. 7680'i32 or
    result.game.windowHeight notin 1'i32 .. 7680'i32:
      failOption("Window dimensions must be between 1 and 7680.")
  result.resolve(explicitCount, seatBots)
