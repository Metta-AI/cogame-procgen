## The binary `COWLDPGN` replay: the starter's format, retargeted.
##
## `coworld-ctf`'s `replays.nim` writes a binary `COWLD…` stream of recorded
## inputs plus a per-tick hash; this fork keeps exactly that shape. The static
## wasm viewer parses these bytes and re-simulates with the SAME sim module,
## so everything the viewer needs is in the file and no server is contacted
## except S3 for it.
##
## Layout (little-endian; `str` is a u32 length followed by that many bytes):
##
##   magic "COWLDPGN"        8 bytes
##   u32   format version
##   str   game name         "procgen"
##   str   game version
##   str   config JSON       seed, variant, difficulty, levelKinds,
##                           levelSeeds, levelSplit, the cadence constants,
##                           players[].name (REAL names), aliases
##   u32   join count        then per join: u32 slot, str name, str token
##   u32   frame count       then per frame: one ACTION BYTE
##                           (0=L 1=R 2=U 3=D 4=X 5=. 255=level boundary)
##                           and a u64 gameHash
##   u32   chat count        then per record: str
##
## THE LEVEL GRIDS ARE NOT RECORDED and do not need to be:
## `generateLevel(kind, seed, difficulty)` is a pure function, so the wasm
## module re-generates all eight levels from `levelKinds` + `levelSeeds` +
## `difficulty`, and the per-frame `gameHash` proves it — which is exactly the
## "deterministic replay verification" the idea's integrity note asks for.

import std/json
import sim, sim_types, tiles

type
  ReplayFrame* = object
    action*: uint8
    hash*: uint64

  Replay* = object
    gameName*: string
    gameVersion*: string
    configJson*: string
    joins*: seq[tuple[slot: int, name, token: string]]
    frames*: seq[ReplayFrame]
    chats*: seq[string]

