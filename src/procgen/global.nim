## The live `/global` spectator stream.
##
## `coworld-ctf`'s `global.nim` composes the whole board into the bitworld
## sprite protocol; this fork's board is a 15 x 9 integer grid drawn in the
## browser from a JSON frame, so every weapon, paint, flag, hill and
## first-person draw path is deleted with its wire fields (design note
## §Sim module -> The named edits). What survives is the contract: `/global`
## answers with a first message immediately, broadcasts are fire-and-forget so
## a slow viewer can never stall the episode, and the state carries the level.

import std/json
import levels, sim, tiles

proc liveStateJson*(episode: Episode, playing: bool): string =
  ## The live broadcast state. Same field names as the replay chrome document
  ## so the page has one code path.
  let st = episode.level
  var grid = newJArray()
  for index in 0 ..< BoardCells:
    grid.add(%ord(st.grid.cells[index]))
  var hunters = newJArray()
  for h in st.hunters:
    hunters.add(%[h.x, h.y])
  var falling = newJArray()
  if st.falling.len == BoardCells:
    for index in 0 ..< BoardCells:
      if st.falling[index]:
        let c = cellAt(index)
        falling.add(%[c.x, c.y])
  var roster = newJArray()
  roster.add(%*{
    "s": 0, "name": episode.seat.name, "alias": cogAlias(0),
    "kind": episode.seat.policyKind, "level": episode.levelIndex,
    "of": episode.plan.len,
    "split": (if episode.levelIndex >= 1: $episode.currentPlanned().split
              else: ""),
    "collected": st.collected, "total": st.collectTotal,
    "alive": st.alive, "fallback": episode.seat.fallbackTurns > 0
  })
  $(%*{
    "protocol": ProtocolName,
    "board": {"w": BoardW, "h": BoardH, "cellPx": CellPx},
    "alpha": 1000,
    "grid": grid,
    "cog": {
      "x": st.cog.x, "y": st.cog.y, "px": st.cog.x, "py": st.cog.y,
      "dir": ord(st.lastDir), "alive": st.alive, "jump": st.jumpFuel,
      "fall": st.fallDepth, "dash": st.dashCooldown,
      "finished": st.finished, "death": $st.deathCause
    },
    "hunters": hunters,
    "falling": falling,
    "exit": {"x": st.exitAt.x, "y": st.exitAt.y,
             "open": st.grid.at(st.exitAt) == tExitOpen},
    "collected": st.collected,
    "total": st.collectTotal,
    "plan": {"moves": "", "run": 0, "cut": false},
    "bubbles": newJArray(),
    "flashes": newJArray(),
    "chrome": {
      "t": episode.totalFrames,
      "st": 0,
      "mx": max(1, episode.config.levelCount * episode.config.turnsPerLevel *
        episode.config.framesPerTurn),
      "mt": 0,
      "ph": (if episode.over: "gameover"
             elif episode.levelIndex == 0: "lobby" else: "playing"),
      "lob": 0, "sp": 1, "pl": playing, "lp": false, "sk": false,
      "ff": false, "en": false, "over": episode.over,
      "level": episode.levelIndex,
      "levels": episode.plan.len,
      "kind": $st.kind,
      "split": (if episode.levelIndex >= 1: $episode.currentPlanned().split
                else: ""),
      "seed": (if episode.levelIndex >= 1: episode.currentPlanned().seed
               else: 0),
      "difficulty": normalizedDifficulty(episode.config.difficulty),
      "turn": st.levelTurn,
      "turns": episode.config.turnsPerLevel,
      "frame": st.frame,
      "collected": st.collected,
      "total": st.collectTotal,
      "gauntletLine": episode.gauntletLine(),
      "mismatch": -1,
      "roster": roster,
      "beats": newJArray(),
      "lulls": newJArray(),
      "feed": newJArray(),
      "results": newJNull()
    }
  })
