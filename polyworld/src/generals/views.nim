import
  std/[algorithm, math, monotimes, os, strutils, times, unicode],
  chroma, opengl, pixie, pixie/fileformats/svg, silky, vmath,
  silky/widgets as widgets,
  silky/contexts as silkyContexts,
  silky/internal/inputs as textInputs,
  polyworld/viewers,
  profiles as gameProfiles,
  common, controls, worlds, visions, bots, events, chats, themes, arrows,
  replays, transports, povs, players, brains, messages

when gameProfiles.ProfileTracePath.len > 0:
  import silky/profiles as silkyProfiles

when defined(softmaxReplay) and defined(emscripten):
  {.emit: "#include <emscripten.h>".}

when defined(softmaxReplay):
  import polyworld_live

const
  SidebarWidth = 406.0'f
  ChatLineHeight = 24.0'f
  ChatInputHeight = 36.0'f
  MaxChatLines = 12
  WinnerPauseSeconds = 5.0
  Emotes = [":)", ":D", ":(", "<3", "GG", "GLHF"]

type
  Screen = enum
    MenuScreen, HelpScreen, GameScreen
  ChatPart = object
    x: float32
    text, font: string
    player: int
  ChatLine = object
    marker: bool
    parts: seq[ChatPart]
  View = ref object
    window: Window
    sk: Silky
    config: Config
    autoWidth, autoHeight: bool
    humanPlayer: int
    pauseOnStart: bool
    initialSpeed: int = 1
    world: World
    configuredRoster, roster: Roster
    botFiles: BotFiles
    brains: array[MaxPlayers, Brain]
    hub: MessageHub
    replayChatIndex: int
    botScratch: BotScratch
    recording: ReplayRecorder
    replay: ReplayPlayer
    transport: Transport
    pov: Pov
    visibilityScratch: seq[bool]
    remote: bool
    liveChatTarget: int = -2
    when defined(softmaxReplay):
      live: LiveSnapshot
    replaying: bool
    replayEnded: bool
    replayEndAt: MonoTime
    recordPath: string
    controls: Controls
    screen: Screen
    boardOrigin: Vec2
    cellSize: float32
    size: Vec2
    stacked: bool
    scoreboard: Rect
    visible: seq[bool]
    log: MatchLog
    editor: Editor
    chatLines: seq[ChatLine]
    chatScroll, emoteIndex: int
    chatFocusEpoch: uint64
    deathTurns: array[MaxPlayers, int]
    captor: int
    chatDirty, emotesOpen: bool
    paused, closing, outcomeClosed, buttonsEnabled: bool
    frames: int
    elapsed: float64
    lastFrame: MonoTime
    screenshot: string

proc label(
    view: View,
    value: string,
    position: Vec2,
    color = Ink,
    font = "Default"
) =
  ## Draws one line of shared game typography.
  discard view.sk.drawText(font, value, position, color, clip = false)

proc centered(
    view: View,
    value: string,
    position: Vec2,
    width: float32,
    color = Ink,
    font = "Default"
) =
  ## Centers a text line within an explicit horizontal region.
  discard view.sk.drawText(
    font,
    value,
    position,
    color,
    maxWidth = width,
    clip = false,
    hAlign = CenterAlign
  )

proc fitted(view: View, value: string, width: float32, font: string): string =
  ## Fits a public name without cutting through a UTF-8 character.
  if view.sk.getTextSize(font, value).x <= width:
    return value
  var characters = value.toRunes()
  while characters.len > 0:
    characters.setLen(characters.len - 1)
    result = $characters & "..."
    if view.sk.getTextSize(font, result).x <= width:
      return
  result = "..."

proc button(
    view: View,
    value: string,
    position: Vec2,
    font = "Default",
    padding = vec2(8)
): bool =
  ## Uses the shared game theme with standard Silky button interactions.
  let
    sk = view.sk
    size = sk.getTextSize(font, value) + padding * 2
    interaction = widgets.interact(
      sk,
      rect(position, size),
      view.buttonsEnabled
    )
    patch =
      case interaction
      of widgets.Error:
        "button.error.9patch"
      of widgets.Disabled:
        "button.disabled.9patch"
      of widgets.Pressed, widgets.Held:
        "button.down.9patch"
      of widgets.Hovered, widgets.Released:
        "button.hover.9patch"
      of widgets.None, widgets.ReleasedOutside:
        "button.9patch"
  sk.drawRect(position + vec2(ShadowOffset), size, Black)
  sk.draw9Patch(patch, sk.theme.buttonPatch, position, size)
  view.label(
    value,
    position + padding,
    if view.buttonsEnabled: Ink else: Muted,
    font
  )
  interaction == widgets.Released

proc centeredButton(
    view: View,
    value: string,
    position: Vec2,
    width: float32,
    font = "OutcomeButton",
    padding = vec2(40, 14)
): bool =
  ## Centers a padded action by its measured label within the panel.
  let size = view.sk.getTextSize(font, value) + padding * 2
  view.button(
    value,
    position + vec2((width - size.x) / 2, 0),
    font,
    padding
  )

proc closeButton(view: View, position: Vec2): bool =
  ## Dismisses a panel through a large unobtrusive close target.
  let interaction = widgets.interact(
    view.sk,
    rect(position, vec2(42, 48)),
    true
  )
  view.label(
    "X",
    position + vec2(7, 6),
    if interaction in {widgets.Hovered, widgets.Pressed, widgets.Held}:
      Teal
    else:
      Black,
    "Close"
  )
  interaction == widgets.Released

proc hasHuman(view: View): bool =
  ## Reports whether this live view has a locally controlled roster seat.
  view.humanPlayer >= 0 and view.humanPlayer < view.world.config.players and
    view.brains[view.humanPlayer] == nil

proc humanAlive(view: View): bool =
  ## Reports whether the local controller still has a surviving general.
  view.hasHuman() and view.world.alive[view.humanPlayer]

proc refreshVisibility(view: View) =
  ## Applies the human seat's fog or shows the full spectator board.
  if view.humanAlive():
    view.visible = visibility(view.world, view.humanPlayer)
  else:
    view.visible.setLen(view.world.tiles.len)
    for shown in view.visible.mitems:
      shown = true

proc outcomeOpen(view: View): bool =
  ## Returns whether the result panel blocks the underlying match controls.
  not view.remote and not view.replaying and not view.outcomeClosed and
    (view.world.finished or (view.hasHuman() and not view.humanAlive()))

proc panel(view: View, origin, size: Vec2) =
  ## Draws a light square panel over the shared teal offset shadow.
  view.sk.drawRect(origin + vec2(ShadowOffset), size, Teal)
  view.sk.draw9Patch("window.9patch", view.sk.theme.windowPatch, origin, size)

proc sprite(view: View, name: string, origin: Vec2, size: float32) =
  ## Fits a copied game icon inside one tile without changing its pixels.
  let entry = view.sk.atlas.entries[name]
  view.sk.drawQuad(
    origin,
    vec2(size),
    vec2(entry.x.float32, entry.y.float32),
    vec2(entry.width.float32, entry.height.float32),
    rgbx(255, 255, 255, 255)
  )

proc border(view: View, origin, size: Vec2, color: ColorRGBX) =
  ## Draws a crisp two-pixel outline around a board tile or panel.
  view.sk.drawRect(origin, vec2(size.x, 2), color)
  view.sk.drawRect(origin, vec2(2, size.y), color)
  view.sk.drawRect(origin + vec2(0, size.y - 2), vec2(size.x, 2), color)
  view.sk.drawRect(origin + vec2(size.x - 2, 0), vec2(2, size.y), color)

proc tileOrigin(view: View, index: int): Vec2 =
  ## Converts a flat tile index into a logical screen position.
  let position =
    if view.replaying:
      view.pov.coordinates(view.world.config, index)
    else:
      (x: index mod view.world.config.width,
        y: index div view.world.config.width)
  view.boardOrigin + vec2(position.x.float32, position.y.float32) * view.cellSize

