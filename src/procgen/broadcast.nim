## The broadcast packet: one JSON frame the viewer draws, and the chrome
## document the page's classic scorebug / clock / transport / scrubber /
## endcard read.
##
## `coworld-ctf` smuggles its chrome JSON through a reserved sprite label on
## the binary sprite channel; this fork carries it as a field of the same
## frame packet, for the same reason: the chrome must survive every playback
## path (live serve and hosted static replay) rather than riding a separate
## interactive text channel that a recorded stream never replays.
##
## `stepEvents` derives the broadcast events from state deltas during
## playback, so they cost no replay bytes and are identical live and in
## replay.

import std/[json, strutils, tables]
import events, labels, levels, replay_runtime, sim, tiles

proc stepEvents*(rt: ReplayRuntime, step: int): seq[FrameEvent] =
  ## Every event whose absolute frame is exactly `step`.
  for e in rt.events:
    if e.abs == step:
      result.add(e)

proc levelIndexAt(rt: ReplayRuntime, step: int): int =
  if step < 0 or step >= rt.snapshots.len: 0 else: rt.snapshots[step].level

proc splitOf(rt: ReplayRuntime, level: int): string =
  if level >= 1 and level <= rt.episode.plan.len:
    $rt.episode.plan[level - 1].split
  else:
    ""

proc seedOf(rt: ReplayRuntime, level: int): int =
  if level >= 1 and level <= rt.episode.plan.len:
    rt.episode.plan[level - 1].seed
  else:
    0

proc runningMeans(rt: ReplayRuntime): JsonNode =
  ## The momentum series the split bar and the `#momentum` SVG share: the
  ## running seen and unseen means at every level end. Shipped ONCE, so the
  ## graph spans the whole timeline from the first drawn frame.
  var pts = newJArray()
  pts.add(%[0, 0, 0])
  var
    seenTotal, seenCount, unseenTotal, unseenCount = 0
  for i in 0 ..< rt.episode.plan.len:
    if rt.episode.plan[i].split == spSeen:
      seenTotal = seenTotal + rt.levelReturns[i]
      inc seenCount
    else:
      unseenTotal = unseenTotal + rt.levelReturns[i]
      inc unseenCount
    let frame =
      if i + 1 < rt.levelStartFrames.len: rt.levelStartFrames[i + 1]
      else: max(1, rt.snapshots.len - 1)
    pts.add(%[frame,
      (if seenCount > 0: seenTotal div seenCount else: 0),
      (if unseenCount > 0: unseenTotal div unseenCount else: 0)])
  %*{"teams": ["seen", "unseen"], "pts": pts}

proc splitBarJson(rt: ReplayRuntime): JsonNode =
  ## The idea's "seen levels vs unseen split score", drawn literally: one bar
  ## per level in play order, each the level's return out of 1000, seen bars
  ## in slate and unseen bars in amber, with the two mean lines.
  var bars = newJArray()
  for i in 0 ..< rt.episode.plan.len:
    bars.add(%*{
      "level": i + 1,
      "kind": $rt.episode.plan[i].kind,
      "split": $rt.episode.plan[i].split,
      "seed": rt.episode.plan[i].seed,
      "return": rt.levelReturns[i],
      "outcome": rt.levelOutcomes[i],
      "start": (if i < rt.levelStartFrames.len: rt.levelStartFrames[i] else: 0)
    })
  %*{
    "bars": bars,
    "seenMilli": rt.episode.seenMilli(),
    "unseenMilli": rt.episode.unseenMilli(),
    "gapMilli": rt.episode.gap()
  }

