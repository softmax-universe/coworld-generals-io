## Public, fog-filtered display state. The server and browser transport own play.
import std/[json, jsonutils]

when defined(emscripten):
  {.emit: "#include <emscripten.h>".}

type
  LiveOrder* = object
    source*, target*: int
    half*: bool
  LiveSnapshot* = object
    width*, height*, slot*, tick*, selected*, winner*: int
    half*, finished*: bool
    types*, knownTypes*, owners*, armies*: seq[seq[int]]
    army*, land*: seq[int]
    alive*: seq[bool]
    names*, skills*, messages*: seq[string]
    orders*: seq[LiveOrder]
    status*, ruleset*: string

proc liveInput*(kind: string, value = 0, half = false, text = "") =
  ## Emits input to the sole queue owner; never advances a local simulation.
  when defined(emscripten):
    let encoded = $(%*{"kind": kind, "value": value, "half": half, "text": text})
    let payload = encoded.cstring
    {.emit: """
    EM_ASM({
      parent.postMessage({type: 'polyworld-live-input', input: JSON.parse(UTF8ToString($0))}, location.origin);
    }, `payload`);
    """.}

proc parseLiveSnapshot*(encoded: string): LiveSnapshot =
  parseJson(encoded).to(LiveSnapshot)
