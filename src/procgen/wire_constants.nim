## The JS wire-constants block: the handful of engine constants the browser
## chrome must agree with (playback speeds, fps, the board, the tile glyphs).
## Historically each HTML client re-typed these as literals and nothing
## enforced agreement. This module renders them ONCE, from the same Nim consts
## the engine runs on; `server.nim` splices the block into every served client
## page, and `tools/gen_wire_constants.nim` emits it for the static wasm
## bundle. Clients read `window.PROCGEN_WIRE`.

import std/strutils
import levels, sim_types, tiles

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

proc jsStrArray(values: openArray[string]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add "\"" & v & "\""
  result.add "]"

proc tileNames(): seq[string] =
  for t in Tile.low .. Tile.high:
    result.add($t)

proc tileGlyphs(): seq[string] =
  for t in Tile.low .. Tile.high:
    result.add($t.glyph())

proc kindNames(): seq[string] =
  for k in LevelKind.low .. LevelKind.high:
    result.add($k)

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder the client HTML carries where the block belongs (before
  ## any script that reads window.PROCGEN_WIRE).

proc wireConstantsJs*(): string =
  "window.PROCGEN_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
  ",fps:" & $TargetFps &
  ",seats:" & $Seats &
  ",maxSayRunes:" & $MaxSayRunes &
  ",boardW:" & $BoardW &
  ",boardH:" & $BoardH &
  ",cellPx:" & $CellPx &
  ",alphabet:\"" & ActionAlphabet & "\"" &
  ",tiles:" & jsStrArray(tileNames()) &
  ",glyphs:" & jsStrArray(tileGlyphs()) &
  ",kinds:" & jsStrArray(kindNames()) &
  ",aliases:" & jsStrArray(["COG-alpha"]) &
  "};"

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & wireConstantsJs() & "</script>")
