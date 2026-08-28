import
  std/json,
  procgen/[broadcast, replay_runtime, replays, sim]

var
  runtimeLoaded = false
  runtime: ReplayRuntime
  packet: string
  lastError: string

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 — allocation failure aborts the runtime loudly —
## and this fixed buffer, stamped BEFORE each risky phase, stays readable from
## JS after the abort (aborting kills the call stack, not the linear memory),
## so the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string  ## prebuilt once per load; re-stamped every frame

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent() =
  packet = framePacket(runtime)

proc procgenLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "procgen_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let bytes = data.bytesFromPointer(int(length))
    stampStage("initialize replay runtime")
    ## The LOAD-TIME PRE-SCAN: RE-GENERATE all eight levels from their seeds
    ## and re-simulate the whole episode once headlessly (at most 480 frames
    ## of integer work over 135 tiles, plus one bounded search per frame) and
    ## record the per-level return series, the per-level frame spans, every
    ## beat frame and the lull spans. That is what lets the SPLIT BAR, the
    ## clock and the scrubber beats draw at FULL WIDTH on the first frame
    ## instead of growing in.
    runtime = loadReplay(bytes)
    runtimeLoaded = true
    let note = " (" & $runtime.episode.plan.len & " levels, " &
      $runtime.replay.frames.len & " frames)"
    frameStage = "advance replay" & note
    stampStage("render first frame" & note)
    renderCurrent()
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc procgenInput(data: ptr uint8, length: cint)
    {.exportc: "procgen_input", cdecl.} =
  if runtimeLoaded:
    runtime.command(data.bytesFromPointer(int(length)))

proc procgenFrame(): cint {.exportc: "procgen_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    runtime.advance()
    renderCurrent()
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc procgenPacketPointer(): ptr uint8
    {.exportc: "procgen_packet_ptr", cdecl.} =
  if packet.len == 0:
    nil
  else:
    cast[ptr uint8](packet[0].addr)

proc procgenPacketLength(): cint {.exportc: "procgen_packet_len", cdecl.} =
  cint(packet.len)

proc procgenMismatchTick(): cint {.exportc: "procgen_mismatch_tick", cdecl.} =
  if runtimeLoaded:
    cint(runtime.mismatchFrame)
  else:
    -1

proc procgenErrorPointer(): ptr uint8 {.exportc: "procgen_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc procgenErrorLength(): cint {.exportc: "procgen_error_len", cdecl.} =
  cint(lastError.len)

proc procgenStagePointer(): ptr uint8 {.exportc: "procgen_stage_ptr", cdecl.} =
  ## The progress note (see stageNote above). Unlike procgen_error_*, this stays
  ## valid after an allocation-failure abort, so JS can report what the
  ## runtime was doing when the address space ran out.
  if stageNoteLen == 0:
    nil
  else:
    cast[ptr uint8](stageNote[0].addr)

proc procgenStageLength(): cint {.exportc: "procgen_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the replay runtime while the wasm module stays alive and JS keeps
  # calling procgen_load_replay / procgen_frame. The whole session then runs on
  # freed globals. Unwinding main through emscripten's live-runtime exit skips
  # the destructor epilogue entirely, so globals stay valid for the life of
  # the page.
  emscriptenExitWithLiveRuntime()
