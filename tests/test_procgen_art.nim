## The board art ships, and it is the ONE list every consumer reads
## (`src/procgen/procgen_art.nim`): the Dockerfile.replay-viewer asset
## assertions, the renderer's preloader and this test.
##
## Every character sprite is a nano-banana render of the Softmax cog, split by
## `scripts/art/split_tile_sheet.py` from the committed source sheets. Nothing
## here is a procedural rig.

import std/[os, strutils]
import procgen/[levels, procgen_art, tiles]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

block:
  for file in allArtFiles():
    check fileExists("data" / file), "art: data/" & file & " ships"
    if fileExists("data" / file):
      check getFileSize("data" / file) > 0, "art: data/" & file & " is not empty"

block:
  ## Every tile the renderer can draw has a sprite name, and every sprite name
  ## is a file that ships.
  var files = allArtFiles()
  for t in Tile.low .. Tile.high:
    let name = spriteForTile(t)
    check (name & ".png") in files,
      "art: " & $t & " maps to " & name & ", which must ship"
  for kind in LevelKind.low .. LevelKind.high:
    check kindPalette(kind).len > 0, "art: " & $kind & " has a floor wash"

block:
  ## The source sheets and the split script are committed, so the kit can be
  ## regenerated rather than trusted.
  check dirExists("scripts/art/source"), "art: the source sheets are committed"
  check fileExists("scripts/art/split_tile_sheet.py"),
    "art: the split script is committed"
  var sheets = 0
  for _ in walkFiles("scripts/art/source/*.png"):
    inc sheets
  check sheets >= 1, "art: at least one source sheet ships"

block:
  ## The renderer's own preloader must name the same kit.
  ## The renderer preloads the SPRITE KIT. The floor wash, the palette and
  ## the font are not sprites: the wash and the palette are drawn
  ## procedurally in the bake's colours and the font is loaded as a FontFace.
  let core = readFile("client/broadcast_core.js")
  var kit = tileSpriteFiles()
  kit.add(entitySpriteFiles())
  kit.add(cogSpriteFiles())
  for file in kit:
    let name = file[0 ..< file.len - 4]
    check ("'" & name & "'") in core,
      "art: broadcast_core.js preloads " & name

if failures > 0:
  quit("test_procgen_art: " & $failures & " failures", 1)
echo "test_procgen_art: ok"
