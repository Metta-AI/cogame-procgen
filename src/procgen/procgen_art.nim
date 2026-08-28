## The board-art manifest.
##
## `coworld-ctf`'s `rig_art.nim` bakes its rig segments server-side into the
## sprite protocol. This fork draws the grid in the browser, so the bake is
## the browser's: this module is the SINGLE list of the shipped sprite files,
## shared by `Dockerfile.replay-viewer`'s asset assertions, the viewer's
## preloader (through `wire_constants`) and `tests/test_procgen_art.nim`.
##
## Every character sprite is a nano-banana render of the Softmax cog
## (`scripts/art/source/*.png`), split by
## `scripts/art/split_tile_sheet.py`. Nothing here is a procedural rig.

import levels, tiles

const
  TileSprites* = ["bedrock", "dirt", "platform", "ladder", "spike", "floor",
                  "exit_locked", "exit_open"]
  EntitySprites* = ["gem", "pellet", "boulder", "boulder_falling",
                    "hunter_l", "hunter_r", "hunter_u", "hunter_d"]
  CogSprites* = ["cog_l", "cog_r", "cog_u", "cog_d", "cog_jump", "cog_dig"]

proc tileSpriteFiles*(): seq[string] =
  for name in TileSprites:
    result.add("tile_" & name & ".png")

proc entitySpriteFiles*(): seq[string] =
  for name in EntitySprites:
    result.add("ent_" & name & ".png")

proc cogSpriteFiles*(): seq[string] =
  for name in CogSprites:
    result.add(name & ".png")

proc allArtFiles*(): seq[string] =
  result = tileSpriteFiles()
  result.add(entitySpriteFiles())
  result.add(cogSpriteFiles())
  result.add("arena_floor.png")
  result.add("pallete.png")
  result.add("font.ttf")

proc spriteForTile*(t: Tile): string =
  ## The one mapping from a tile to its sprite file, read by the renderer's
  ## preloader and asserted by the art test.
  case t
  of tWall: "tile_bedrock"
  of tDirt: "tile_dirt"
  of tPlatform: "tile_platform"
  of tLadder: "tile_ladder"
  of tSpike: "tile_spike"
  of tExitLocked: "tile_exit_locked"
  of tExitOpen: "tile_exit_open"
  of tGem: "ent_gem"
  of tPellet: "ent_pellet"
  of tBoulder: "ent_boulder"
  of tEmpty: "tile_floor"

proc kindPalette*(kind: LevelKind): string =
  ## The floor wash each archetype is drawn on, so the four read apart at a
  ## glance without a label.
  case kind
  of lkMaze: "slate"
  of lkChaser: "rust"
  of lkClimber: "steel"
  of lkMiner: "amber"
