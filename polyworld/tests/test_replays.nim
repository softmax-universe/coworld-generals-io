import
  std/[os, strutils],
  flatty,
  ../src/generals/[bots, common, events, players, replays, worlds]

type CompactTestData = ActionTape[
  ReplaySetup, uint32, void, Config
]

template expectReplayError(body: untyped) =
  ## Requires malformed input to fail at the Generals error boundary.
  block:
    var failed = false
    try:
      body
    except GeneralsError:
      failed = true
    doAssert failed, "Expected a Generals replay error"

proc fixture(players, ticks: int): ReplayData =
  ## Creates bounded codec metadata with placeholder hashes, not a game run.
  var config = defaultConfig(7, players)
  config.maxTurns = max(1, ticks)
  result = newReplayRecorder(newWorld(config)).data
  result.hashes = newSeq[uint64](ticks)

proc compact(data: ReplayData): CompactTestData =
  ## Reads the serialized action words independently of the runtime decoder.
  decodeReplayFile(
    ReplayGame,
    ReplayGameVersion,
    data.encodeReplay(),
    CompactTestData
  )

proc encoded(data: CompactTestData): string =
  ## Encodes wire fixtures without validating their intentionally bad words.
  encodeReplayFile(ReplayGame, ReplayGameVersion, data)

proc snapshot(world: World): World =
  ## Copies every sequence so expected states cannot share live mutations.
  result = World(
    config: world.config,
    turn: world.turn,
    winner: world.winner,
    finished: world.finished,
    tiles: newSeq[Tile](world.tiles.len),
    generals: newSeq[int](world.generals.len),
    alive: newSeq[bool](world.alive.len)
  )
  for i, tile in world.tiles:
    result.tiles[i] = tile
  for i, general in world.generals:
    result.generals[i] = general
  for i, alive in world.alive:
    result.alive[i] = alive

proc rawMove(world: World, move: Move): Move =
  ## Expresses an adjacent bot command using the reference action geometry.
  let delta = move.target - move.source
  var direction = -1
  if delta == -world.config.width:
    direction = 0
  elif delta == world.config.width:
    direction = 1
  elif delta == -1:
    direction = 2
  elif delta == 1:
    direction = 3
  doAssert direction >= 0
  actionMove(
    move.source div world.config.width,
    move.source mod world.config.width,
    direction,
    move.half
  )

proc recordedMatch(players: int): tuple[data: ReplayData, states: seq[World]] =
  ## Records real bot games with raw, half, rejected, and passing commands.
  var config = defaultConfig(7, players)
  config.maxTurns = 2000
  var
    world = newWorld(config)
    moves = newSeq[Move](players)
    scratch: BotScratch
  let recorder = newReplayRecorder(world)
  result.states.add(world.snapshot())
  while not world.finished:
    for player in 0 ..< players:
      moves[player] = chooseMove(world, player, scratch)
      if moves[player] != noMove() and world.turn mod 7 == 0:
        moves[player] = rawMove(world, moves[player])
      if moves[player] != noMove() and world.turn mod 11 == 0:
        moves[player].half = true
    case world.turn
    of 0:
      moves[0] = actionMove(2, 2, 3, true)
      moves[1] = Move(source: -1, target: -1, half: true)
    of 1:
      moves[0] = Move(
        source: -7,
        target: 99,
        raw: true,
        row: 2,
        column: 2,
        direction: 9
      )
      moves[1] = actionMove(-3, -9, 0, true)
    of 2:
      moves[0] = Move(source: 0, target: world.tiles.len + 3)
    else:
      discard
    world.tick(moves)
    recorder.recordTick(world, moves)
    result.states.add(world.snapshot())
  result.data = recorder.data
  doAssert result.data.header.setup.maximumTicks == uint32(config.maxTurns)
  doAssert result.data.hashes.len == world.turn
  echo "Recorded ", players, " players, ", world.turn, " ticks, ",
    result.data.actions.len, " actions"

echo "Testing standard Polyworld action tapes and exact lockstep playback"
var
  sample: ReplayData
  conquests = 0