proc contentHeight(view: View): float32 =
  ## Reserves the shared transport ribbon only while watching a replay.
  view.size.y - (if view.replaying: replayTransportHeight(view.size.x) else: 0.0'f)

proc rankWidth(view: View): float32 =
  ## Accommodates supplied MMR values without overlapping adjacent columns.
  result = 50
  when defined(softmaxReplay):
    if view.remote:
      result = 78
      for score in view.live.skills:
        result = max(result, view.sk.getTextSize("Score", score).x + 40)
      return
    if view.replaying:
      result = 78
      for score in view.replay.data.header.setup.skillScores:
        result = max(result, view.sk.getTextSize("Score", score).x + 40)
      return
  for player in 0 ..< view.world.config.players:
    let rank = view.roster.playerMmr(player)
    if rank >= 0:
      result = max(result, view.sk.getTextSize("Score", $rank).x + 32)

proc sidebarWidth(view: View): float32 =
  ## Reserves rank values and the replay-only POV column beside the board.
  SidebarWidth + view.rankWidth() - 50 +
    (if view.replaying: 52.0'f else: 0.0'f)

proc chatWidth(view: View): float32 =
  ## Aligns phone chat with the full-width player table.
  if view.stacked: view.size.x - 24 else: SidebarWidth

proc layout(view: View) =
  ## Fits the map beside desktop panels or above them on a portrait phone.
  let previousChatWidth = view.chatWidth()
  view.stacked = view.screen == GameScreen and
    view.window.size.x < 760 and view.window.size.x < view.window.size.y
  view.sk.uiScale = min(
    view.window.size.x.float32 / (if view.stacked: 520.0'f else: 1280.0'f),
    view.window.size.y.float32 / 900
  )
  view.size = view.window.size.vec2 / view.sk.uiScale
  if view.chatWidth() != previousChatWidth:
    view.chatDirty = true
  let
    inset = vec2(12, if view.remote: 100 else: 44)
    scoreboardHeight = (2 + (view.world.config.players + 1) * 36).float32
    available = vec2(
      view.size.x - (if view.stacked: 0.0'f else: view.sidebarWidth()) - inset.x * 2,
      view.contentHeight() - inset.y - 12 -
        (if view.stacked: scoreboardHeight + 24 + ChatLineHeight * 2 + 8 + ChatInputHeight +
          (if view.remote: 32 else: 0) else: 0.0'f)
    )
    columns = view.world.config.width.float32
    rows = view.world.config.height.float32
  view.cellSize = min(
    available.x / columns,
    available.y / rows
  )
  let mapSize = vec2(columns, rows) * view.cellSize
  view.boardOrigin = inset + (available - mapSize) / 2
  if view.stacked:
    view.boardOrigin.y = inset.y
    view.scoreboard = rect(12, view.boardOrigin.y + mapSize.y + 12, view.size.x - 24, scoreboardHeight)
  else:
    view.scoreboard = rect(view.size.x - view.sidebarWidth(), 0, view.sidebarWidth(), scoreboardHeight)

proc start(view: View, newSeed = false) =
  ## Resets match state and gives the selected human seat its own general.
  if newSeed:
    view.config.seed = view.config.seed + 1'u64
  let defaults = defaultConfig(view.config.seed, view.config.players)
  if view.autoWidth:
    view.config.width = defaults.width
  if view.autoHeight:
    view.config.height = defaults.height
  view.replaying = false
  view.replay = nil
  view.world = newWorld(view.config)
  if view.humanPlayer >= view.config.players:
    view.humanPlayer = view.config.players - 1
  view.roster = resolveRoster(
    view.configuredRoster,
    view.botFiles,
    view.config.players
  )
  view.hub = newMessageHub(view.roster, view.config.players)
  view.brains = default(array[MaxPlayers, Brain])
  for player in 0 ..< view.config.players:
    if view.botFiles[player].len > 0:
      view.brains[player] = newBrain(
        readSource(view.botFiles[player]),
        player,
        view.hub
      )
  view.recording = newReplayRecorder(view.world, view.roster)
  view.controls = newControls(
    if view.hasHuman(): view.world.generals[view.humanPlayer] else: -1,
    if view.hasHuman(): view.humanPlayer else: -1
  )
  view.refreshVisibility()
  view.log.resetLog()
  view.deathTurns = default(array[MaxPlayers, int])
  view.captor = -1
  view.editor = Editor()
  view.chatScroll = 0
  view.chatDirty = true
  view.emotesOpen = false
  view.screen = GameScreen
  view.paused = view.pauseOnStart
  view.outcomeClosed = false
  view.elapsed = 0
  view.lastFrame = getMonoTime()

proc advance(view: View, autoplay = false) =
  ## Collects one order per seat before resolving a deterministic turn.
  if view.world.finished:
    return
  let
    human = if view.hasHuman(): view.humanPlayer else: -1
    general = if human >= 0: view.world.generals[human] else: -1
    before = snapshotEvents(view.world)
  var moves = newSeq[Move](view.world.config.players)
  for player in 0 ..< moves.len:
    moves[player] =
      if view.brains[player] != nil:
        view.brains[player].decide(view.world)
      elif player == human and not autoplay:
        view.controls.takeMove()
      else:
        chooseMove(view.world, player, view.botScratch)
  view.world.tick(moves)
  view.recording.recordTick(view.world, moves)
  view.log.recordTick(before, view.world, moves)
  view.hub.deliverMessages(view.log, view.world.turn)
  for entry in view.log.entries:
    if entry.turn == view.world.turn:
      if entry.kind in {Capture, Victory, Draw}:
        view.hub.broadcastEvent(entry)
      elif entry.kind == Chat:
        discard view.recording.recordChat(entry.player, entry.turn, entry.text)
    if entry.kind == Capture:
      view.deathTurns[entry.target] = entry.turn
      if entry.target == human:
        view.captor = entry.player
  if view.world.finished:
    view.outcomeClosed = false
    if view.recordPath.len > 0:
      saveReplay(view.recordPath, view.recording.data)
  view.chatDirty = true
  if not view.humanAlive():
    view.controls = newControls(-1, -1)
  elif view.world.generals[human] != general:
    view.controls = newControls(view.world.generals[human], human)
  else:
    view.controls.reconcile(view.world, moves[human])
  view.refreshVisibility()

proc syncReplay(view: View) =
  ## Reports the verified action tape position to the shared transport.
  view.transport.player.sync(
    view.world.turn.int32,
    view.replay.data.hashes.len.int32,
    view.world.turn >= view.replay.data.hashes.len
  )

proc replayChats(view: View) =
  ## Restores public chat at its recorded tick without executing any bots.
  let chats = view.replay.data.metrics.chats
  while view.replayChatIndex < chats.len and
    chats[view.replayChatIndex].tick <= uint32(view.world.turn):
      let entry = chats[view.replayChatIndex]
      discard view.log.addChat(entry.player.int, entry.tick.int, entry.text)
      inc view.replayChatIndex
      view.chatDirty = true

proc resetReplay(view: View) =
  ## Reconstructs the seeded board and clears derived event history.
  view.replayEnded = false
  view.world = newReplayWorld(view.replay.data)
  view.replay.syncCursor(0)
  view.log.resetLog()
  when defined(softmaxReplay):
    view.log.entries[0].text = view.replay.data.header.setup.skillLabel
  else:
    view.log.entries[0].text = "Replay events."
  view.replayChatIndex = 0
  view.replayChats()
  view.deathTurns = default(array[MaxPlayers, int])
  view.captor = -1
  view.chatScroll = 0
  view.chatDirty = true
  view.pov.updateVisibility(view.world, view.visible, view.visibilityScratch)
  view.syncReplay()

proc advanceReplay(view: View) =
  ## Applies recorded commands through the same simulation and verifies state.
  let before = snapshotEvents(view.world)
  var moves: array[MaxPlayers, Move]
  if not view.replay.replayTick(view.world, moves):
    return
  view.log.recordTick(
    before,
    view.world,
    moves.toOpenArray(0, view.world.config.players - 1)
  )
  view.replayChats()
  for entry in view.log.entries:
    if entry.kind == Capture:
      view.deathTurns[entry.target] = entry.turn
      if entry.target == view.humanPlayer:
        view.captor = entry.player
  view.chatDirty = true
  view.pov.updateVisibility(view.world, view.visible, view.visibilityScratch)
  view.syncReplay()

proc startReplay(view: View, data: ReplayData, at = 0) =
  ## Opens a standard Polyworld action tape with independent replay POV.
  view.replay = newReplayPlayer(data)
  view.replaying = true
  view.world = newReplayWorld(data)
  view.roster = data.header.setup.roster
  view.brains = default(array[MaxPlayers, Brain])
  view.hub = nil
  view.pov = newPov(view.world)
  view.transport = Transport(player: initPlayer(
    false,
    data.hashes.len.int32,
    playing = not view.pauseOnStart,
    speed = view.initialSpeed.int32,
    repeating = true
  ))
  view.controls = newControls(-1, -1)
  view.editor = Editor()
  view.emotesOpen = false
  view.outcomeClosed = true
  view.screen = GameScreen
  view.elapsed = 0
  view.lastFrame = getMonoTime()
  view.resetReplay()
  while view.world.turn < min(at, data.hashes.len):
    view.advanceReplay()

proc playReplay(view: View, elapsed: float64) =
  ## Restores from setup and catches up through the shared playback clock.
  let
    frameStart = epochTime()
    restore = view.transport.player.takeRestore()
  if restore >= 0:
    view.transport.player.targetTick = restore
    view.resetReplay()
  # Normalize the half-second game tick to the transport's short clock steps.
  view.transport.player.startFrame(
    elapsed.float32 / (60.0'f * TickSeconds.float32),
    60
  )
  while view.world.turn < view.replay.data.hashes.len and
    view.transport.player.shouldTick(frameStart):
      view.advanceReplay()
  if view.world.turn == view.replay.data.hashes.len:
    when not defined(softmaxReplay):
      if not view.world.finished:
        discard view.transport.player.shouldTick(frameStart)
        return
    if not view.replayEnded:
      view.replayEnded = true
      view.replayEndAt = getMonoTime()
    view.transport.player.accumulator = 0
    view.transport.player.targetTick = -1
    if not view.transport.player.repeating:
      view.transport.player.playing = false
    elif view.transport.player.playing and
      view.transport.player.timelineEnd > 0 and
      (getMonoTime() - view.replayEndAt).inNanoseconds.float64 / 1e9 >=
      WinnerPauseSeconds:
        view.transport.player.seekTo(0, automatic = true)

proc winnerText(view: View): string =
  ## Names the final winner without exposing results before the last tick.
  if view.world.winner >= 0:
    view.roster.displayName(view.world.winner) & " wins the game!"
  else:
    "The game is a draw."

proc drawReplayOutcome(view: View) =
  ## Shows the final result while leaving replay controls available below it.
  if view.remote:
    if not view.world.finished:
      return
  elif not view.replaying or view.world.turn != view.replay.data.hashes.len:
    return
  when not defined(softmaxReplay):
    if not view.world.finished:
      return
  let
    boardSize = vec2(
      view.world.config.width.float32,
      view.world.config.height.float32
    ) * view.cellSize
    size = vec2(min(540.0'f, boardSize.x - 24), 180)
    origin = view.boardOrigin + (boardSize - size) / 2
  view.sk.drawRect(view.boardOrigin, boardSize, rgbx(0, 0, 0, 96))
  view.panel(origin, size)
  if view.world.winner >= 0:
    view.centered(
      view.fitted(
        view.roster.displayName(view.world.winner),
        size.x - 32,
        "OutcomeName"
      ),
      origin + vec2(16, 42),
      size.x - 32,
      Black,
      "OutcomeName"
    )
    view.centered(
      "wins the game!",
      origin + vec2(0, 96),
      size.x,
      Black,
      "OutcomeDetail"
    )
  else:
    view.centered(
      "The game is a draw.",
      origin + vec2(0, 72),
      size.x,
      Black,
      "OutcomeDetail"
    )

proc drawBlockedGlow(view: View, target: int, origin: Vec2, size: float32) =
  ## Fades red along the selected edge of one adjacent blocked terrain tile.
  let selected = view.controls.selected
  if selected < 0 or selected >= view.world.tiles.len:
    return
  let
    width = view.world.config.width
    dx = selected mod width - target mod width
    dy = selected div width - target div width
  if abs(dx) + abs(dy) != 1:
    return
  let
    depth = max(2, int(round(view.cellSize * 0.4'f)))
    shown = view.visible[selected]
    opacity = if shown: 0.6'f else: 0.3'f
    channel = if shown: 109 else: 84
  for i in 0 ..< depth:
    let
      fade = 1.0'f - sqrt((i.float32 + 0.5'f) / depth.float32)
      alpha = uint8(round(255 * opacity * fade))
      tint = uint8(alpha.int * channel div 255)
      color = rgbx(alpha, tint, tint, alpha)
      offset = i.float32
    if dx != 0:
      let x = if dx > 0: size - 1 - offset else: offset
      view.sk.drawRect(origin + vec2(x, 0), vec2(1, size), color)
    else:
      let y = if dy > 0: size - 1 - offset else: offset
      view.sk.drawRect(origin + vec2(0, y), vec2(size, 1), color)

proc drawQueuedArrows(view: View) =
  ## Marks each queued direction once at the outgoing edge of its source.
  if view.controls.moves.len == 0:
    return
  let
    cell = view.cellSize
    textSize = round(clamp(cell * 0.375'f, 8.0'f, 18.0'f))
    fontSize = max(10, int(ceil(0.9'f * textSize)))
    padding = max(6.0'f, ceil(cell * 0.15'f))
    middle = round(cell / 2)
  for i, move in view.controls.moves:
    var repeated = false
    for j in 0 ..< i:
      let previous = view.controls.moves[j]
      if previous.source == move.source and previous.target == move.target:
        repeated = true
        break
    if repeated:
      continue
    let
      delta = move.target - move.source
      direction =
        if delta == 1:
          RightArrow
        elif delta == -1:
          LeftArrow
        elif delta > 0:
          DownArrow
        else:
          UpArrow
      center =
        case direction
        of LeftArrow:
          vec2(padding + 1, middle)
        of RightArrow:
          vec2(cell - padding - 1, middle)
        of UpArrow:
          vec2(middle, padding)
        of DownArrow:
          vec2(middle, cell - padding - 4)
      origin = view.tileOrigin(move.source)
    view.sk.pushClipRect(rect(origin, vec2(cell)))
    view.sprite(
      arrowName(fontSize, direction),
      origin + center - vec2(ArrowCanvas.float32 / 2),
      ArrowCanvas.float32
    )
    view.sk.popClipRect()

proc drawBoard(view: View, preview = false) =
  ## Draws terrain, armies and fog without revealing hidden owners or crowns.
  let
    sk = view.sk
    width = view.world.config.width
    mapSize = vec2(
      width.float32,
      view.world.config.height.float32
    ) * view.cellSize
  sk.drawRect(view.boardOrigin, mapSize, Fog)
  for i, tile in view.world.tiles:
    let
      shown = preview or view.visible[i]
      origin = view.tileOrigin(i)
      size = view.cellSize - 2
    var color = Fog
    if shown:
      color =
        if tile.owner >= 0:
          PlayerColors[tile.owner]
        else:
          case tile.kind
          of Plain, General: PlainColor
          of City: CityColor
          of Mountain: MountainColor
      sk.drawRect(origin, vec2(view.cellSize), Grid)
      sk.drawRect(origin, vec2(size), color)
    if not preview and not view.replaying and
      view.humanAlive() and not view.world.finished and
      (tile.kind == Mountain or (not shown and tile.kind == City)):
        view.drawBlockedGlow(i, origin, size)
    if shown and tile.kind != Plain:
      let image =
        case tile.kind
        of General: "crown"
        of City: "city"
        of Mountain: "mountain"
        of Plain: ""
      let iconSize = size * 0.85'f
      view.sprite(image, origin + vec2((size - iconSize) / 2), iconSize)
    elif not shown and tile.kind in {Mountain, City}:
      view.sprite("obstacle", origin, size)
    if shown and tile.army > 0:
      let
        number =
          if not preview and not view.replaying and
            i == view.controls.selected and view.controls.half:
              "50%"
          else:
            $tile.army
        font = if view.cellSize < 25: "Small" else: "Board"
        textSize = sk.getTextSize(font, number)
        at = origin + (vec2(size) - textSize) / 2
      view.label(number, at + vec2(1), rgbx(0, 0, 0, 210), font)
      view.label(number, at, Ink, font)
  if not preview and not view.replaying:
    let selected = view.controls.selected
    if selected >= 0 and selected < view.world.tiles.len:
      view.border(
        view.tileOrigin(selected) - vec2(1),
        vec2(view.cellSize + 1),
        Gold
      )
    view.drawQueuedArrows()

proc turnText(turn: int): string =
  ## Shows whole turns with the original dot for an intervening half-turn.
  result = $(turn div 2)
  if turn mod 2 != 0:
    result.add('.')

proc drawTurn(view: View) =
  ## Anchors the original white turn counter at the top-left corner.
  let
    text = "Turn " & turnText(view.world.turn)
    width = max(94.0'f, view.sk.getTextSize("Turn", text).x + 10)
  view.sk.drawRect(vec2(0), vec2(width + 2, 34), Teal)
  view.sk.drawRect(vec2(0), vec2(width, 32), Ink)
  view.centered(text, vec2(0, 4), width, Black, "Turn")

proc drawStar(view: View, origin: Vec2) =
  ## Draws the original gold rank symbol without requiring a fallback font.
  let
    entry = view.sk.atlas.entries[WhiteTileKey]
    uv = vec2(entry.x.float32, entry.y.float32) +
      vec2(entry.width.float32, entry.height.float32) / 2
    center = origin + vec2(8)
    color = rgbx(255, 215, 0, 255)
  var points: array[10, Vec2]
  for i in 0 ..< points.len:
    let
      angle = -PI / 2 + i.float64 * PI / 5
      radius = if i mod 2 == 0: 8.0'f else: 3.3'f
    points[i] = center + vec2(cos(angle), sin(angle)) * radius
  for i in 0 ..< points.len:
    view.sk.drawTriangle(
      [center, points[i], points[(i + 1) mod points.len]],
      [uv, uv, uv],
      [color, color, color]
    )

proc drawPov(view: View, player: int, origin: Vec2) =
  ## Separates original-view orientation from multi-player fog selection.
  let
    sk = view.sk
    eye = rect(origin + vec2(2, 2), vec2(24, 30))
    checkbox = rect(origin + vec2(29, 8), vec2(17))
    active = view.pov.orientation == player
    name = if active: "eye-dark" else: "eye"
    icon = sk.atlas.entries[name]
    interaction = widgets.interact(sk, eye, view.buttonsEnabled)
  if interaction == widgets.Released:
    view.pov.toggleOrientation(player)
  sk.drawQuad(
    origin + vec2(4, 11),
    vec2(19, 12),
    vec2(icon.x.float32, icon.y.float32),
    vec2(icon.width.float32, icon.height.float32),
    if active: Ink else: rgbx(102, 102, 102, 102)
  )
  let selected = view.pov.selected[player]
  sk.drawRect(checkbox.xy, checkbox.wh, rgbx(170, 170, 170, 255))
  sk.drawRect(
    checkbox.xy + vec2(1),
    checkbox.wh - vec2(2),
    if selected: rgbx(0, 120, 255, 255) else: Ink
  )
  if selected:
    view.sprite("pov-check", checkbox.xy, checkbox.w)
  if widgets.interact(
    sk,
    rect(origin + vec2(27, 2), vec2(23, 30)),
    view.buttonsEnabled and view.world.alive[player]
  ) == widgets.Released:
    view.pov.togglePlayer(view.world, player)
    view.pov.updateVisibility(view.world, view.visible, view.visibilityScratch)

proc drawScoreboard(view: View) =
  ## Ranks public scores and adds original POV controls for recorded games.
  let
    sidebar = view.scoreboard.w
    widths = [50.0'f, view.rankWidth(), 240.0'f + sidebar - view.sidebarWidth(), 54.0'f, 52.0'f]
    origin = view.scoreboard.xy
    players = view.world.config.players
  var
    armies, lands: array[MaxPlayers, int]
    ordered: seq[int]
  for player in 0 ..< players:
    when defined(softmaxReplay):
      if view.remote:
        armies[player] = view.live.army[player]
        lands[player] = view.live.land[player]
      else:
        let score = totals(view.world, player)
        armies[player] = score.army
        lands[player] = score.land
    else:
      let score = totals(view.world, player)
      armies[player] = score.army
      lands[player] = score.land
    ordered.add(player)
  ordered.sort(proc(a, b: int): int =
    ## Sorts living armies first and preserves a deterministic tie order.
    result = cmp(view.world.alive[b], view.world.alive[a])
    if result == 0 and not view.world.alive[a]:
      result = cmp(view.deathTurns[b], view.deathTurns[a])
    if result == 0:
      result = cmp(armies[b], armies[a])
    if result == 0:
      result = cmp(lands[b], lands[a])
    if result == 0:
      result = cmp(a, b)
  )
  view.sk.drawRect(
    origin,
    view.scoreboard.wh,
    Black
  )
  for row in 0 .. players:
    let
      player = if row == 0: -1 else: ordered[row - 1]
      y = 2 + row.float32 * 36
    var x = 2.0'f
    for column in (if view.replaying: 0 else: 1) .. widths.high:
      let
        width = widths[column]
        at = origin + vec2(x, y)
        color = if column == 2 and player >= 0: PlayerColors[player] else: Ink
      view.sk.drawRect(at, vec2(width, 34), color)
      if column == 0 and player >= 0:
        view.drawPov(player, at)
      elif column == 1:
        when defined(softmaxReplay):
          if view.replaying or view.remote:
            if player < 0:
              view.centered("Skill", at + vec2(0, 6), width, Black, "Score")
            else:
              view.drawStar(at + vec2(7, 9))
              let score = if view.remote: view.live.skills[player] else: view.replay.data.header.setup.skillScores[player]
              view.label(score, at + vec2(28, 6), Black, "Score")
        if (not view.replaying and not view.remote) or not defined(softmaxReplay):
          view.drawStar(at + vec2(7, 9))
        if player >= 0 and ((not view.replaying and not view.remote) or not defined(softmaxReplay)):
          let rank = view.roster.playerMmr(player)
          view.label(
            if rank < 0: "?" else: $rank,
            at + vec2(28, 6),
            Black,
            "Score"
          )
      else:
        let value =
          if row == 0:
            ["POV", "", "Player", "Army", "Land"][column]
          elif column == 2:
            view.fitted(view.roster.displayName(player), width - 12, "Score")
          elif column == 3:
            $armies[player]
          else:
            $lands[player]
        view.centered(
          value,
          at + vec2(0, 6),
          width,
          if column == 2 and player >= 0: Ink else: Black,
          "Score"
        )
      x += width + 2
    if player >= 0 and not view.world.alive[player]:
      view.sk.drawRect(
        origin + vec2(2, y),
        vec2(sidebar - 4, 34),
        EliminatedOverlay
      )

proc displayChat(view: View, text: string): string =
  ## Keeps unsupported characters visible instead of silently dropping them.
  for rune in text.runes:
    let glyph = rune.toUTF8()
    result.add(if glyph in view.sk.atlas.fonts["Chat"].entries: glyph else: "?")

proc rebuildChat(view: View) =
  ## Wraps the bounded event history into colored text and player markers.
  view.chatLines.setLen(0)
  var
    x = 20.0'f
    currentFont = "Chat"
  proc newLine(marker = false) =
    ## Starts a wrapped line at the shared message inset.
    view.chatLines.add(ChatLine(marker: marker))
    x = 20
  proc addText(value: string, font = "") =
    ## Appends words, splitting an overlong token at character boundaries.
    let style = if font.len == 0: currentFont else: font
    for token, space in strutils.tokenize(view.displayChat(value)):
      let width = view.sk.getTextSize(style, token).x
      if x + width > view.chatWidth() - 10:
        if space:
          continue
        if x > 20:
          newLine()
      if width <= view.chatWidth() - 30:
        view.chatLines[^1].parts.add(ChatPart(
          x: x, text: token, font: style, player: -1
        ))
        x += width
      else:
        for rune in token.runes:
          let
            glyph = rune.toUTF8()
            glyphWidth = view.sk.getTextSize(style, glyph).x
          if x + glyphWidth > view.chatWidth() - 10:
            newLine()
          view.chatLines[^1].parts.add(ChatPart(
            x: x, text: glyph, font: style, player: -1
          ))
          x += glyphWidth
  proc addPlayer(player: int) =
    ## Keeps a player's color marker beside the beginning of their name.
    if x + 40 > view.chatWidth() - 10:
      newLine()
    view.chatLines[^1].parts.add(ChatPart(x: x, player: player))
    x += 14
    addText(view.roster.displayName(player))
  for entry in view.log.entries:
    currentFont = if entry.kind == Chat: "Chat" else: "Event"
    newLine(marker = entry.kind != Chat)
    case entry.kind
    of Notice:
      addText(entry.text)
    of Chat:
      addPlayer(entry.player)
      addText(": " & entry.text)
    of Capture:
      when defined(softmaxReplay):
        addPlayer(entry.target)
        addText(" was eliminated.")
      else:
        if entry.player >= 0:
          addPlayer(entry.player)
          addText(" captured ")
          addPlayer(entry.target)
          addText(".")
        else:
          addPlayer(entry.target)
          addText(" was captured.")
    of Victory:
      addPlayer(entry.player)
      addText(" wins!")
    of Draw:
      addText("The game ended in a draw.")
    if entry.kind != Notice:
      addText("  " & turnText(entry.turn), "Timestamp")
  when defined(softmaxReplay):
    if view.replaying and view.world.turn == view.replay.data.hashes.len:
      currentFont = "Event"
      newLine(marker = true)
      addText(view.replay.data.header.setup.outcome)
  view.chatDirty = false

proc chatRows(view: View): int =
  ## Keeps scrolling events clear of the player table in a stacked layout.
  result = MaxChatLines
  if view.stacked:
    let height = view.contentHeight() - view.scoreboard.y - view.scoreboard.h - 12
    result = min(result, int((height - ChatInputHeight - 8) / ChatLineHeight))

proc chatBounds(view: View): Rect =
  ## Returns the chat area above the ribbon and below the portrait player table.
  let
    lines = min(view.chatRows(), max(1, view.chatLines.len))
    height = lines.float32 * ChatLineHeight + 8 + ChatInputHeight
  rect(
    (if view.stacked: 12.0'f else: view.size.x - view.chatWidth()),
    view.contentHeight() - height,
    view.chatWidth(),
    height
  )

proc editorPrefix(view: View, count: int): string =
  ## Measures cursor and selection positions using the rendered characters.
  for i in 0 ..< min(count, view.editor.text.len):
    result.add(view.editor.text[i].toUTF8())
  result = view.displayChat(result)

proc drawChatInput(view: View, origin: Vec2) =
  ## Fills the white input with solid, rounded lower corners.
  let
    sk = view.sk
    entry = sk.atlas.entries[WhiteTileKey]
    uv = vec2(entry.x.float32, entry.y.float32) +
      vec2(entry.width.float32, entry.height.float32) / 2
  sk.drawRect(origin, vec2(view.chatWidth(), ChatInputHeight - 10), Ink)
  sk.drawRect(origin + vec2(10, ChatInputHeight - 10),
    vec2(view.chatWidth() - 20, 10), Ink)
  for corner in 0 .. 1:
    let
      x = if corner == 0: view.chatWidth() - 10 else: 10.0'f
      center = origin + vec2(x, ChatInputHeight - 10)
    for i in 0 ..< 12:
      let
        angle = (corner.float64 + i.float64 / 12) * PI / 2
        next = (corner.float64 + (i + 1).float64 / 12) * PI / 2
        first = center + vec2(cos(angle), sin(angle)) * 10
        last = center + vec2(cos(next), sin(next)) * 10
      sk.drawTriangle([center, first, last], [uv, uv, uv], [Ink, Ink, Ink])

proc drawChat(view: View) =
  ## Anchors wrapped events and an editable local chat box at bottom right.
  if view.chatDirty:
    view.rebuildChat()
  let
    sk = view.sk
    bounds = view.chatBounds()
    input = vec2(bounds.x, view.contentHeight() - ChatInputHeight)
    rows = min(view.chatRows(), view.chatLines.len)
  view.chatScroll = clamp(view.chatScroll, 0, view.chatLines.len - rows)
  let
    last = view.chatLines.len - view.chatScroll
    first = max(0, last - rows)
  sk.drawRect(bounds.xy, bounds.wh, rgbx(0, 0, 0, 128))
  sk.pushClipRect(rect(
    bounds.xy,
    vec2(view.chatWidth(), bounds.h - ChatInputHeight)
  ))
  for i in first ..< last:
    let at = bounds.xy + vec2(0, 4 + (i - first).float32 * ChatLineHeight)
    if view.chatLines[i].marker:
      sk.drawRect(at + vec2(8, 5), vec2(4, 14), rgbx(85, 85, 85, 255))
    for part in view.chatLines[i].parts:
      if part.player >= 0:
        sk.drawRect(at + vec2(part.x, 7), vec2(10), PlayerColors[part.player])
      else:
        view.label(
          part.text,
          at + vec2(part.x, if part.font == "Timestamp": 5.0'f else: 1.0'f),
          if part.font == "Timestamp": rgbx(187, 187, 187, 255) else: Ink,
          part.font
        )
  if view.chatLines.len > rows:
    let
      height = bounds.h - ChatInputHeight - 8
      thumb = height * rows.float32 / view.chatLines.len.float32
      offset = (height - thumb) * first.float32 /
        max(1, view.chatLines.len - rows).float32
    sk.drawRect(bounds.xy + vec2(view.chatWidth() - 5, 4 + offset),
      vec2(3, thumb), rgbx(170, 170, 170, 255))
  sk.popClipRect()
  when defined(softmaxReplay):
    if view.remote and view.humanAlive():
      let recipient = if view.liveChatTarget == -2: "Everyone" else: view.roster.displayName(view.liveChatTarget)
      if view.button("To: " & view.fitted(recipient, view.chatWidth() - 70, "Hud"),
          vec2(bounds.x, bounds.y - 32), "Hud", vec2(6)):
        if view.liveChatTarget == -2:
          view.liveChatTarget = 0
        else:
          inc view.liveChatTarget
          if view.liveChatTarget >= view.world.config.players:
            view.liveChatTarget = -2
  view.drawChatInput(input)
  if view.replaying or not view.hasHuman() or (view.remote and not view.humanAlive()):
    view.label(
      if view.replaying: "Replay" else: "Spectating",
      input + vec2(10, 8),
      Muted,
      "Chat"
    )
    return
  if view.editor.focused:
    view.border(input, vec2(view.chatWidth(), ChatInputHeight), Teal)
  let
    cursorX = sk.getTextSize("Chat", view.editorPrefix(view.editor.cursor)).x
    offset = max(0.0'f, cursorX - view.chatWidth() + 24)
    textOrigin = input + vec2(10 - offset, 8)
  sk.pushClipRect(rect(input + vec2(8, 4), vec2(view.chatWidth() - 16, 28)))
  if view.editor.focused:
    let
      selection = view.editor.selection()
      left = sk.getTextSize("Chat", view.editorPrefix(selection.first)).x
      right = sk.getTextSize("Chat", view.editorPrefix(selection.last)).x
    if left != right:
      sk.drawRect(textOrigin + vec2(left, 0), vec2(right - left, 20),
        rgbx(173, 211, 224, 255))
  if view.editor.text.len == 0 and not view.editor.focused:
    view.label("Press [enter] to chat, [tab] for emotes.", input + vec2(10, 8),
      rgbx(136, 136, 136, 255), "Chat")
  else:
    view.label(view.displayChat(view.editor.value()), textOrigin, Black, "Chat")
  if view.editor.focused and view.frames mod 60 < 30:
    sk.drawRect(textOrigin + vec2(cursorX, 0), vec2(1, 20), Black)
  sk.popClipRect()
  if view.emotesOpen:
    let origin = input - vec2(0, 48)
    sk.drawRect(origin, vec2(view.chatWidth(), 48), rgbx(15, 15, 15, 255))
    for i, emote in Emotes:
      let at = origin + vec2(i.float32 * view.chatWidth() / Emotes.len.float32, 0)
      if i == view.emoteIndex:
        sk.drawRect(
          at + vec2(2),
          vec2(view.chatWidth() / Emotes.len.float32 - 4, 44),
          Teal
        )
      view.centered(emote, at + vec2(0, 12), view.chatWidth() / Emotes.len.float32,
        Ink, "Score")

proc sendChat(view: View, message: string) =
  ## Adds one local message and returns keyboard control to the board.
  when defined(softmaxReplay):
    if view.remote:
      liveInput("chat", value = view.liveChatTarget, text = message)
  if not view.remote and view.hasHuman() and view.hub != nil and
    view.hub.queueMessage(view.humanPlayer, -2, message) > 0:
      view.hub.deliverMessages(view.log, view.world.turn)
      let entry = view.log.entries[^1]
      discard view.recording.recordChat(entry.player, entry.turn, entry.text)
      if view.world.finished and view.recordPath.len > 0:
        saveReplay(view.recordPath, view.recording.data)
      view.chatDirty = true
      view.chatScroll = 0
  view.editor.clear()
  view.editor.focused = false
  view.emotesOpen = false

proc chatKey(view: View, event: textInputs.InputEvent) =
  ## Applies one ordered native edit without exposing it to army controls.
  let
    shift = event.shift
    command = event.super or (event.control and not event.alt)
  case event.button
  of KeyEscape:
    view.editor.focused = false
    view.emotesOpen = false
  of KeyTab:
    view.emotesOpen = not view.emotesOpen
  of KeyEnter:
    view.sendChat(
      if view.emotesOpen: Emotes[view.emoteIndex] else: view.editor.value()
    )
  of KeyBackspace:
    view.editor.backspace()
  of KeyDelete:
    view.editor.deleteForward()
  of KeyLeft:
    if view.emotesOpen:
      view.emoteIndex = (view.emoteIndex + Emotes.len - 1) mod Emotes.len
    elif command:
      view.editor.moveHome(shift)
    else:
      view.editor.moveCursor(-1, shift)
  of KeyRight:
    if view.emotesOpen:
      view.emoteIndex = (view.emoteIndex + 1) mod Emotes.len
    elif command:
      view.editor.moveEnd(shift)
    else:
      view.editor.moveCursor(1, shift)
  of KeyHome:
    view.editor.moveHome(shift)
  of KeyEnd:
    view.editor.moveEnd(shift)
  of KeyA:
    if command:
      view.editor.selectAll()
  of KeyC, KeyX:
    if command:
      let selected = view.editor.selectedText()
      if selected.len > 0:
        setClipboardString(selected)
        if event.button == KeyX:
          view.editor.backspace()
  of KeyV:
    if command:
      view.editor.insert(getClipboardString())
  else:
    discard

proc handleChat(view: View): bool =
  ## Consumes editing and log input before it can become a game command.
  let
    window = view.window
    mouse = window.mousePos.vec2 / view.sk.uiScale
    bounds = view.chatBounds()
    overChat = mouse.x >= bounds.x and mouse.x < bounds.x + bounds.w and
      mouse.y >= bounds.y and mouse.y < bounds.y + bounds.h
    wasFocused = view.editor.focused
    inputs = silkyContexts.textInputs(view.sk)
  if not view.hasHuman() or (view.remote and not view.humanAlive()):
    view.editor.focused = false
    view.emotesOpen = false
    if overChat and window.scrollDelta.y != 0:
      view.chatScroll = clamp(
        view.chatScroll + int(round(window.scrollDelta.y * 3)),
        0,
        max(0, view.chatLines.len - view.chatRows())
      )
    return overChat and
      (window.buttonPressed[MouseLeft] or window.scrollDelta.y != 0)
  if view.editor.focused and view.chatFocusEpoch != inputs.focusEpoch:
    view.editor.focused = false
    view.emotesOpen = false
  if view.editor.focused:
    for event in inputs.takeInput():
      case event.kind
      of textInputs.TextInput:
        if not event.super and not (event.control and not event.alt):
          view.emotesOpen = false
          view.editor.insert(event.rune)
      of textInputs.KeyDown:
        view.chatKey(event)
      of textInputs.KeyUp:
        discard
      if not view.editor.focused:
        break
  if overChat and window.scrollDelta.y != 0:
    view.chatScroll = clamp(
      view.chatScroll + int(round(window.scrollDelta.y * 3)),
      0,
      max(0, view.chatLines.len - view.chatRows())
    )
  if window.buttonPressed[MouseLeft]:
    if view.emotesOpen and mouse.x >= view.chatBounds().x and
      mouse.y >= view.size.y - ChatInputHeight - 48 and
      mouse.y < view.size.y - ChatInputHeight:
        let chosen = clamp(int((mouse.x - view.chatBounds().x) /
          (view.chatWidth() / Emotes.len.float32)), 0, Emotes.len - 1)
        view.sendChat(Emotes[chosen])
        return true
    if overChat:
      if mouse.y >= view.size.y - ChatInputHeight:
        let
          cursorX = view.sk.getTextSize("Chat",
            view.editorPrefix(view.editor.cursor)).x
          offset = max(0.0'f, cursorX - view.chatWidth() + 24)
          target = mouse.x - bounds.x - 10 + offset
        var
          closest = 0
          distance = abs(target)
        for i in 1 .. view.editor.text.len:
          let width = view.sk.getTextSize("Chat", view.editorPrefix(i)).x
          if abs(target - width) < distance:
            closest = i
            distance = abs(target - width)
        view.editor.focused = true
        view.editor.cursor = closest
        if not window.buttonDown[KeyLeftShift] and
          not window.buttonDown[KeyRightShift]:
            view.editor.anchor = closest
      return true
    if view.editor.focused or view.emotesOpen:
      view.editor.focused = false
      view.emotesOpen = false
      return true
  if wasFocused:
    return true
  if window.buttonPressed[KeyEnter] or window.buttonPressed[KeyTab]:
    view.editor.focused = true
    view.emotesOpen = window.buttonPressed[KeyTab]
    return true
  false

proc drawOutcome(view: View) =
  ## Ends player control with a clear result and local restart choices.
  if not view.outcomeOpen():
    return
  view.buttonsEnabled = true
  let
    size = vec2(584, 590)
    origin = (view.size - size) / 2
    title =
      if view.hasHuman() and view.world.finished and
        view.world.winner == view.humanPlayer:
          "Victory"
      elif view.world.finished and view.world.winner < 0:
        "Draw"
      else:
        "Game Over"
    defeated = view.hasHuman() and not view.humanAlive() and view.captor >= 0
    detail =
      if view.world.finished and view.world.winner >= 0:
        view.fitted(view.winnerText(), size.x - 40, "OutcomeDetail")
      elif defeated:
        "You were defeated by "
      elif view.world.finished and view.world.winner < 0:
        "The turn limit was reached."
      else:
        "Your general was captured."
    detailWidth = view.sk.getTextSize("OutcomeDetail", detail).x
    name =
      if view.world.finished and view.world.winner >= 0:
        ""
      elif defeated:
        view.fitted(
          view.roster.displayName(view.captor),
          size.x - detailWidth - 40,
          "OutcomeName"
        ) & "."
      else:
        ""
    nameWidth = view.sk.getTextSize("OutcomeName", name).x
    textOrigin = origin + vec2((size.x - detailWidth - nameWidth) / 2, 172)
  view.panel(origin, size)
  if view.closeButton(origin + vec2(8, 4)):
    view.outcomeClosed = true
    return
  view.centered(
    title,
    origin + vec2(0, 64),
    size.x,
    Black,
    "OutcomeTitle"
  )
  view.label(detail, textOrigin, Black, "OutcomeDetail")
  view.label(name, textOrigin + vec2(detailWidth, 0), Black, "OutcomeName")
  if view.centeredButton("Play Again", origin + vec2(0, 256), size.x):
    view.start(true)
    return
  if view.centeredButton(
    if view.world.finished: "Watch Replay" else: "Keep Watching",
    origin + vec2(0, 350),
    size.x
  ):
    if view.world.finished:
      view.startReplay(view.recording.data)
    else:
      view.outcomeClosed = true
    return
  if view.centeredButton(
    "Exit",
    origin + vec2(0, 444),
    size.x,
    "OutcomeExit",
    vec2(60, 18)
  ):
    view.screen = MenuScreen

proc drawMenu(view: View) =
  ## Shows a compact local game menu over a preview of the actual board.
  view.drawBoard(preview = true)
  view.sk.drawRect(vec2(0), view.size, rgbx(0, 0, 0, 208))
  let origin = (view.size - vec2(510, 560)) / 2
  view.panel(origin, vec2(510, 560))
  view.centered("POLYWORLD", origin + vec2(0, 35), 510, Muted, "Hud")
  view.centered("GENERALS", origin + vec2(0, 70), 510, Black, "Title")
  view.centered(
    "One crown. An army. A map hidden in fog.",
    origin + vec2(0, 145),
    510,
    Muted,
    "Hud"
  )
  view.label("LOCAL MATCH", origin + vec2(42, 201), Teal, "Hud")
  for players in 2 .. MaxPlayers:
    let position = origin + vec2(42 + (players - 2).float32 * 47, 234)
    if view.button($players, position, padding = vec2(13, 10)):
      view.config.players = players
    if view.config.players == players:
      view.sk.drawRect(position + vec2(0, 44), vec2(38, 3), Teal)
  view.label(
    if view.humanPlayer < 0:
      "Watch " & $view.config.players & " computer commanders."
    else:
      "You against " & $(view.config.players - 1) &
        (if view.config.players == 2: " computer." else: " computers."),
    origin + vec2(42, 295),
    Muted,
    "Hud"
  )
  if view.button("Play " & $view.config.players & " player game",
    origin + vec2(42, 331)):
      view.start()
  if view.button("How to play", origin + vec2(42, 388)):
    view.screen = HelpScreen
  if view.button("Quit", origin + vec2(42, 445)):
    view.closing = true
  view.label("Offline. Seeded maps. Classic rules.",
    origin + vec2(42, 513), Muted, "Small")

proc drawHelp(view: View) =
  ## Explains controls and the production and conquest rules in one panel.
  let origin = (view.size - vec2(740, 590)) / 2
  view.panel(origin, vec2(740, 590))
  view.label("How to play", origin + vec2(32, 29), Black, "H1")
  const Lines = [
    "Protect your general. Capture the other crowns to win.",
    "Select your land. Computer commanders obey the same fog of war.",
    "", "MOVEMENT",
    "Click one of your tiles, then a neighboring tile to move your army.",
    "WASD or arrow keys queue a path. Every move leaves one soldier behind.",
    "Hold Shift for half an army, or press Z to toggle half moves.",
    "Q or right click clears the queue. G selects your general.",
    "", "THE MAP",
    "Generals and owned cities gain an army every second.",
    "Every 25 seconds, all of your land gains one army.",
    "Mountains cannot be crossed. Cities have defending armies.",
    "You see your land and its eight neighboring tiles.",
    "A captured general becomes a city. The winner inherits the lost land.",
    "Mutual general captures trade crowns and land. Both players survive.",
    "At the turn limit, the match is a draw regardless of army or land.",
    "", "Space pauses the game. Escape returns to the menu."
  ]
  for i, line in Lines:
    view.label(
      line,
      origin + vec2(32, 89 + i.float32 * 22),
      if line in ["MOVEMENT", "THE MAP"]: Teal else: Muted,
      "Hud"
    )
  if view.button("Back", origin + vec2(32, 526)):
    view.screen = MenuScreen

proc handleInput(view: View) =
  ## Converts local mouse and keyboard input into bounded human orders.
  let window = view.window
  if window.buttonPressed[KeyF2]:
    gameProfiles.toggleProfileTrace()
  if view.screen == GameScreen and view.outcomeOpen():
    view.editor.focused = false
    view.emotesOpen = false
    if window.buttonPressed[KeyEscape]:
      view.screen = MenuScreen
      view.elapsed = 0
    return
  if view.screen == GameScreen and not view.replaying and view.handleChat():
    return
  when not defined(replayViewer):
    if window.buttonPressed[KeyEscape]:
      view.screen = MenuScreen
      view.elapsed = 0
  if view.screen != GameScreen:
    return
  if view.replaying:
    if window.buttonPressed[KeySpace]:
      view.transport.player.handleKey(KeySpace)
    if window.buttonPressed[KeyLeft]:
      view.transport.player.stepBack()
    if window.buttonPressed[KeyRight]:
      view.transport.player.stepForward()
    if window.buttonPressed[KeyHome]:
      view.transport.player.skipToStart()
    if window.buttonPressed[KeyEnd]:
      view.transport.player.skipToEnd()
    let mouse = window.mousePos.vec2 / view.sk.uiScale
    if mouse.x >= view.chatBounds().x and
      mouse.y >= view.chatBounds().y and
      mouse.y < view.contentHeight() and window.scrollDelta.y != 0:
        view.chatScroll = clamp(
          view.chatScroll + int(round(window.scrollDelta.y * 3)),
          0,
          max(0, view.chatLines.len - view.chatRows())
        )
    return
  when defined(softmaxReplay):
    if view.remote:
      if not view.humanAlive() or view.world.finished:
        return
      for (key, direction) in [
        (KeyW, 0), (KeyUp, 0), (KeyS, 1), (KeyDown, 1),
        (KeyA, 2), (KeyLeft, 2), (KeyD, 3), (KeyRight, 3)
      ]:
        if window.buttonPressed[key]:
          liveInput("move", value = direction,
            half = window.buttonDown[KeyLeftShift] or window.buttonDown[KeyRightShift])
      for (key, command) in [(KeyH, "split"), (KeyZ, "split"),
        (KeyE, "undo"), (KeyQ, "clear"), (KeyB, "build"),
        (KeyG, "general"), (KeySpace, "deselect")]:
          if window.buttonPressed[key]:
            liveInput(command)
      if window.buttonPressed[MouseRight]:
        liveInput("clear")
      if window.buttonPressed[MouseLeft]:
        let position = window.mousePos.vec2 / view.sk.uiScale - view.boardOrigin
        let x = int(floor(position.x / view.cellSize))
        let y = int(floor(position.y / view.cellSize))
        if x in 0 ..< view.world.config.width and y in 0 ..< view.world.config.height:
          liveInput("tile", value = y * view.world.config.width + x)
      return
  if window.buttonPressed[KeySpace]:
    view.paused = not view.paused
    view.elapsed = 0
  if not view.humanAlive() or view.world.finished:
    return
  if window.buttonPressed[KeyQ] or window.buttonPressed[MouseRight]:
    view.controls.clear(view.world)
  if window.buttonPressed[KeyG]:
    view.controls.select(view.world, view.world.generals[view.humanPlayer])
  if window.buttonPressed[KeyZ]:
    view.controls.half = not view.controls.half
  let half = window.buttonDown[KeyLeftShift] or window.buttonDown[KeyRightShift]
  for (key, dx, dy) in [
    (KeyW, 0, -1), (KeyUp, 0, -1),
    (KeyS, 0, 1), (KeyDown, 0, 1),
    (KeyA, -1, 0), (KeyLeft, -1, 0),
    (KeyD, 1, 0), (KeyRight, 1, 0)
  ]:
    if window.buttonPressed[key]:
      discard view.controls.step(view.world, dx, dy, half)
  if window.buttonPressed[MouseLeft]:
    let
      position = window.mousePos.vec2 / view.sk.uiScale - view.boardOrigin
      x = int(floor(position.x / view.cellSize))
      y = int(floor(position.y / view.cellSize))
    if x >= 0 and x < view.world.config.width and
      y >= 0 and y < view.world.config.height:
        let target = y * view.world.config.width + x
        if target == view.controls.selected:
          view.controls.clear(view.world)
        elif not view.controls.enqueue(view.world, target, half):
          view.controls.select(view.world, target)

proc capture(view: View) =
  ## Saves the rendered back buffer while preserving normal window cleanup.
  let image = newImage(view.window.size.x, view.window.size.y)
  glReadPixels(
    0,
    0,
    image.width.GLsizei,
    image.height.GLsizei,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    image.data[0].addr
  )
  image.flipVertical()
  image.writeFile(view.screenshot)
  view.closing = true

proc frame(view: View) =
  ## Advances bounded simulation time and draws one complete local frame.
  when defined(softmaxReplay):
    if view.remote and view.live.names.len == 0:
      return
  let
    now = getMonoTime()
    elapsed = min(0.25, (now - view.lastFrame).inNanoseconds.float64 / 1e9)
  view.lastFrame = now
  view.layout()
  view.sk.beginUi(view.window, view.window.size)
  view.handleInput()
  gameProfiles.profileBlock "game frame":
    if view.screen == GameScreen and view.replaying:
      if view.screenshot.len == 0:
        view.playReplay(elapsed)
    elif view.screen == GameScreen and not view.remote and not view.paused and
      not view.world.finished and view.screenshot.len == 0:
        view.elapsed += elapsed * view.initialSpeed.float64
        while view.elapsed >= TickSeconds:
          view.advance()
          view.elapsed -= TickSeconds
    view.sk.clearScreen(Background)
    view.buttonsEnabled = true
    case view.screen
    of MenuScreen:
      view.drawMenu()
    of HelpScreen:
      view.drawHelp()
    of GameScreen:
      view.buttonsEnabled = not view.outcomeOpen()
      view.drawBoard()
      view.drawScoreboard()
      view.drawTurn()
      when defined(softmaxReplay):
        if view.remote:
          var x = 120.0'f
          var y = 0.0'f
          if view.humanAlive():
            for (label, command) in [("Half [H]", "split"), ("Undo [E]", "undo"),
              ("Clear [Q]", "clear"), ("Hold", "pass"), ("Surrender", "surrender")]:
                if command == "surrender" and view.world.config.players < 3:
                  continue
                let width = view.sk.getTextSize("Hud", label).x + 20
                if x + width > (if view.stacked: view.size.x else: view.scoreboard.x):
                  x = 12
                  y += 34
                if view.button(label, vec2(x, y), "Hud", vec2(6)):
                  liveInput(command)
                x += width
            if view.live.ruleset == "build_castles" and
              view.button("Build [B]", vec2(x, y), "Hud", vec2(6)):
                liveInput("build")
          let statusWidth = if view.stacked: view.size.x - 24 else: view.scoreboard.x - 24
          view.label(view.fitted(view.live.status, statusWidth, "Hud"), vec2(12, 72), Ink, "Hud")
      view.drawChat()
      if view.replaying:
        view.transport.drawTransport(view.sk, view.window, GameUiPanel(
          origin: vec2(0, view.contentHeight()),
          size: vec2(view.size.x, replayTransportHeight(view.size.x))
        ))
      view.drawOutcome()
      view.drawReplayOutcome()
    silkyContexts.textInputs(view.sk).submitInput(
      view.window,
      "generals-chat",
      view.screen == GameScreen and view.editor.focused,
      true
    )
    view.chatFocusEpoch = silkyContexts.textInputs(view.sk).focusEpoch
    view.sk.endUi()
  inc view.frames
  if gameProfiles.profileShouldDump(view.frames):
    gameProfiles.finishProfileTrace()
  if view.screenshot.len > 0 and view.frames >= 3:
    view.capture()
  view.window.swapBuffers()
  when defined(softmaxReplay) and defined(emscripten):
    if view.remote:
      let tick = view.world.turn
      let skillScores = view.live.skills.join("|")
      let skills = skillScores.cstring
      {.emit: """
      EM_ASM({
        Module.liveFrameCount = (Module.liveFrameCount || 0) + 1;
        Module.liveTick = $0;
        Module.liveSkillScores = UTF8ToString($1).split('|');
        Module.polyworldFrame($0, 0);
      }, `tick`, `skills`);
      """.}
  if view.replaying:
    reportReplayFrame(view.world.turn.int32, 0)
    when defined(softmaxReplay) and defined(emscripten):
      let
        playing = view.transport.player.playing.int
        repeating = view.transport.player.repeating.int
        skillScores = view.replay.data.header.setup.skillScores.join("|")
        skillScoresCString = skillScores.cstring
        outcome =
          if view.world.turn == view.replay.data.hashes.len:
            view.winnerText()
          else:
            ""
        outcomeCString = outcome.cstring
      var messages: string
      for line in view.chatLines:
        for part in line.parts:
          messages.add(part.text)
        messages.add('\n')
      let messagesCString = messages.cstring
      {.emit: """
      EM_ASM({
        Module.replayFrameCount = (Module.replayFrameCount || 0) + 1;
        Module.replayPlaying = !!$0;
        Module.replayRepeating = !!$1;
        Module.replaySkillScores = UTF8ToString($2).split('|');
        Module.replayMessages = UTF8ToString($3);
        Module.replayOutcome = UTF8ToString($4);
      }, `playing`, `repeating`, `skillScoresCString`, `messagesCString`,
        `outcomeCString`);
      """.}

when defined(softmaxReplay) and defined(emscripten):
  include polyworld_live_view

proc runWindow(
    config: Config,
    assets: string,
    screenshot = "",
    autoTurns = 0,
    startGame = false,
    windowSize = ivec2(1280, 900),
    replayPath = "",
    recordPath = "",
    roster = defaultRoster(),
    botFiles = default(BotFiles),
    autoWidth = false,
    autoHeight = false,
    humanPlayer = 0,
    pauseOnStart = false,
    initialSpeed = 1,
    vsync = true,
    remote = false
) =
  ## Runs local games, hosted human seats and recordings with the shared theme.
  let
    window = newWindow(
      "Polyworld Generals",
      windowSize,
      visible = true,
      vsync = vsync
    )
  defer:
    gameProfiles.finishProfileTrace()
    gameProfiles.closeProfileViewer()
    window.onFrame = nil
    window.close()
  window.makeContextCurrent()
  loadExtensions()
  let builder = newAtlasBuilder(2048, 4)
  builder.addTheme(assets)
  builder.addArrows(assets)
  builder.addTransport(assets)
  for name in ["eye", "eye-dark"]:
    # The original 900 by 500 SVGs omit the viewBox required by Pixie.
    let
      source = readFile(assets / "images" / (name & ".svg")).replace(
        "<svg ", "<svg viewBox=\"0 0 900 500\" "
      )
      icon = newImage(parseSvg(source, 38, 24))
    if not builder.addImage(name, icon):
      raise newException(GeneralsError, "Cannot fit POV icon: " & name)
  let
    check = newImage(20, 20)
    path = newPath()
  path.moveTo(4, 10)
  path.lineTo(8, 14)
  path.lineTo(16, 5)
  check.strokePath(path, color(1, 1, 1, 1), strokeWidth = 3)
  if not builder.addImage("pov-check", check):
    raise newException(GeneralsError, "Cannot fit POV checkbox")
  for (name, file) in [
    ("crown", "crownie.png"),
    ("city", "citie.png"),
    ("mountain", "mountainie.png"),
    ("obstacle", "obstacle.png")
  ]:
    if not builder.addImage(name, readImage(assets / "images" / file)):
      raise newException(GeneralsError, "The game atlas is too small")
  let view = View(
    window: window,
    sk: newSilky(window, builder.atlasImage, builder.atlas),
    config: config,
    autoWidth: autoWidth,
    autoHeight: autoHeight,
    humanPlayer: humanPlayer,
    pauseOnStart: pauseOnStart,
    initialSpeed: initialSpeed,
    configuredRoster: roster,
    botFiles: botFiles,
    screenshot: screenshot,
    recordPath: recordPath,
    lastFrame: getMonoTime(),
    remote: remote
  )
  view.sk.applyTheme()
  defer:
    if recordPath.len > 0 and view.recording != nil:
      saveReplay(recordPath, view.recording.data)
  if replayPath.len > 0:
    view.startReplay(loadReplay(replayPath), autoTurns)
  elif remote:
    view.screen = GameScreen
  else:
    view.start()
    for i in 0 ..< autoTurns:
      view.advance(autoplay = true)
    if not startGame and not remote:
      view.screen = MenuScreen
  when defined(softmaxReplay) and defined(emscripten):
    if remote:
      liveView = view
      installLiveBridge()
  when gameProfiles.ProfileTracePath.len > 0:
    silkyProfiles.startRuntimeProfileTrace(gameProfiles.ProfileTracePath)
    gameProfiles.startProfileTrace()
  window.onFrame = proc() =
    ## Draws one frame without transferring ownership of the window.
    view.frame()
  while not window.closeRequested and not view.closing:
    pollEvents()
    waitForDisplay()

proc runGraphics*(
    config: Config,
    assets: string,
    screenshot = "",
    autoTurns = 0,
    startGame = false,
    windowSize = ivec2(1280, 900),
    replayPath = "",
    recordPath = "",
    roster = defaultRoster(),
    botFiles = default(BotFiles),
    autoWidth = false,
    autoHeight = false,
    humanPlayer = 0,
    pauseOnStart = false,
    initialSpeed = 1,
    vsync = true,
    remote = false
) =
  ## Maps asset and graphical failures to the game's public exception type.
  try:
    runWindow(
      config,
      assets,
      screenshot,
      autoTurns,
      startGame,
      windowSize,
      replayPath,
      recordPath,
      roster,
      botFiles,
      autoWidth,
      autoHeight,
      humanPlayer,
      pauseOnStart,
      initialSpeed,
      vsync,
      remote
    )
  except IOError, OSError, PixieError, SilkyError,
    SilkyAtlasError, WindyError:
      raise newException(
        GeneralsError,
        "Cannot run graphics: " & getCurrentExceptionMsg()
      )
