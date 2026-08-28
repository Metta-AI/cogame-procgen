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

proc liveSplitBar(episode: Episode): JsonNode =
  ## The signature readout, live: one bar per level in play order, each the
  ## level's return out of 1000, seen in slate and unseen in amber, with the
  ## two mean lines. `broadcast.nim` builds the same document from the replay
  ## pre-scan; `broadcast_core.js`'s `drawSplitBar` reads it fresh on EVERY
  ## frame, so the live one fills in as levels complete.
  var bars = newJArray()
  var start = 0
  for i in 0 ..< episode.plan.len:
    bars.add(%*{
      "level": i + 1,
      "kind": $episode.plan[i].kind,
      "split": $episode.plan[i].split,
      "seed": episode.plan[i].seed,
      "return": episode.returns[i],
      "outcome": $episode.outcomes[i],
      "start": start
    })
    start = start + episode.levelFrames[i]
  %*{
    "bars": bars,
    "seenMilli": episode.seenMilli(),
    "unseenMilli": episode.unseenMilli(),
    "gapMilli": episode.gap()
  }

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
  var bubbles = newJArray()
  if episode.seat.say.len > 0 and episode.seat.sayFramesLeft > 0:
    bubbles.add(%*{"text": episode.seat.say, "x": st.cog.x, "y": st.cog.y})
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
    # The say the seat asked for, drawn above the cog for `sayFrames` frames
    # — `applyPlan` counts `sayFramesLeft` down, one per frame it runs.
    "bubbles": bubbles,
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
      "splitbar": liveSplitBar(episode),
      # No `lead`: `chrome_common.js`'s `ingestLeadSeries` takes the series
      # ONCE and never re-reads it, so a live stream — which cannot know the
      # running means before the levels are played — would pin the momentum
      # graph to the zeroes of its first frame. The replay path ships the
      # whole series from the pre-scan, which is what that field is for.
      "feed": newJArray(),
      "results": newJNull()
    }
  })
