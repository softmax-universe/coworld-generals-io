import
  std/[os, unicode],
  flatty, polyworld/[hashes, tapes],
  common, events, players, worlds

when defined(softmaxReplay):
  import std/[json, strutils]
  import polyworld_hosted

export tapes

const
  ReplayGame* = (when defined(softmaxReplay): "generals_hosted" else: "generals")
  ReplayFormatVersion* = 5'u16
  ReplayGameVersion* = (when defined(softmaxReplay): 3'u16 else: 6'u16)
  ReplayMapVersion* = 3'u16
  MaxReplayTicks* = 100_000
  MaxReplayActions* = MaxReplayTicks * MaxPlayers + 16_384
  MaxReplayChats* = 16_384
  MaxReplayBytes* = 64 * 1024 * 1024
  HalfFlag = 1'u32
  RawFlag = 2'u32
  BuildFlag = 4'u32
  SourceMask = 0xfff'u32
  MaximumTickDelta = 0x1fff'u32
  ExtendedAction = uint32.high
  ExtendedWords = 9
  ChatWord = uint32.high - 1
  ChatWords = 4

type
  ReplaySetup* = object
    mapVersion*: uint16
    mapHash*: uint64
    maximumTicks*: uint32
    roster*: Roster
    when defined(softmaxReplay):
      hostedTicks*: seq[seq[HostedEvent]]
      building*: bool
      outcome*: string
      skillScores*: seq[string]
      skillLabel*: string
  ReplayActionKind* = enum
    MoveAction, ChatAction
  ReplayAction* = object
    kind*: ReplayActionKind
    text*: string
    tick*, player*, flags*: uint32
    source*, target*, row*, column*, direction*: int32
  ReplayChat* = object
    tick*: uint32
    player*: int32
    text*: string
  ReplayData* = ActionTape[ReplaySetup, ReplayAction, void, Config]
  ReplayRecorder* = ref object
    data*: ReplayData
    chatCount: int
  ReplayPlayer* = TapePlayer[ReplaySetup, ReplayAction, void, Config]
  PackedData = ActionTape[ReplaySetup, uint32, void, Config]

proc fail(message: string) {.noreturn, raises: [GeneralsError].} =
  ## Raises an error at the Generals replay boundary.
  raise newException(GeneralsError, "Replay: " & message)

proc stateHash*(world: World): uint64 {.raises: [].} =
  ## Hashes every authoritative field with portable Polyworld hashing.
  uint64(hashy(world))

proc initialWorld(
    config: Config,
    mapVersion = ReplayMapVersion
): World {.raises: [GeneralsError].} =
  ## Rebuilds the recorded generator with portable native integer fields.
  if mapVersion != ReplayMapVersion:
    fail("unsupported map generation version " & $mapVersion)
  newWorld(config)

proc recordedRoster(roster: Roster, count: int): Roster {.
    raises: [GeneralsError].} =
  ## Preserves resolved public labels and fills only unnamed active seats.
  roster.validateRoster(count)
  result = defaultRoster()
  result.exposePlayerInfo = roster.exposePlayerInfo
  for player in 0 ..< count:
    result.players[player] = PlayerInfo(
      name: roster.displayName(player),
      mmr: roster.players[player].mmr
    )

proc validateAction(action: ReplayAction, players: int) {.
    raises: [GeneralsError].} =
  ## Checks command metadata without rejecting ordinary illegal moves.
  if action.player >= uint32(players):
    fail("action references an unknown player")
  if action.kind == ChatAction:
    if action.flags != 0 or action.source != 0 or action.target != 0 or
      action.row != 0 or action.column != 0 or action.direction != 0:
        fail("chat contains move fields")
    return
  if action.text.len > 0:
    fail("move contains chat text")
  if action.flags > HalfFlag + RawFlag and
      not (defined(softmaxReplay) and action.flags == BuildFlag):
    fail("action contains unsupported move flags")
  if (action.flags and RawFlag) != 0 and action.direction in 0 .. 3:
    if action.row in [int32.low, int32.high] or
      action.column in [int32.low, int32.high]:
        fail("raw action coordinates exceed the portable range")