for players in [2, 4]:
  let
    recorded = recordedMatch(players)
    bytes = recorded.data.encodeReplay()
    header = bytes.replayFileHeader()
    data = bytes.decodeReplay()
    player = newReplayPlayer(data)
  var
    world = newReplayWorld(data)
    moves: array[MaxPlayers, Move]
  doAssert header.game == ReplayGame
  doAssert header.formatVersion == ReplayFileVersion
  doAssert header.gameVersion == ReplayGameVersion
  doAssert data == recorded.data
  doAssert world == recorded.states[0]
  while player.replayTick(world, moves):
    doAssert world == recorded.states[world.turn]
    doAssert world.stateHash() == data.hashes[world.turn - 1]
    if world.turn == 1:
      doAssert moves[0] == actionMove(2, 2, 3, true)
      doAssert moves[1] == Move(source: -1, target: -1, half: true)
    if world.turn == 2:
      doAssert moves[0].raw and moves[0].direction == 9
      doAssert moves[0].source == -7 and moves[0].target == 99
      doAssert moves[1] == actionMove(-3, -9, 0, true)
    for unused in players ..< MaxPlayers:
      doAssert moves[unused] == noMove()
  doAssert world == recorded.states[^1]
  doAssert world.finished
  doAssert not player.replayTick(world, moves)
  for alive in world.alive:
    if not alive:
      inc conquests

  # Restoring a historical world also restores the shared action cursor.
  let seekTurn = min(37, data.hashes.len)
  world = recorded.states[seekTurn].snapshot()
  player.syncCursor(uint32(seekTurn))
  while player.replayTick(world, moves):
    doAssert world == recorded.states[world.turn]
  doAssert world == recorded.states[^1]
  world = newReplayWorld(data)
  player.syncCursor(0)
  for tick in 1 .. seekTurn:
    doAssert player.replayTick(world, moves)
    doAssert world == recorded.states[tick]
  if players == 2:
    sample = data
doAssert conquests > 0, "Replays must cover actual general captures"

