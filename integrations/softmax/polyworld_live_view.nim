## Included by the shared Silky view; no alternate board renderer or simulation.
var liveView: View

proc updateLive(encoded: cstring) {.cdecl, exportc: "generals_live_update",
    codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
  let state = parseLiveSnapshot($encoded)
  assert state.width in 1 .. 100 and state.height in 1 .. 100
  assert state.names.len in 2 .. MaxPlayers
  assert state.skills.len == state.names.len
  assert state.army.len == state.names.len and state.land.len == state.names.len
  assert state.alive.len == state.names.len
  assert state.slot in 0 ..< state.names.len
  assert state.types.len == state.height and state.owners.len == state.height
  assert state.armies.len == state.height and state.knownTypes.len == state.height
  let view = liveView
  view.live = state
  view.humanPlayer = state.slot
  view.world.config.width = state.width
  view.world.config.height = state.height
  view.world.config.players = state.names.len
  view.world.turn = state.tick
  view.world.finished = state.finished
  view.world.winner = state.winner
  view.world.alive = state.alive
  view.world.generals = newSeq[int](state.names.len)
  view.world.tiles.setLen(state.width * state.height)
  view.visible.setLen(view.world.tiles.len)
  for player, name in state.names:
    view.roster.players[player].name = name
    view.world.generals[player] = -1
  for y in 0 ..< state.height:
    assert state.types[y].len == state.width and state.owners[y].len == state.width
    assert state.armies[y].len == state.width and state.knownTypes[y].len == state.width
    for x in 0 ..< state.width:
      let index = y * state.width + x
      let kind = state.types[y][x]
      assert kind in 0 .. 5 and state.owners[y][x] in 0 .. state.names.len
      view.visible[index] = kind notin {0, 5}
      view.world.tiles[index] = Tile(
        kind: case state.knownTypes[y][x]
          of 2, 5: Mountain
          of 3: City
          of 4: General
          else: Plain,
        owner: (state.owners[y][x] - 1).int8,
        army: state.armies[y][x]
      )
      if kind == 4 and state.owners[y][x] > 0:
        view.world.generals[state.owners[y][x] - 1] = index
  view.controls = newControls(state.selected, state.slot)
  view.controls.selected = state.selected
  view.controls.half = state.half
  for order in state.orders:
    assert order.source in 0 ..< view.world.tiles.len
    assert order.target in 0 ..< view.world.tiles.len
    view.controls.moves.add(Move(source: order.source, target: order.target, half: order.half))
  view.log.entries.setLen(0)
  for text in state.messages:
    view.log.entries.add(LogEntry(kind: Notice, player: -1, text: text))
  view.chatDirty = true

proc installLiveBridge() =
  {.emit: """
  EM_ASM({
    Module.polyworldLiveUpdate = text => {
      const size = lengthBytesUTF8(text) + 1;
      const pointer = _malloc(size);
      try {
        stringToUTF8(text, pointer, size);
        _generals_live_update(pointer);
      } finally { _free(pointer); }
    };
    if (Module.pendingLiveSnapshot) Module.polyworldLiveUpdate(Module.pendingLiveSnapshot);
    parent.postMessage({src: 'coworld-replay', type: 'phase', phase: 'live_ready'}, location.origin);
  });
  """.}