proc actionMove(action: ReplayAction): Move {.raises: [].} =
  ## Restores all submitted move fields, including rejected commands.
  Move(
    source: int(action.source),
    target: int(action.target),
    half: (action.flags and HalfFlag) != 0,
    raw: (action.flags and RawFlag) != 0,
    row: int(action.row),
    column: int(action.column),
    direction: int(action.direction)
  )

proc replayAction(move: Move, tick, player: int): ReplayAction {.
    raises: [GeneralsError].} =
  ## Converts the runtime command to fixed-width, padding-free tape fields.
  let values = [move.source, move.target, move.row, move.column, move.direction]
  for value in values:
    if value < int32.low.int or value > int32.high.int:
      fail("move field exceeds the portable signed 32-bit range")
  result = ReplayAction(
    tick: uint32(tick),
    player: uint32(player),
    source: int32(move.source),
    target: int32(move.target),
    row: int32(move.row),
    column: int32(move.column),
    direction: int32(move.direction)
  )
  if move.half:
    result.flags = result.flags or HalfFlag
  if move.raw:
    result.flags = result.flags or RawFlag

proc validateChat(chat: ReplayChat, count, duration: int) {.
    raises: [GeneralsError].} =
  ## Checks accepted public chat without modifying its text or timestamp.
  if chat.player < 0 or chat.player >= count:
    fail("chat references an unknown player")
  if chat.tick > uint32(duration):
    fail("chat is outside the recorded duration")
  if chat.text.len == 0 or chat.text.len > MaxChatCharacters * 4 or
    not chat.text.validUtf8():
      fail("chat must contain bounded, valid UTF-8 text")
  var
    characters = 0
    space = true
  for rune in chat.text.runes:
    if rune.int < 32 or rune.int in 127 .. 159:
      fail("chat contains control characters")
    if rune.isWhiteSpace:
      if rune.int != 32 or space:
        fail("chat whitespace must already be normalized")
      space = true
    else:
      space = false
    inc characters
    if characters > MaxChatCharacters:
      fail("chat exceeds the character limit")
  if space:
    fail("chat text must already be normalized")

proc validate(data: ReplayData): World {.raises: [GeneralsError].} =
  ## Validates the versioned setup and bounded, ordered action stream.
  if data.config.width notin 13 .. 61 or data.config.height notin 13 .. 61:
    fail("recording requires explicit generated board dimensions")
  try:
    data.header.requireTapeVersion(ReplayFormatVersion, ReplayGameVersion)
  except ReplayError as error:
    fail(error.msg)
  if data.header.setup.mapVersion != ReplayMapVersion:
    fail("unsupported map generation version " & $data.header.setup.mapVersion)
  when defined(softmaxReplay):
    let setup = data.header.setup
    if data.config.players notin 2 .. 8 or data.hashes.len > 50_002 or
        setup.hostedTicks.len != data.hashes.len + 1 or
        setup.skillScores.len != data.config.players or
        (setup.building and data.config.players != 2):
      fail("hosted recording exceeds duration or player limits")
    result = newHostedWorld(data.config.seed, data.config.players, setup.building)
    if result.config != data.config:
      fail("hosted configuration does not match its generated map")
    for tick, commands in setup.hostedTicks:
      if commands.len > 40:
        fail("hosted tick has an invalid command count")
      var steps = 0
      for command in commands:
        if command.kind == StepEvent:
          inc steps
          if command.slots != 0:
            fail("step command contains player flags")
        elif command.slots == 0 or int(command.slots) shr data.config.players != 0:
          fail("hosted command references an unknown player")
      if steps != (if tick == 0: 0 else: 1):
        fail("hosted recording requires exactly one step per tick")
    for command in setup.hostedTicks[0]:
      discard result.applyHostedEvent(command, [], setup.building)
  else:
    result = initialWorld(data.config, data.header.setup.mapVersion)
  data.header.setup.roster.validateRoster(data.config.players)
  if data.header.setup.maximumTicks != uint32(data.config.maxTurns):
    fail("configuration and setup have different turn limits")
  let fingerprint =
    when defined(softmaxReplay): result.hostedHashValue()
    else: result.stateHash()
  if data.header.setup.mapHash != fingerprint:
    fail("generated map does not match its recorded fingerprint")
  if data.hashes.len > data.config.maxTurns:
    fail("hashes exceed the configured duration")
  if data.actions.len > MaxReplayActions:
    fail("action count exceeds the recording limit")
  var
    lastTick = 0'u32
    players = 0'u32
    chatCount = 0
    chatStarted = false
  for action in data.actions:
    action.validateAction(data.config.players)
    if action.tick < lastTick or action.tick > uint32(data.hashes.len):
      fail("action is outside the ordered recording")
    if action.tick != lastTick:
      players = 0
      chatStarted = false
    if action.kind == ChatAction:
      ReplayChat(tick: action.tick, player: int32(action.player),
        text: action.text).validateChat(data.config.players, data.hashes.len)
      inc chatCount
      if chatCount > MaxReplayChats:
        fail("public chat exceeds the recording limit")
      chatStarted = true
    else:
      if action.tick == 0 or chatStarted:
        fail("moves must precede admitted chat in each completed tick")
      when defined(softmaxReplay):
        if action.flags == BuildFlag and (not data.header.setup.building or
            action.row notin 0 ..< data.config.height or
            action.column notin 0 ..< data.config.width):
          fail("construction command is outside the building game")
      let mask = 1'u32 shl action.player
      if (players and mask) != 0:
        fail("player has multiple commands in one tick")
      players = players or mask
    lastTick = action.tick