echo "Testing four-byte commands for every seat, direction, and half flag"
block:
  var data = fixture(MaxPlayers, 8)
  let
    source = data.config.width + 1
    offsets = [-data.config.width, data.config.width, -1, 1]
  for direction in 0 .. 3:
    for half in 0 .. 1:
      for player in 0 ..< MaxPlayers:
        data.actions.add(ReplayAction(
          tick: uint32(direction * 2 + half + 1),
          player: uint32(player),
          flags: uint32(half),
          source: int32(source),
          target: int32(source + offsets[direction])
        ))
  let wire = data.compact()
  doAssert wire.actions.len == 80
  doAssert wire.actions.toFlatty().len == 8 + 80 * 4
  doAssert wire.actions[0] == (uint32(source) or (1'u32 shl 19))
  doAssert wire.actions[9] == (uint32(source) or (9'u32 shl 15))
  doAssert wire.actions[^1] == (uint32(source) or
    (3'u32 shl 12) or (1'u32 shl 14) or (9'u32 shl 15))
  doAssert wire.encoded().decodeReplay() == data
  doAssert data.encodeReplay().len ==
    encodeReplayFile(ReplayGame, ReplayGameVersion, data).len -
      80 * (data.actions[0].toFlatty().len - 4)

echo "Testing the largest supported source cell and idle tick gaps"
block:
  var config = defaultConfig(9, MaxPlayers)
  config.width = 61
  config.height = 61
  config.maxTurns = 1
  var data = newReplayRecorder(newWorld(config)).data
  data.hashes = @[0'u64]
  data.actions = @[
    ReplayAction(tick: 1, player: 9, flags: 1, source: 3720, target: 3719)
  ]
  doAssert data.compact().actions.len == 1
  doAssert data.encodeReplay().decodeReplay() == data
  data = fixture(2, 16_384)
  let source = int32(data.config.width + 1)
  for tick in [1'u32, 8192'u32, 16_384'u32]:
    data.actions.add(ReplayAction(
      tick: tick,
      player: 0,
      source: source,
      target: source + 1
    ))
  let wire = data.compact()
  doAssert wire.actions.len == 11
  doAssert wire.actions[1] shr 19 == 8191
  doAssert wire.actions[2] == uint32.high
  doAssert wire.actions[3] == 16_384
  doAssert data.encodeReplay().decodeReplay() == data

echo "Testing exact escape records for raw and rejected commands"
block:
  var data = fixture(2, 4)
  let width = int32(data.config.width)
  data.actions = @[
    ReplayAction(
      tick: 1, player: 0, flags: 3,
      source: int32.low, target: int32.high,
      row: int32.low, column: int32.high, direction: 9
    ),
    ReplayAction(
      tick: 2, player: 1, source: width - 1, target: width
    ),
    ReplayAction(
      tick: 3, player: 0, source: width + 1, target: width + 2,
      row: 123, column: -123, direction: -1
    ),
    ReplayAction(tick: 4, player: 1, source: -1, target: -1, flags: 1)
  ]
  let wire = data.compact()
  doAssert wire.actions.len == 4 * 9
  for i in 0 ..< 4:
    doAssert wire.actions[i * 9] == uint32.high
  doAssert wire.actions[4] == cast[uint32](int32.low)
  doAssert wire.actions[5] == cast[uint32](int32.high)
  doAssert wire.encoded().decodeReplay() == data

echo "Testing malformed compact commands before action expansion"
block:
  var data = fixture(2, 2)
  let source = uint32(data.config.width + 1)
  data.actions = @[
    ReplayAction(tick: 1, player: 0, source: int32(source),
      target: int32(source + 1)),
    ReplayAction(tick: 2, player: 1, source: int32(source),
      target: int32(source + 1))
  ]
  let original = data.compact()
  for maximum in [0, MaxReplayTicks + 1, 1]:
    var bounded = original
    bounded.config.maxTurns = maximum
    bounded.header.setup.maximumTicks = uint32(maximum)
    var failure: string
    try:
      discard bounded.encoded().decodeReplay()
    except GeneralsError as error:
      failure = error.msg
    doAssert failure.contains(
      "packed commands require bounded board dimensions and duration"
    )
  for count in 1 .. 8:
    var malformed = original
    malformed.actions = @[uint32.high]
    malformed.actions.setLen(count)
    expectReplayError:
      discard malformed.encoded().decodeReplay()
  for word in [
    source or (3'u32 shl 12),
    source or (3'u32 shl 12) or (2'u32 shl 15) or (1'u32 shl 19),
    4095'u32 or (3'u32 shl 12) or (1'u32 shl 19),
    0'u32 or (1'u32 shl 19),
    uint32(data.config.width - 1) or (3'u32 shl 12) or (1'u32 shl 19)
  ]:
    var malformed = original
    malformed.actions = @[word]
    expectReplayError:
      discard malformed.encoded().decodeReplay()
  var malformed = original
  malformed.actions = @[
    original.actions[0], original.actions[0] and 0x7ffff'u32
  ]
  expectReplayError:
    discard malformed.encoded().decodeReplay()
  malformed = original
  malformed.actions = newSeq[uint32](5)
  expectReplayError:
    discard malformed.encoded().decodeReplay()
  # An otherwise ordinary command must not use a longer escape encoding.
  malformed = original
  malformed.actions = @[
    uint32.high, 1'u32, 0'u32, 0'u32,
    source, source + 1, 0'u32, 0'u32, 0'u32
  ]
  expectReplayError:
    discard malformed.encoded().decodeReplay()
  # An escaped absolute tick cannot evade the configured duration bound.
  malformed = original
  malformed.actions = @[
    uint32.high, uint32.high, 0'u32, 2'u32,
    0'u32, 0'u32, 0'u32, 0'u32, 9'u32
  ]
  expectReplayError:
    discard malformed.encoded().decodeReplay()

echo "Testing empty recordings and initial map isolation"
block:
  var world = newWorld(defaultConfig(2, 2))
  let
    initial = world.snapshot()
    recorder = newReplayRecorder(world)
    data = recorder.data.encodeReplay().decodeReplay()
    player = newReplayPlayer(data)
  var moves: array[MaxPlayers, Move]
  doAssert data.actions.len == 0 and data.hashes.len == 0
  doAssert not player.replayTick(world, moves)
  world.tiles[world.generals[0]].army += 100
  doAssert newReplayWorld(data) == initial
  expectReplayError:
    discard newReplayRecorder(world)
  world = initial.snapshot()
  world.tick([noMove(), noMove()])
  expectReplayError:
    discard newReplayRecorder(world)

echo "Testing pass omission, recording bounds, and atomic invalid commands"
block:
  var config = defaultConfig(5, 2)
  config.maxTurns = 2
  var world = newWorld(config)
  let recorder = newReplayRecorder(world)
  world.tick([noMove(), noMove()])
  expectReplayError:
    recorder.recordTick(world, [noMove()])
  doAssert recorder.data.hashes.len == 0
  recorder.recordTick(world, [noMove(), noMove()])
  doAssert recorder.data.actions.len == 0
  expectReplayError:
    recorder.recordTick(world, [noMove(), noMove()])
  world.tick([noMove(), noMove()])
  let invalid = Move(raw: true, row: int32.high.int, direction: 0)
  expectReplayError:
    recorder.recordTick(world, [invalid, noMove()])
  doAssert recorder.data.hashes.len == 1
  doAssert recorder.data.actions.len == 0
  when sizeof(int) > sizeof(int32):
    let oversized = Move(source: int32.high.int + 1, target: 0)
    expectReplayError:
      recorder.recordTick(world, [oversized, noMove()])
  recorder.recordTick(world, [noMove(), noMove()])
  doAssert recorder.data.hashes.len == 2
  inc world.turn
  expectReplayError:
    recorder.recordTick(world, [noMove(), noMove()])

echo "Testing file round trips and bounded malformed input"
block:
  let
    path = "out/test-replays-" & $getCurrentProcessId() & ".replay"
    bytes = sample.encodeReplay()
  defer:
    if fileExists(path):
      removeFile(path)
  saveReplay(path, sample)
  doAssert loadReplay(path) == sample
  expectReplayError:
    discard loadReplay(path & ".missing")
  expectReplayError:
    saveReplay("", sample)
  expectReplayError:
    discard loadReplay("")
  expectReplayError:
    discard decodeReplay(newString(MaxReplayBytes + 1))
  for length in [0, 1, ReplayMagic.len, 30, 90, bytes.len - 1]:
    expectReplayError:
      discard decodeReplay(bytes[0 ..< min(length, bytes.len)])
  expectReplayError:
    discard decodeReplay(bytes & "trailing")
  var empty = newReplayRecorder(newWorld(sample.config)).data
  let
    emptyBytes = empty.encodeReplay()
    actionLengthOffset = emptyBytes.len - 16
  var malformed = emptyBytes
  for i in 0 ..< 8:
    malformed[actionLengthOffset + i] = char(255)
  expectReplayError:
    discard decodeReplay(malformed)

echo "Testing inline chat bounds before decoding untrusted words"
block:
  let original = newReplayRecorder(newWorld(sample.config)).data.compact()
  for size in [0'u32, 561'u32, uint32.high]:
    var malformed = original
    malformed.actions = @[uint32.high - 1, 0'u32, 0'u32, size]
    expectReplayError:
      discard malformed.encoded().decodeReplay()
  for count in 1 .. 4:
    var malformed = original
    malformed.actions = @[uint32.high - 1, 0'u32, 0'u32, 4'u32]
    malformed.actions.setLen(count)
    expectReplayError:
      discard malformed.encoded().decodeReplay()

echo "Testing game and tape versions and malformed action metadata"
block:
  let bytes = sample.encodeReplay()
  expectReplayError:
    discard decodeReplay(encodeReplayFile("galcon", ReplayGameVersion, sample))
  expectReplayError:
    discard decodeReplay(encodeReplayFile(
      ReplayGame,
      ReplayGameVersion + 1,
      sample
    ))
  var changed = bytes.decodeReplay()
  changed.header.formatVersion += 1
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.header.gameVersion += 1
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.header.setup.mapVersion = ReplayMapVersion + 1
  expectReplayError:
    discard newReplayWorld(changed)
  changed = bytes.decodeReplay()
  changed.header.setup.mapVersion = 0
  expectReplayError:
    discard newReplayWorld(changed)
  changed = bytes.decodeReplay()
  changed.header.setup.maximumTicks += 1
  expectReplayError:
    discard newReplayWorld(changed)
  changed = bytes.decodeReplay()
  changed.header.setup.mapHash = changed.header.setup.mapHash xor 1
  expectReplayError:
    discard newReplayWorld(changed)
  changed = bytes.decodeReplay()
  changed.config.width = int.high
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.config.seed = changed.config.seed xor (1'u64 shl 63)
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[0].player = uint32(changed.config.players)
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[0].flags = 4
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[0].row = int32.low
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[0].tick = 0
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[^1].tick = uint32(changed.hashes.len + 1)
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[0].tick = 2
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions.insert(changed.actions[0], 1)
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.hashes.setLen(changed.config.maxTurns + 1)
  expectReplayError:
    discard newReplayPlayer(changed)

echo "Testing replay divergence and stale cursors"
block:
  var data = sample.encodeReplay().decodeReplay()
  data.hashes[0] = data.hashes[0] xor 1
  let player = newReplayPlayer(data)
  var
    world = newReplayWorld(data)
    moves: array[MaxPlayers, Move]
  expectReplayError:
    discard player.replayTick(world, moves)
  let goodPlayer = newReplayPlayer(sample)
  world = newReplayWorld(sample)
  world.turn = 1
  expectReplayError:
    discard goodPlayer.replayTick(world, moves)
  world = newReplayWorld(sample)
  world.finished = true
  expectReplayError:
    discard goodPlayer.replayTick(world, moves)

echo "Testing public roster metadata without BASIC paths or sources"
block:
  let world = newWorld(defaultConfig(8, 2))
  var
    roster = defaultRoster()
    files: BotFiles
  files[0] = "/private/local/bots/Explorer.bas"
  files[1] = "/private/local/bots/unused.bas"
  roster.players[0].mmr = 37
  roster.players[1] = PlayerInfo(name: "  Commander  ", mmr: 0)
  roster.players[3] = PlayerInfo(name: "Inactive", mmr: 8)
  roster.exposePlayerInfo = false
  let
    resolved = resolveRoster(roster, files, 2)
    recorder = newReplayRecorder(world, resolved)
    bytes = recorder.data.encodeReplay()
    data = bytes.decodeReplay()
    stored = data.header.setup.roster
  doAssert stored == resolved
  doAssert stored.players[0] == PlayerInfo(name: "Explorer", mmr: 37)
  doAssert stored.players[1] == PlayerInfo(name: "Commander", mmr: 0)
  doAssert stored.players[3] == PlayerInfo(name: "", mmr: -1)
  doAssert not stored.exposePlayerInfo
  doAssert stored.queryName(0) == "" and stored.queryMmr(0) == -1
  doAssert not bytes.contains("/private/local/")
  doAssert not bytes.contains(".bas")
  roster.players[0].name = "Changed later"
  doAssert recorder.data.header.setup.roster == resolved
  doAssert newReplayWorld(data) == world
  doAssert newReplayWorld(data).stateHash() == world.stateHash()
  roster = defaultRoster()
  let generic = newReplayRecorder(world, roster).data.header.setup.roster
  doAssert generic.players[0] == PlayerInfo(name: "Player 1", mmr: -1)
  doAssert generic.players[1] == PlayerInfo(name: "Player 2", mmr: -1)
  doAssert generic.exposePlayerInfo
  for invalidName in [
    "x".repeat(MaxPlayerNameBytes + 1), "\xff", "\xed\xa0\x80",
    "\xf4\x90\x80\x80", "\xe0\x81\x81"
  ]:
    roster = defaultRoster()
    roster.players[0].name = invalidName
    expectReplayError:
      discard newReplayRecorder(world, roster)
  roster = defaultRoster()
  roster.players[0].mmr = -2
  expectReplayError:
    discard newReplayRecorder(world, roster)
  files[0] = "/private/local/bots/literal.bas.bas"
  roster = resolveRoster(defaultRoster(), files, 2)
  doAssert roster.players[0].name == "literal.bas"
  doAssert newReplayRecorder(world, roster).data.header.setup.roster == roster
  var changed = bytes.decodeReplay()
  changed.header.setup.roster.players[0].name = "bad\nname"
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.header.setup.roster.players[0].mmr = -2
  expectReplayError:
    discard newReplayPlayer(changed)
  var malformed = bytes
  let gateOffset =
    ReplayMagic.len + 6 + ReplayGame.len +
    recorder.data.header.toFlatty().len - 1
  malformed[gateOffset] = char(2)
  expectReplayError:
    discard decodeReplay(malformed)

echo "Testing public chat metadata, ordering, normalization, and caps"
block:
  var
    config = defaultConfig(4, 2)
    world: World
  config.maxTurns = 1
  world = newWorld(config)
  let recorder = newReplayRecorder(world)
  doAssert recorder.recordChat(0, 0, "Ready 🌟")
  world.tick([noMove(), noMove()])
  recorder.recordTick(world, [noMove(), noMove()])
  let expectedHash = world.stateHash()
  doAssert recorder.recordChat(1, 1, "Good game")
  doAssert recorder.recordChat(1, 1, "Good game")
  doAssert recorder.recordChat(0, 1, "🌟".repeat(140))
  let data = recorder.data.encodeReplay().decodeReplay()
  doAssert data.actions == recorder.data.actions
  doAssert data.actions[0] == ReplayAction(kind: ChatAction,
    tick: 0,
    player: 0,
    text: "Ready 🌟"
  )
  doAssert data.actions.len == 4
  doAssert data.hashes == @[expectedHash]
  let player = newReplayPlayer(data)
  var
    replay = newReplayWorld(data)
    moves: array[MaxPlayers, Move]
    log: MatchLog
  log.resetLog()
  player.replayInitial(log)
  doAssert log.entries.len == 2
  doAssert log.entries[1].text == "Ready 🌟"
  doAssert player.replayTick(replay, moves, log)
  doAssert replay == world
  let transcript = log.entries
  doAssert transcript[^3].text == "Good game"
  doAssert transcript[^2].text == "Good game"
  replay = newReplayWorld(data)
  player.actionIndex = 0
  log.resetLog()
  player.replayInitial(log)
  doAssert player.replayTick(replay, moves, log)
  doAssert log.entries == transcript
  doAssert not player.replayTick(replay, moves, log)
  doAssert log.entries == transcript
  for invalidText in [
    "", " leading", "trailing ", "two  spaces", "line\nbreak",
    "control\x01", "\xff", "\xed\xa0\x80", "\xf4\x90\x80\x80",
    "\xe0\x81\x81", "🌟".repeat(141)
  ]:
    expectReplayError:
      discard recorder.recordChat(0, 1, invalidText)
  expectReplayError:
    discard recorder.recordChat(2, 1, "Unknown player")
  expectReplayError:
    discard recorder.recordChat(-1, 1, "Unknown player")
  expectReplayError:
    discard recorder.recordChat(0, 2, "Future")
  expectReplayError:
    discard recorder.recordChat(0, -1, "Negative")
  expectReplayError:
    discard recorder.recordChat(0, 0, "Backward")
  let bytes = data.encodeReplay()
  var changed = bytes.decodeReplay()
  changed.actions[0].player = 2
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[0].tick = 2
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[1].tick = 0
  changed.actions[0].tick = 1
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions[0].text = "bad\nchat"
  expectReplayError:
    discard newReplayPlayer(changed)
  changed = bytes.decodeReplay()
  changed.actions.setLen(MaxReplayChats + 1)
  expectReplayError:
    discard newReplayPlayer(changed)
  var boundedWorld = newWorld(config)
  let bounded = newReplayRecorder(boundedWorld)
  for i in 0 ..< MaxReplayChats:
    doAssert bounded.recordChat(i mod 2, 0, "Public")
  doAssert not bounded.recordChat(0, 0, "Budget exhausted")
  doAssert bounded.data.actions.len == MaxReplayChats
  boundedWorld.tick([noMove(), noMove()])
  bounded.recordTick(boundedWorld, [noMove(), noMove()])
  doAssert not bounded.recordChat(0, 1, "Still exhausted")
  let boundedData = bounded.data.encodeReplay().decodeReplay()
  doAssert boundedData.actions.len == MaxReplayChats
  doAssert boundedData.hashes.len == 1
  expectReplayError:
    discard bounded.recordChat(-1, 0, "Still invalid")

echo "Testing all FFA seat counts, player ten, and map version retention"
for count in 2 .. MaxPlayers:
  var
    config = defaultConfig(19, count)
    roster = defaultRoster()
  config.maxTurns = 64
  for i in 0 ..< count:
    roster.players[i] = PlayerInfo(name: "Commander " & $(i + 1), mmr: int32(i))
  var
    world = newWorld(config)
    scratch: BotScratch
    moves = newSeq[Move](count)
  let recorder = newReplayRecorder(world, roster)
  doAssert recorder.data.header.setup.mapVersion == ReplayMapVersion
  doAssert recorder.recordChat(count - 1, 0, "Last seat ready")
  while not world.finished:
    for i in 0 ..< count:
      moves[i] = chooseMove(world, i, scratch)
    world.tick(moves)
    recorder.recordTick(world, moves)
  let
    data = recorder.data.encodeReplay().decodeReplay()
    player = newReplayPlayer(data)
  var
    replay = newReplayWorld(data)
    replayMoves: array[MaxPlayers, Move]
    lastPlayerActed = false
  doAssert data.header.setup.roster == roster
  doAssert data.actions[0].player == uint32(count - 1)
  for action in data.actions:
    if action.kind == MoveAction and action.player == uint32(count - 1):
      lastPlayerActed = true
  doAssert lastPlayerActed
  while player.replayTick(replay, replayMoves):
    discard
  doAssert replay == world
  var invalid = data
  invalid.header.setup.mapVersion = 1
  expectReplayError:
    discard newReplayWorld(invalid)

echo "Testing old replay versions require their archived game build"
block:
  for version in 1'u16 ..< ReplayGameVersion:
    var old = sample
    old.header.formatVersion = version
    old.header.gameVersion = version
    expectReplayError:
      discard decodeReplay(encodeReplayFile(ReplayGame, version, old))

echo "All replay checks passed"
