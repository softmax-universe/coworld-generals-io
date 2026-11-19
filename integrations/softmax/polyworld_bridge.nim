## Private JSONL transport for the authoritative Polyworld simulation.
import std/[json, sequtils, os, strutils]
import generals/[common, replays, players]
import polyworld_hosted

if paramCount() == 1 and paramStr(1) == "--encode-replay":
  stdout.write(encodeHostedReplay(parseJson(stdin.readAll())))
  quit(0)
if paramCount() == 2 and paramStr(1) == "--inspect-replay":
  let data = loadReplay(paramStr(2))
  let replay = newReplayPlayer(data)
  var state = newReplayWorld(data)
  var moves: array[MaxPlayers, Move]
  while replay.replayTick(state, moves): discard
  var names: seq[string]
  for slot in 0 ..< data.config.players:
    names.add(data.header.setup.roster.displayName(slot))
  var
    chats = newJArray()
    stream = newJArray()
  for action in data.actions:
    stream.add(%*{"kind": (if action.kind == ChatAction: "chat" else: "move"),
      "tick": action.tick, "player": action.player, "text": action.text})
    if action.kind == ChatAction:
      chats.add(%*{"tick": action.tick, "player": action.player,
        "text": action.text})
  stdout.writeLine($(%*{"format": ReplayMagic, "game": ReplayGame,
    "game_version": ReplayGameVersion, "turns": state.turn,
    "seed": $data.config.seed,
    "players": names, "skill_scores": data.header.setup.skillScores,
    "final_hash": state.hostedHash(),
    "first_hash": (if data.hashes.len > 0: data.hashes[0] else: data.header.setup.mapHash).toHex(16),
    "actions": data.actions.len, "chats": chats, "stream": stream}))
  quit(0)

var world: World

proc snapshot(report: StepReport): JsonNode =
  result = %*{
    "hash": world.hostedHash(),
    "turn": world.turn,
    "winner": world.winner,
    "width": world.config.width,
    "height": world.config.height,
    "alive": world.alive,
    "kinds": world.tiles.mapIt(it.kind.ord),
    "owners": world.tiles.mapIt(it.owner.int),
    "armies": world.tiles.mapIt(it.army),
    "executed": report.executed,
    "captured_by": report.capturedBy,
    "elimination_order": report.eliminationOrder,
    "damage": report.damage
  }

for line in stdin.lines:
  let request = parseJson(line)
  var report: StepReport
  report = world.applyHosted(request)
  stdout.writeLine($snapshot(report))
  stdout.flushFile()