proc newReplayRecorder*(
    world: World,
    roster = defaultRoster()
): ReplayRecorder {.raises: [GeneralsError].} =
  ## Starts an action-only recording from an unchanged generated match.
  if world.turn != 0 or world != initialWorld(world.config):
    fail("recording must start from the generated world at turn zero")
  new(result)
  result.data.header = TapeHeader[ReplaySetup](
    formatVersion: ReplayFormatVersion,
    gameVersion: ReplayGameVersion,
    setup: ReplaySetup(
      mapVersion: ReplayMapVersion,
      mapHash: world.stateHash(),
      maximumTicks: uint32(world.config.maxTurns),
      roster: recordedRoster(roster, world.config.players)
    )
  )
  result.data.config = world.config

proc recordTick*(
    recorder: ReplayRecorder,
    worldAfter: World,
    moves: openArray[Move]
) {.raises: [GeneralsError].} =
  ## Records submitted commands and the resulting authoritative tick hash.
  if recorder == nil:
    return
  if worldAfter.config != recorder.data.config:
    fail("world configuration changed during recording")
  if moves.len != worldAfter.config.players:
    fail("recording requires one move for every player")
  if worldAfter.turn != recorder.data.hashes.len + 1 or
    worldAfter.turn > worldAfter.config.maxTurns:
      fail("recording requires the next completed simulation tick")
  var
    actions: array[MaxPlayers, ReplayAction]
    count = 0
  for player, move in moves:
    if move == noMove():
      continue
    let action = replayAction(move, worldAfter.turn, player)
    action.validateAction(worldAfter.config.players)
    actions[count] = action
    inc count
  if recorder.data.actions.len + count > MaxReplayActions:
    fail("action limit exceeded")
  try:
    for i in 0 ..< count:
      recorder.data.actions.appendAction(actions[i], MaxReplayActions)
    recorder.data.hashes.appendHash(
      worldAfter.stateHash(),
      recorder.data.header.setup.maximumTicks,
      MaxReplayTicks
    )
  except ReplayError as error:
    fail(error.msg)

proc recordChat*(
    recorder: ReplayRecorder,
    player, turn: int,
    text: string
): bool {.raises: [GeneralsError].} =
  ## Keeps the first bounded public chat history without interrupting play.
  if recorder == nil:
    return false
  if player < 0 or player >= recorder.data.config.players or
    turn < 0 or turn > recorder.data.hashes.len:
      fail("chat player or turn is outside the recorded match")
  let chat = ReplayChat(tick: uint32(turn), player: int32(player), text: text)
  chat.validateChat(recorder.data.config.players, recorder.data.hashes.len)
  if recorder.data.actions.len > 0 and
    chat.tick < recorder.data.actions[^1].tick:
      fail("chat messages move backward in time")
  if recorder.chatCount >= MaxReplayChats:
    return false
  recorder.data.actions.add ReplayAction(kind: ChatAction, tick: chat.tick,
    player: uint32(player), text: text)
  inc recorder.chatCount
  true