proc chromeJson*(rt: ReplayRuntime, step: int): JsonNode =
  ## The classic broadcast chrome document. Field names are the starter's, so
  ## `chrome_common.js` — copied BYTE-FOR-BYTE — reads it unchanged:
  ## `t`/`st`/`mx`/`mt` are the timeline, `ph` the phase, `sp`/`pl`/`lp`/`sk`/
  ## `ff`/`en` the transport, `roster` the seat, `beats` the up-front scrubber
  ## timeline, `lulls` the quiet spans and `lead` the momentum series.
  let
    snap = rt.snapshots[step]
    steps = rt.snapshots.len - 1
    level = snap.level
  var roster = newJArray()
  roster.add(%*{
    "s": 0,
    "name": rt.name,
    "alias": cogAlias(0),
    "kind": rt.policyKind,
    "level": level,
    "of": rt.episode.plan.len,
    "split": rt.splitOf(level),
    "collected": snap.collected,
    "total": snap.collectTotal,
    "alive": snap.alive,
    "fallback": rt.fallbacks.len > 0
  })
  var beats = newJArray()
  for b in rt.beats:
    beats.add(%*{"t": b.frame, "k": b.kind, "label": b.label})
  var lulls = newJArray()
  for span in rt.lulls:
    lulls.add(%[span[0], span[1]])
  var feed = newJArray()
  for e in stepEvents(rt, step):
    let outcome =
      if e.level >= 1 and e.level <= rt.levelOutcomes.len:
        parseEnum[LevelOutcome](rt.levelOutcomes[e.level - 1], loUnplayed)
      else: loUnplayed
    let row = feedRow(e, snap.kind, outcome)
    if row.len > 0:
      feed.add(%*{"k": $e.kind, "row": row})
  let phase =
    if step == 0: "lobby"
    elif step >= steps: "gameover"
    else: "playing"
  result = %*{
    "t": step,
    "st": 0,
    "mx": max(1, steps),
    "mt": 0,
    "ph": phase,
    "lob": 0,
    "sp": rt.displaySpeed(),
    "pl": rt.playback.playing,
    "lp": rt.playback.loop,
    "sk": rt.playback.skipLulls,
    "ff": rt.playback.fastForward,
    "en": true,
    "over": step >= steps,
    "level": level,
    "levels": rt.episode.plan.len,
    "kind": $snap.kind,
    "split": rt.splitOf(level),
    "seed": rt.seedOf(level),
    "difficulty": normalizedDifficulty(rt.config.difficulty),
    "turn": snap.turn,
    "turns": rt.config.turnsPerLevel,
    "frame": snap.frameInLevel,
    "collected": snap.collected,
    "total": snap.collectTotal,
    "gauntletLine": rt.episode.gauntletLine(),
    "mismatch": rt.mismatchFrame,
    "roster": roster,
    "beats": beats,
    "lulls": lulls,
    "lead": runningMeans(rt),
    "splitbar": splitBarJson(rt),
    "feed": feed,
    "results": (if rt.resultsJson.len > 0: parseJson(rt.resultsJson)
                else: newJNull())
  }

proc framePacket*(rt: ReplayRuntime): string =
  ## One drawn frame. `alpha` is the interpolation phase inside the sim frame,
  ## so the cog glides from its previous cell to its current one instead of
  ## teleporting.
  let
    perStep = max(1, rt.playback.framesPerStep)
    step = rt.stepAt(rt.playback.frame)
    within = rt.playback.frame - step * perStep
    snap = rt.snapshots[step]
    prev = rt.snapshots[max(0, step - 1)]
  var alpha = 1000
  if step > 0 and within < perStep:
    alpha = (within * 1000) div perStep
  var grid = newJArray()
  for index in 0 ..< BoardCells:
    grid.add(%ord(snap.grid.cells[index]))
  var hunters = newJArray()
  for h in snap.hunters:
    hunters.add(%[h.x, h.y])
  var falling = newJArray()
  for f in snap.falling:
    falling.add(%[f.x, f.y])
  var bubbles = newJArray()
  var back = 0
  while back < max(1, rt.config.sayFrames) and step - back >= 0:
    let key = step - back
    if rt.says.hasKey(key):
      bubbles.add(%*{
        "text": rt.says[key], "x": snap.cog.x, "y": snap.cog.y})
      break
    inc back
  var flashes = newJArray()
  for e in stepEvents(rt, step):
    if e.kind in {ekCollect, ekDeath, ekExitOpen, ekPush, ekDig}:
      flashes.add(%*{"k": $e.kind, "x": e.at.x, "y": e.at.y})
  $(%*{
    "protocol": ProtocolName,
    "board": {"w": BoardW, "h": BoardH, "cellPx": CellPx},
    "alpha": alpha,
    "grid": grid,
    "cog": {
      "x": snap.cog.x, "y": snap.cog.y,
      "px": prev.cog.x, "py": prev.cog.y,
      "dir": ord(snap.lastDir), "alive": snap.alive,
      "jump": snap.jumpFuel, "fall": snap.fallDepth,
      "dash": snap.dashCooldown, "finished": snap.finished,
      "death": snap.deathCause
    },
    "hunters": hunters,
    "falling": falling,
    "exit": {"x": snap.exitAt.x, "y": snap.exitAt.y, "open": snap.exitOpen},
    "collected": snap.collected,
    "total": snap.collectTotal,
    "plan": {"moves": snap.plan, "run": snap.planRun,
             "cut": snap.interrupted},
    "bubbles": bubbles,
    "flashes": flashes,
    "chrome": chromeJson(rt, step)
  })
