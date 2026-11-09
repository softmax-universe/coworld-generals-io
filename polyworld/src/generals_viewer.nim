import
  std/os,
  generals/[common, views]

proc main() =
  ## Opens server-driven play or verified recordings in the shared renderer.
  let arguments = commandLineParams()
  when defined(softmaxReplay) and defined(emscripten):
    if arguments == @["--live"]:
      runGraphics(defaultConfig(), "/assets", startGame = true, remote = true)
      return
  if arguments.len != 2 or arguments[0] != "--replay":
    raise newException(
      GeneralsError,
      "A replay URL is required. Open index.html#replay=URL."
    )
  runGraphics(
    defaultConfig(),
    "/assets",
    replayPath = arguments[1],
    humanPlayer = -1
  )

try:
  main()
except GeneralsError:
  quit("GeneralsError: " & getCurrentExceptionMsg(), QuitFailure)