proc newReplayWorld*(data: ReplayData): World =
  ## Regenerates and verifies the initial world without running any bots.
  result = data.validate()

proc newReplayPlayer*(data: ReplayData): ReplayPlayer =
  ## Creates a shared Polyworld cursor over a validated Generals tape.
  when defined(softmaxReplay):
    discard data.newReplayWorld()
  else:
    discard data.validate()
  initTapePlayer(data)

proc replayChatsAt(player: ReplayPlayer, tick: uint32, log: var MatchLog) =
  ## Dispatches admitted chat through the same cursor as game commands.
  var action: ReplayAction
  try:
    while player.takeActionAt(tick, action):
      if action.kind != ChatAction:
        fail("unexpected move after the completed tick")
      discard log.addChat(int(action.player), int(action.tick), action.text)
  except ReplayError as error:
    fail(error.msg)

proc replayInitial*(player: ReplayPlayer, log: var MatchLog) =
  ## Restores chat admitted before the first simulation tick.
  if player != nil:
    player.replayChatsAt(0, log)

proc replayTick*(
    player: ReplayPlayer,
    world: var World,
    moves: var array[MaxPlayers, Move],
    log: var MatchLog
): bool =
  ## Applies the next recorded tick and rejects any simulation divergence.
  for move in moves.mitems:
    move = noMove()
  if player == nil:
    return false
  if world.config != player.data.config or world.turn < 0:
    fail("playback world does not match the recorded configuration")
  if world.turn > player.data.hashes.len:
    fail("playback world is past the recorded duration")
  if world.turn == 0:
    player.replayInitial(log)
  if world.turn == player.data.hashes.len:
    return false
  when not defined(softmaxReplay):
    if world.finished:
      fail("simulation ended before the recorded duration")
  let
    tick = uint32(world.turn + 1)
    before = snapshotEvents(world)
  when defined(softmaxReplay):
    var actions = newSeq[HostedAction](world.config.players)
    for action in actions.mitems:
      action[0] = 1
    var recorded: ReplayAction
    while player.actionIndex < player.data.actions.len and
      player.data.actions[player.actionIndex].kind == MoveAction:
      if not player.takeActionAt(tick, recorded):
        break
      let slot = int(recorded.player)
      if recorded.flags == BuildFlag:
        actions[slot] = [2'i32, recorded.row, recorded.column, 0, 0]
      else:
        let move = recorded.actionMove()
        moves[slot] = move
        var row, column, direction: int
        if move.raw:
          row = move.row
          column = move.column
          direction = move.direction
        else:
          row = move.source div world.config.width
          column = move.source mod world.config.width
          let delta = move.target - move.source
          direction = if delta == -world.config.width: 0
            elif delta == world.config.width: 1
            elif delta == -1: 2 else: 3
        actions[slot] = [0'i32, row.int32, column.int32, direction.int32, move.half.int32]
    for event in player.data.header.setup.hostedTicks[int(tick)]:
      discard world.applyHostedEvent(event, actions, player.data.header.setup.building)
    if world.turn != int(tick) or world.hostedHashValue() != player.data.hashes[int(tick) - 1]:
      fail("hosted simulation diverged at tick " & $tick)
    result = true
  else:
    var
      action: ReplayAction
      players = 0'u32
    try:
      while player.actionIndex < player.data.actions.len and
        player.data.actions[player.actionIndex].kind == MoveAction:
        if not player.takeActionAt(tick, action):
          break
        action.validateAction(world.config.players)
        let mask = 1'u32 shl action.player
        if (players and mask) != 0:
          fail("player has multiple commands in one tick")
        players = players or mask
        moves[int(action.player)] = action.actionMove()
    except ReplayError as error:
      fail(error.msg)
    world.tick(moves.toOpenArray(0, world.config.players - 1))
    if world.turn != int(tick) or
      world.stateHash() != player.data.hashes[int(tick) - 1]:
        fail("simulation diverged at tick " & $tick)
    result = true
  log.recordTick(before, world, moves.toOpenArray(0, world.config.players - 1))
  player.replayChatsAt(tick, log)

proc replayTick*(
    player: ReplayPlayer,
    world: var World,
    moves: var array[MaxPlayers, Move]
): bool =
  ## Verifies one tick when callers do not need the derived event transcript.
  var log: MatchLog
  player.replayTick(world, moves, log)

proc packedAction(
    action: ReplayAction,
    previous: uint32,
    config: Config
): uint32 {.raises: [].} =
  ## Packs ordinary cardinal commands into one word or requests an escape.
  if action.kind != MoveAction or
    action.flags > HalfFlag or action.row != 0 or
    action.column != 0 or action.direction != 0 or
    action.tick < previous or action.tick - previous > MaximumTickDelta or
    action.source < 0 or action.target < 0 or
    action.source >= int32(config.width * config.height) or
    action.target >= int32(config.width * config.height):
      return ExtendedAction
  let
    source = action.source.int
    target = action.target.int
    width = config.width
  var direction: uint32
  if target == source - width:
    direction = 0
  elif target == source + width:
    direction = 1
  elif target == source - 1 and source mod width > 0:
    direction = 2
  elif target == source + 1 and source mod width < width - 1:
    direction = 3
  else:
    return ExtendedAction
  uint32(source) or (direction shl 12) or (action.flags shl 14) or
    (action.player shl 15) or ((action.tick - previous) shl 19)

proc packActions(data: ReplayData): seq[uint32] {.raises: [].} =
  ## Stores four-byte common orders and exact escapes for unusual commands.
  result = newSeqOfCap[uint32](data.actions.len)
  var previous = 0'u32
  for action in data.actions:
    if action.kind == ChatAction:
      result.add([ChatWord, action.tick, action.player, uint32(action.text.len)])
      for start in countup(0, action.text.len - 1, 4):
        var word = 0'u32
        for offset in 0 ..< min(4, action.text.len - start):
          word = word or (uint32(action.text[start + offset].ord) shl (offset * 8))
        result.add(word)
    else:
      let packed = packedAction(action, previous, data.config)
      result.add(packed)
      if packed == ExtendedAction:
        result.add([
          action.tick, action.player, action.flags,
          cast[uint32](action.source), cast[uint32](action.target),
          cast[uint32](action.row), cast[uint32](action.column),
          cast[uint32](action.direction)
        ])
    previous = action.tick

proc unpackActions(
    words: seq[uint32],
    config: Config,
    ticks: int
): seq[ReplayAction] {.raises: [GeneralsError].} =
  ## Bounds decoded command storage before expanding the packed word stream.
  if config.width notin 13 .. 61 or config.height notin 13 .. 61 or
    config.players notin 2 .. MaxPlayers or
    config.maxTurns notin 1 .. MaxReplayTicks or ticks > config.maxTurns:
      fail("packed commands require bounded board dimensions and duration")
  let limit = ticks * config.players + MaxReplayChats
  if words.len > ticks * config.players * ExtendedWords +
    MaxReplayChats * (ChatWords + MaxChatCharacters):
    fail("packed action words exceed the recorded duration")
  var
    position = 0
    count = 0
  while position < words.len:
    var span = if words[position] == ExtendedAction: ExtendedWords else: 1
    if words[position] == ChatWord:
      if words.len - position < ChatWords:
        fail("chat command header is truncated")
      let size = words[position + 3]
      if size == 0 or size > uint32(MaxChatCharacters * 4):
        fail("decoded chat text exceeds the byte limit")
      span = ChatWords + (int(size) + 3) div 4
    if words.len - position < span:
      fail("extended command is truncated")
    inc count
    if count > limit:
      fail("decoded action count exceeds the recorded duration")
    position += span
  result = newSeq[ReplayAction](count)
  position = 0
  var previous = 0'u32
  for action in result.mitems:
    let packed = words[position]
    inc position
    if packed == ChatWord:
      let size = int(words[position + 2])
      action = ReplayAction(kind: ChatAction, tick: words[position],
        player: words[position + 1], text: newString(size))
      position += ChatWords - 1
      for i in 0 ..< size:
        action.text[i] = char((words[position + i div 4] shr ((i mod 4) * 8)) and 255)
      position += (size + 3) div 4
    elif packed == ExtendedAction:
      action = ReplayAction(
        tick: words[position],
        player: words[position + 1],
        flags: words[position + 2],
        source: cast[int32](words[position + 3]),
        target: cast[int32](words[position + 4]),
        row: cast[int32](words[position + 5]),
        column: cast[int32](words[position + 6]),
        direction: cast[int32](words[position + 7])
      )
      position += ExtendedWords - 1
    else:
      let
        tick = previous.uint64 + (packed shr 19).uint64
        source = int(packed and SourceMask)
        direction = (packed shr 12) and 3
        width = config.width
      if tick > ticks.uint64:
        fail("packed command exceeds the recorded duration")
      if source >= width * config.height:
        fail("packed command source is outside the board")
      let target =
        case direction
        of 0:
          source - width
        of 1:
          source + width
        of 2:
          source - 1
        else:
          source + 1
      if target < 0 or target >= width * config.height or
        (direction == 2 and source mod width == 0) or
        (direction == 3 and source mod width == width - 1):
          fail("packed command target is outside the board")
      action = ReplayAction(
        tick: tick.uint32,
        player: (packed shr 15) and 15,
        flags: (packed shr 14) and HalfFlag,
        source: source.int32,
        target: target.int32
      )
    if (action.kind == MoveAction and action.tick == 0) or
      action.tick < previous or action.tick > ticks.uint32:
        fail("packed command tick is outside the ordered recording")
    action.validateAction(config.players)
    previous = action.tick

proc encodeReplay*(data: ReplayData): string {.raises: [GeneralsError].} =
  ## Encodes the current Polyworld tape with compact command words.
  discard data.validate()
  let packed = PackedData(
    header: data.header,
    config: data.config,
    actions: data.packActions(),
    hashes: data.hashes
  )
  try:
    result = encodeReplayFile(
      ReplayGame,
      ReplayGameVersion,
      packed,
      MaxReplayBytes
    )
  except ReplayError as error:
    fail(error.msg)

proc decodeReplay*(bytes: string): ReplayData {.raises: [GeneralsError].} =
  ## Reads only this game's replay version with bounded command expansion.
  try:
    let packed = decodeReplayFile(
      ReplayGame,
      ReplayGameVersion,
      bytes,
      PackedData,
      MaxReplayBytes
    )
    packed.header.requireTapeVersion(ReplayFormatVersion, ReplayGameVersion)
    result = ReplayData(
      header: packed.header,
      config: packed.config,
      actions: unpackActions(packed.actions, packed.config, packed.hashes.len),
      hashes: packed.hashes
    )
    discard result.validate()
    if result.packActions() != packed.actions:
      fail("recording has noncanonical command words")
    if encodeReplayFile(
      ReplayGame,
      ReplayGameVersion,
      packed,
      MaxReplayBytes
    ) != bytes:
      fail("recording has trailing or noncanonical bytes")
  except ReplayError, FlattyError, ValueError, IndexDefect, RangeDefect:
    fail("cannot decode recording: " & getCurrentExceptionMsg())

proc saveReplay*(path: string, data: ReplayData) {.
    raises: [GeneralsError].} =
  ## Saves a validated tape using the shared Polyworld file format.
  if path.len == 0:
    fail("output path is empty")
  let bytes = data.encodeReplay()
  try:
    let directory = path.parentDir
    if directory.len > 0:
      createDir(directory)
    writeFile(path, bytes)
  except IOError, OSError:
    fail("cannot save recording: " & getCurrentExceptionMsg())

proc loadReplay*(path: string): ReplayData =
  ## Checks the file size before reading and decoding the recording.
  if path.len == 0:
    fail("input path is empty")
  try:
    if getFileSize(path) > MaxReplayBytes:
      fail("recording exceeds the file size limit")
    result = decodeReplay(readFile(path))
    when defined(softmaxReplay):
      if fileExists("/player-ratings.json"):
        let metadata = parseJson(readFile("/player-ratings.json"))
        result.header.setup.skillLabel = "Current " & metadata["league"].getStr() &
          " " & metadata["label"].getStr() & ". — = unrated."
        var seen: set[0 .. 7]
        for player in metadata["players"].getElems():
          let slot = player["slot"].getInt()
          if slot notin 0 ..< result.config.players or slot in seen:
            fail("invalid leaderboard player slot")
          seen.incl(slot)
          result.header.setup.skillScores[slot] =
            if player["score"].kind == JNull: "—"
            else: formatFloat(player["score"].getFloat(), ffDecimal, 1)
  except IOError, OSError:
    fail("cannot load recording: " & getCurrentExceptionMsg())

when defined(softmaxReplay):
  proc encodeHostedReplay*(payload: JsonNode): string =
    ## Converts the process command log into upstream's packed action tape.
    if payload["format"].getStr() != "polyworld-generals-hosted" or
      payload["version"].getInt() != 2 or payload.hasKey("chats"):
        fail("unsupported hosted command stream format")
    let ticks = payload["ticks"]
    let initial = ticks[0][0]["command"]
    var data: ReplayData
    data.header = TapeHeader[ReplaySetup](
      formatVersion: ReplayFormatVersion, gameVersion: ReplayGameVersion,
      setup: ReplaySetup(mapVersion: ReplayMapVersion,
        maximumTicks: 100_000, roster: defaultRoster(),
        building: initial["ruleset"].getStr() == "build_castles"))
    let world = newHostedWorld(
      parseSeed(initial["seed"].getStr()),
      initial["players"].getInt(), data.header.setup.building)
    data.config = world.config
    for slot, name in payload["players"].getElems():
      data.header.setup.roster.players[slot].name = name.getStr()
      let score = payload["skill_scores"][slot]
      data.header.setup.skillScores.add(
        if score.kind == JNull: "—" else: formatFloat(score.getFloat(), ffDecimal, 1))
    data.header.setup.skillLabel = payload["skill_label"].getStr()
    let winner = payload["result"]["winner"].getInt()
    data.header.setup.outcome = "Result: " &
      (if winner < 0: "draw" else: data.header.setup.roster.displayName(winner) & " won") &
      " (" & payload["result"]["reason"].getStr().replace('_', ' ') & ")."
    for tick, events in ticks.getElems():
      var commands: seq[HostedEvent]
      for index, event in events.getElems():
        let command = event["command"]
        case command["op"].getStr()
        of "new":
          if tick != 0 or index != 0:
            fail("hosted recording must initialize exactly once")
        of "step":
          commands.add HostedEvent(kind: StepEvent)
          for slot, fields in command["actions"].getElems():
            case fields[0].getInt()
            of 0:
              var move = actionMove(fields[1].getInt(), fields[2].getInt(),
                fields[3].getInt(), fields[4].getInt() == 1)
              let source = move.row * data.config.width + move.column
              let delta = [-data.config.width, data.config.width, -1, 1][move.direction]
              let target = source + delta
              if move.row in 0 ..< data.config.height and
                  move.column in 0 ..< data.config.width and
                  target in 0 ..< data.config.width * data.config.height and
                  (move.direction != 2 or move.column > 0) and
                  (move.direction != 3 or move.column < data.config.width - 1):
                move = Move(source: source, target: target, half: move.half)
              data.actions.add replayAction(move, tick, slot)
            of 2:
              data.actions.add ReplayAction(tick: tick.uint32, player: slot.uint32,
                flags: BuildFlag, row: fields[1].getInt().int32,
                column: fields[2].getInt().int32)
            else:
              discard
        of "chat":
          if command["tick"].getInt() != tick:
            fail("hosted chat does not match its admitted tick")
          data.actions.add ReplayAction(kind: ChatAction, tick: tick.uint32,
            player: command["player"].getInt().uint32,
            text: command["text"].getStr())
        of "surrender", "neutralize":
          var recorded = HostedEvent(kind:
            if command["op"].getStr() == "surrender": SurrenderEvent else: NeutralizeEvent)
          for slot in command["slots"]:
            recorded.slots = recorded.slots or (1'u8 shl slot.getInt())
          commands.add(recorded)
        else:
          fail("unknown hosted recording command")
      data.header.setup.hostedTicks.add(commands)
      let fingerprint = cast[uint64](events[^1]["hash"].getStr().parseHexInt())
      if tick == 0:
        data.header.setup.mapHash = fingerprint
      else:
        data.hashes.add(fingerprint)
    data.encodeReplay()