proc putU32(buffer: var string, value: uint32) =
  buffer.add(chr(int(value and 0xFF'u32)))
  buffer.add(chr(int((value shr 8) and 0xFF'u32)))
  buffer.add(chr(int((value shr 16) and 0xFF'u32)))
  buffer.add(chr(int((value shr 24) and 0xFF'u32)))

proc putU64(buffer: var string, value: uint64) =
  putU32(buffer, uint32(value and 0xFFFFFFFF'u64))
  putU32(buffer, uint32((value shr 32) and 0xFFFFFFFF'u64))

proc putStr(buffer: var string, value: string) =
  putU32(buffer, uint32(value.len))
  buffer.add(value)

type Reader = object
  data: string
  pos: int

proc need(reader: var Reader, count: int) =
  if reader.pos + count > reader.data.len:
    raise newException(ProcgenError, "replay truncated")

proc getU32(reader: var Reader): uint32 =
  reader.need(4)
  result = uint32(ord(reader.data[reader.pos])) or
    (uint32(ord(reader.data[reader.pos + 1])) shl 8) or
    (uint32(ord(reader.data[reader.pos + 2])) shl 16) or
    (uint32(ord(reader.data[reader.pos + 3])) shl 24)
  reader.pos += 4

proc getU64(reader: var Reader): uint64 =
  let lo = reader.getU32()
  let hi = reader.getU32()
  uint64(lo) or (uint64(hi) shl 32)

proc getStr(reader: var Reader): string =
  let length = int(reader.getU32())
  reader.need(length)
  result = reader.data[reader.pos ..< reader.pos + length]
  reader.pos += length

proc variantOf*(episode: Episode): string =
  if episode.plan.len == 4: "sprint"
  elif normalizedDifficulty(episode.config.difficulty) == "hard": "hardpool"
  else: "gauntlet"

proc replayConfigJson*(episode: Episode): string =
  ## The self-sufficient config document. `players[].name` carries the REAL
  ## policy name — spectator side only; a seat never sees this, and neither
  ## `levelSplit` nor `levelSeeds` ever reaches an observation.
  var
    players = newJArray()
    aliases = newJArray()
    kinds = newJArray()
    seedsJson = newJArray()
    splits = newJArray()
  players.add(%*{"name": episode.seat.name})
  aliases.add(%cogAlias(0))
  for planned in episode.plan:
    kinds.add(%($planned.kind))
    seedsJson.add(%planned.seed)
    splits.add(%($planned.split))
  $(%*{
    "protocol": ProtocolName,
    "seed": episode.config.seed,
    "variant": episode.variantOf(),
    "difficulty": normalizedDifficulty(episode.config.difficulty),
    "levelCount": episode.plan.len,
    "turnsPerLevel": episode.config.turnsPerLevel,
    "framesPerTurn": episode.config.framesPerTurn,
    "boardW": BoardW,
    "boardH": BoardH,
    "cellPx": CellPx,
    "levelKinds": kinds,
    "levelSeeds": seedsJson,
    "levelSplit": splits,
    "interruptOnDanger": episode.config.interruptOnDanger,
    "fallLethal": episode.config.fallLethal,
    "num_agents": Seats,
    "players": players,
    "aliases": aliases,
    "policyKinds": [episode.seat.policyKind],
    "renderFramesPerStep": episode.config.renderFramesPerStep,
    "sayFrames": episode.config.sayFrames,
    "attempt1Ms": episode.config.attempt1Ms,
    "retryMs": episode.config.retryMs,
    "turnBudgetMs": episode.config.turnBudgetMs,
    "turnSpacingMs": episode.config.turnSpacingMs,
    "wallClockBudgetSeconds": episode.config.wallClockBudgetSeconds,
    "gameOverFrames": episode.config.gameOverFrames,
    "fastMode": episode.config.fastMode,
    "showPlayerLabels": episode.config.showPlayerLabels
  })

proc encodeReplay*(replay: Replay): string =
  result = ReplayMagic
  putU32(result, uint32(ReplayFormatVersion))
  putStr(result, replay.gameName)
  putStr(result, replay.gameVersion)
  putStr(result, replay.configJson)
  putU32(result, uint32(replay.joins.len))
  for join in replay.joins:
    putU32(result, uint32(join.slot))
    putStr(result, join.name)
    putStr(result, join.token)
  putU32(result, uint32(replay.frames.len))
  for f in replay.frames:
    result.add(chr(int(f.action)))
    putU64(result, f.hash)
  putU32(result, uint32(replay.chats.len))
  for record in replay.chats:
    putStr(result, record)

proc decodeReplay*(bytes: string): Replay =
  if bytes.len < ReplayMagic.len or
      bytes[0 ..< ReplayMagic.len] != ReplayMagic:
    raise newException(ProcgenError,
      "not a procgen replay: bad magic (expected " & ReplayMagic & ")")
  var reader = Reader(data: bytes, pos: ReplayMagic.len)
  let version = int(reader.getU32())
  if version != ReplayFormatVersion:
    raise newException(ProcgenError,
      "replay format version " & $version & " is not " &
      $ReplayFormatVersion)
  result.gameName = reader.getStr()
  result.gameVersion = reader.getStr()
  result.configJson = reader.getStr()
  let joins = int(reader.getU32())
  for _ in 0 ..< joins:
    let slot = int(reader.getU32())
    let name = reader.getStr()
    let token = reader.getStr()
    result.joins.add((slot, name, token))
  let frames = int(reader.getU32())
  for _ in 0 ..< frames:
    var f: ReplayFrame
    reader.need(1)
    f.action = uint8(ord(reader.data[reader.pos]))
    reader.pos += 1
    f.hash = reader.getU64()
    result.frames.add(f)
  let chats = int(reader.getU32())
  for _ in 0 ..< chats:
    result.chats.add(reader.getStr())

proc configOf*(replay: Replay): GameConfig =
  ## The replay's own config document, rebuilt into a `GameConfig`. Used by
  ## the wasm viewer to re-simulate the episode from the bytes alone.
  result = defaultGameConfig()
  let node = parseJson(replay.configJson)
  result.seed = node{"seed"}.getInt(1)
  result.levelCount = node{"levelCount"}.getInt(8)
  result.turnsPerLevel = node{"turnsPerLevel"}.getInt(10)
  result.framesPerTurn = node{"framesPerTurn"}.getInt(6)
  result.difficulty = normalizedDifficulty(node{"difficulty"}.getStr("standard"))
  result.interruptOnDanger = node{"interruptOnDanger"}.getBool(true)
  result.fallLethal = node{"fallLethal"}.getInt(4)
  result.renderFramesPerStep = node{"renderFramesPerStep"}.getInt(4)
  result.sayFrames = node{"sayFrames"}.getInt(12)
  result.showPlayerLabels = node{"showPlayerLabels"}.getBool(false)
  result.playerNames = @[]
  let players = node{"players"}
  if not players.isNil:
    for entry in players:
      result.playerNames.add(entry{"name"}.getStr(""))

proc plannedFrom*(replay: Replay): seq[PlannedLevel] =
  ## The gauntlet plan, read back from the replay's own config document. The
  ## viewer re-GENERATES every level from these three fields plus the
  ## difficulty; the grids themselves are never stored.
  let node = parseJson(replay.configJson)
  let
    kinds = node{"levelKinds"}
    seedsJson = node{"levelSeeds"}
    splits = node{"levelSplit"}
  if kinds.isNil or seedsJson.isNil or splits.isNil:
    return @[]
  for i in 0 ..< kinds.len:
    var planned = PlannedLevel(kind: lkMaze, split: spSeen, seed: 0)
    case kinds[i].getStr()
    of "chaser": planned.kind = lkChaser
    of "climber": planned.kind = lkClimber
    of "miner": planned.kind = lkMiner
    else: planned.kind = lkMaze
    if i < seedsJson.len:
      planned.seed = seedsJson[i].getInt(0)
    if i < splits.len and splits[i].getStr() == "unseen":
      planned.split = spUnseen
    result.add(planned)
