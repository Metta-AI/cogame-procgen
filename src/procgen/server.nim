## The game server: the Coworld contract, the lobby, the frame loop and the
## artifact writes.
##
## Forked from `coworld-ctf`'s `src/ctf/server.nim` with four named edits
## (design note §Sim module -> The named edits):
##
## 1. The tick loop is a FRAME loop wrapped in a LEVEL loop: one decision
##    round per turn, up to `framesPerTurn` `stepFrame` calls per turn,
##    `fastMode` always on, no frame pacing. `maxTicks` / `startWaitTicks` /
##    `gameOverTicks` / `lobbyJoinTimeoutTicks` become `levelCount` /
##    `turnsPerLevel` / `framesPerTurn` / `gameOverFrames` /
##    `lobbyJoinTimeoutSeconds` — the last in SECONDS, because a `fastMode`
##    frame has no wall-clock meaning.
## 2. The wall-clock check at the top of the loop is kept as-is, reading
##    `wallClockBudgetSeconds`.
## 3. The certifier's browser probes stay registered BEFORE any catch-all
##    asset route and keep answering for a bounded grace after the artifacts
##    are written: `GET /client/player?slot=&token=` (token-checked, and it
##    must NOT open the player socket — the flatland 0.1.1 scar),
##    `GET /client/global`, the `/global` websocket's first message, and
##    `/healthz` (the lantern 0.1.1 and 0.1.3 scars).
## 4. `websocketHandler` KEEPS its `Ping -> Pong` branch and guards nothing
##    else: a `kind != TextMessage` guard drops the player's binary
##    registration frames (the lux-ai 0.1.0 / snake-royale 0.1.0 scar, twice
##    observed). Global broadcasts stay fire-and-forget so a slow viewer can
##    never stall the episode.

import std/[json, locks, monotimes, os, strutils, times]
import mummy, mummy/routers
import baselines, broadcast, control, decide, directives, events, global,
       levels, records, replay_runtime, replays, runtime, sim, tiles,
       wire_constants

type
  Registration = object
    prompt: string
    scripted: string
    policy: string
    seen: bool

  SharedState = object
    episode: Episode
    registration: Registration
    joined: bool
    playing: bool
    finished: bool

var
  stateLock: Lock
  shared: SharedState
  playerSockets: seq[tuple[ws: WebSocket, slot: int]]
  globalSockets: seq[WebSocket]
  socketLock: Lock
  httpServer: Server
  serveThread: Thread[tuple[host: string, port: int]]

initLock(stateLock)
initLock(socketLock)

const
  AssetRoot = "."
  ClientRoot = "client"
  ShutdownGraceSeconds* = 20
    ## `/healthz` and `/global` keep answering this long after the artifacts
    ## are written (the lantern 0.1.3 scar), CLAMPED by `PodBudgetSeconds`
    ## below so it can never push the pod past its budget.
  PodBudgetSeconds* = 720
    ## 60 % of `episode_timeout_minutes: 20`, measured from the episode clock
    ## — which starts at pod start, above the lobby. The arithmetic that has
    ## to fit inside it, worst case: the budget guard turns the seat scripted
    ## at `elapsed + 2 x turnBudgetSeconds > wallClockBudgetSeconds`, so the
    ## last turn that may call the LLM ENDS by
    ## `wallClockBudgetSeconds - turnBudgetSeconds` = 660 - 16 = 644 s; every
    ## later turn is microseconds of integer work. Then the `gameOverFrames`
    ## display hold (0.24 s) and the artifact writes, each bounded by
    ## `runtime.FetchTimeoutSeconds` — the SCORED artifact is the first of
    ## them, so results land by 665 s. This constant is what stops the rest of
    ## the tail (three more artifact URIs that could each hang for their full
    ## timeout, then this grace) from running past the budget: the grace ends
    ## at the earlier of `now + ShutdownGraceSeconds` and this deadline.
    ## `tests/test_procgen_engine.nim` block 31 asserts the whole sum.
  StartupGraceMs* = 200

proc contentTypeFor(path: string): string =
  let dot = path.rfind('.')
  if dot < 0:
    return "application/octet-stream"
  case path[dot .. ^1].toLowerAscii()
  of ".html": "text/html; charset=utf-8"
  of ".js": "text/javascript; charset=utf-8"
  of ".css": "text/css; charset=utf-8"
  of ".json": "application/json"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".webp": "image/webp"
  of ".ttf": "font/ttf"
  else: "application/octet-stream"

proc jsonHeaders(): HttpHeaders =
  result["content-type"] = "application/json"
  result["cache-control"] = "no-store"

proc textHeaders(kind: string): HttpHeaders =
  result["content-type"] = kind
  result["cache-control"] = "no-store"

proc readClientPage(name: string): string =
  let path = ClientRoot / name
  if not fileExists(path):
    return "<!doctype html><html><head><meta charset=\"utf-8\">" &
      "<title>procgen</title></head><body>procgen</body></html>"
  spliceWireConstants(readFile(path))

# ---------------------------------------------------------------------------
#  HTTP
# ---------------------------------------------------------------------------

proc queryValue(request: Request, key: string): string =
  request.queryParams[key]

proc handleHealth(request: Request) {.gcsafe.} =
  request.respond(200, jsonHeaders(), "{\"ok\":true}")

proc handleClientPlayer(request: Request) {.gcsafe.} =
  ## The certifier probes this route with a good token and a bad one BEFORE
  ## any player pod starts. It serves a real page and it NEVER opens the
  ## player socket.
  let
    slotText = request.queryValue("slot")
    token = request.queryValue("token")
  var slot = -1
  try:
    slot = parseInt(slotText.strip())
  except CatchableError:
    slot = -1
  var expected = ""
  {.cast(gcsafe).}:
    withLock stateLock:
      if slot == 0:
        expected = shared.episode.seat.token
  if slot < 0 or slot >= Seats:
    request.respond(400, textHeaders("text/plain; charset=utf-8"),
      "unknown slot")
    return
  if expected.len > 0 and token != expected:
    request.respond(403, textHeaders("text/plain; charset=utf-8"),
      "bad player token")
    return
  request.respond(200, textHeaders("text/html; charset=utf-8"),
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>" &
    "procgen seat " & $slot & "</title></head><body>" &
    "<h1>procgen</h1><p>Seat " & $slot & " is driven by the game " &
    "server. This page is the seat's status view; it opens no socket.</p>" &
    "</body></html>")

proc handleClientGlobal(request: Request) {.gcsafe.} =
  request.respond(200, textHeaders("text/html; charset=utf-8"),
    readClientPage("replay_broadcast.html"))

proc handleAsset(request: Request) {.gcsafe.} =
  var rel = request.path
  while rel.len > 0 and rel[0] == '/':
    rel = rel[1 .. ^1]
  if rel.len == 0:
    request.respond(200, textHeaders("text/html; charset=utf-8"),
      readClientPage("replay_broadcast.html"))
    return
  if ".." in rel:
    request.respond(404, textHeaders("text/plain; charset=utf-8"), "no")
    return
  for root in [ClientRoot, AssetRoot / "data", AssetRoot]:
    let path = root / rel
    if fileExists(path):
      request.respond(200, textHeaders(contentTypeFor(rel)), readFile(path))
      return
  request.respond(404, textHeaders("text/plain; charset=utf-8"), "not found")

# ---------------------------------------------------------------------------
#  WebSockets
# ---------------------------------------------------------------------------

proc handleUpgrade(request: Request) {.gcsafe.} =
  let isPlayer = request.path == "/player"
  var slot = -1
  if isPlayer:
    let token = request.queryValue("token")
    try:
      slot = parseInt(request.queryValue("slot").strip())
    except CatchableError:
      slot = -1
    var expected = ""
    {.cast(gcsafe).}:
      withLock stateLock:
        if slot == 0:
          expected = shared.episode.seat.token
    if slot < 0 or slot >= Seats or (expected.len > 0 and token != expected):
      ## A bad player token must be REFUSED, not accepted: the certifier
      ## probes with a wrong token and fails the episode if it is admitted.
      request.respond(403, textHeaders("text/plain; charset=utf-8"),
        "bad player token")
      return
  var socket: WebSocket
  try:
    socket = request.upgradeToWebSocket()
  except CatchableError:
    return
  {.cast(gcsafe).}:
    withLock socketLock:
      if isPlayer:
        playerSockets.add((socket, slot))
      else:
        globalSockets.add(socket)

proc applyRegistration(payload: string) =
  var node: JsonNode
  try:
    node = parseJson(payload)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr() != "register":
    return
  withLock stateLock:
    shared.registration.prompt =
      node{"prompt"}.getStr().truncateRunes(MaxPromptRunes)
    shared.registration.scripted = node{"scripted"}.getStr()
    shared.registration.policy =
      node{"policy"}.getStr().truncateRunes(MaxPolicyLabelRunes)
    shared.registration.seen = true
    shared.joined = true

proc websocketHandler(socket: WebSocket, event: WebSocketEvent,
                      message: Message) {.gcsafe.} =
  {.cast(gcsafe).}:
    var slot = -1
    withLock socketLock:
      for entry in playerSockets:
        if entry.ws == socket:
          slot = entry.slot
          break
    case event
    of OpenEvent:
      if slot >= 0:
        withLock stateLock:
          shared.joined = true
        socket.send("{\"type\":\"hello\",\"slot\":" & $slot & "}")
      else:
        ## The certifier reads the FIRST message on `/global` and pings it
        ## afterwards; answer immediately.
        var body = ""
        withLock stateLock:
          body = liveStateJson(shared.episode, shared.playing)
        socket.send(body)
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering them
      ## itself; the platform's certifier pings `/global` to check the game is
      ## alive, so an unanswered ping fails certification with
      ## `game_contract_violation`. Registration frames arrive as
      ## BinaryMessage (see `src/procgen_player.nim`), so ONLY Ping is
      ## filtered out here.
      if message.kind == Ping:
        socket.send(message.data, Pong)
        return
      if slot >= 0 and message.data.len > 0:
        applyRegistration(message.data)
    of CloseEvent, ErrorEvent:
      withLock socketLock:
        var keptPlayers: seq[tuple[ws: WebSocket, slot: int]]
        for entry in playerSockets:
          if not (entry.ws == socket):
            keptPlayers.add(entry)
        playerSockets = keptPlayers
        var keptGlobals: seq[WebSocket]
        for s in globalSockets:
          if not (s == socket):
            keptGlobals.add(s)
        globalSockets = keptGlobals

proc broadcastLive() =
  ## Fire and forget: `send` only QUEUES, so a slow viewer can never stall the
  ## episode.
  {.cast(gcsafe).}:
    var body = ""
    withLock stateLock:
      body = liveStateJson(shared.episode, shared.playing)
    withLock socketLock:
      for s in globalSockets:
        s.send(body)
      for entry in playerSockets:
        entry.ws.send(body)

proc sendFinal() =
  {.cast(gcsafe).}:
    withLock socketLock:
      for entry in playerSockets:
        entry.ws.send("{\"type\":\"final\"}")
      for s in globalSockets:
        s.send("{\"type\":\"final\"}")

proc buildRouter(): Router =
  ## Registered BEFORE any catch-all asset route.
  result.get("/healthz", handleHealth)
  result.get("/client/player", handleClientPlayer)
  result.get("/client/global", handleClientGlobal)
  ## There is NO `/client/replay` route: the hosted replay viewer is the
  ## static wasm bundle and nothing else, so the pod serves no replay path at
  ## all (acceptance checklist item 3). Local developer replay mode
  ## (`COGAME_LOAD_REPLAY_URI`) still works — `runLocalReplay` serves the same
  ## page from the asset route at `/`.
  result.get("/player", handleUpgrade)
  result.get("/global", handleUpgrade)
  result.get("/**", handleAsset)

proc serveLoop(args: tuple[host: string, port: int]) {.thread.} =
  {.cast(gcsafe).}:
    httpServer.serve(Port(args.port), args.host)

# ---------------------------------------------------------------------------
#  The episode
# ---------------------------------------------------------------------------

proc waitForLobby(config: GameConfig) =
  let deadline = getMonoTime() +
    initDuration(seconds = config.lobbyJoinTimeoutSeconds)
  while getMonoTime() < deadline:
    var seen = false
    withLock stateLock:
      seen = shared.registration.seen
    if seen:
      return
    sleep(100)

proc runEpisode*(host: string, port: int, config: GameConfig,
                 rt: RuntimeConfig) =
  withLock stateLock:
    shared.episode = newEpisode(config)
    shared.playing = false

  httpServer = newServer(buildRouter().toHandler(), websocketHandler)
  createThread(serveThread, serveLoop, (host: host, port: port))
  echo "procgen listening on ", host, ":", port
  sleep(StartupGraceMs)

  ## THE EPISODE CLOCK STARTS HERE, above the lobby — the platform charges
  ## from pod start, so `wallClockBudgetSeconds` has to cover the lobby too.
  let started = getMonoTime()

  waitForLobby(config)

  var
    engine = initDecisionEngine(config)
    replay = Replay(gameName: GameName, gameVersion: GameVersion)
    allEvents: seq[FrameEvent]
    directiveEvents: seq[DirectiveEvent]
    episode: Episode

  withLock stateLock:
    episode = shared.episode

  # Install the registration. A seat with no register record is logged LOUDLY
  # and flagged `deadSeats` (the grf-football 2026-08-27 scar: a lost register
  # packet silently demoted a champion to the default script for a whole
  # episode).
  var reg: Registration
  withLock stateLock:
    reg = shared.registration
  if not reg.seen:
    echo "ERROR: seat 0", UnregisteredSeatLog
    episode.seat.dead = true
    engine.seat.isLlm = false
    engine.seat.baseline = blPathfinder
    engine.seat.label = "pathfinder"
  else:
    engine.seat.registered = true
    engine.seat.prompt = reg.prompt
    engine.seat.isLlm = reg.prompt.len > 0
    engine.seat.baseline = parseBaseline(reg.scripted)
    engine.seat.label =
      if reg.policy.len > 0: reg.policy
      elif reg.prompt.len > 0: "prompt"
      else: $engine.seat.baseline
  episode.seat.policyKind = engine.policyKind()
  episode.seat.policyLabel = engine.seat.label
  episode.seat.baseline = $engine.seat.baseline
  replay.joins.add((0, episode.seat.name, episode.seat.token))
  replay.chats.add(registerRecord(0, cogAlias(0), engine.seat.label,
    episode.seat.policyKind, $engine.seat.baseline))
  replay.configJson = replayConfigJson(episode)

  withLock stateLock:
    shared.episode = episode
    shared.playing = true
  broadcastLive()

  var
    endRule = erGauntletComplete
    reason = rsComplete
    stopDetail = ""
    stopRecorded = false

  try:
    while not episode.gauntletDone():
      let elapsedAtLevel = (getMonoTime() - started).inSeconds.int
      if elapsedAtLevel >= config.wallClockBudgetSeconds:
        endRule = erWallClock
        reason = rsDeadline
        replay.chats.add(stopRecord(episode.totalFrames, $endRule))
        stopRecorded = true
        break
      allEvents.add(episode.beginLevel())
      if episode.level.genFallback:
        replay.chats.add(genFallbackRecord(episode.levelIndex,
          $episode.level.kind, episode.level.seed))
      withLock stateLock:
        shared.episode = episode
      broadcastLive()

      while not episode.levelDone():
        let elapsed = (getMonoTime() - started).inSeconds.int
        if elapsed >= config.wallClockBudgetSeconds:
          endRule = erWallClock
          reason = rsDeadline
          replay.chats.add(stopRecord(episode.totalFrames, $endRule))
          stopRecorded = true
          break
        let records = engine.turn(episode, elapsed)
        for record in records:
          replay.chats.add(record)
        ## A fallback is a fact about the transport, not about the level, so
        ## the sim cannot derive it: the decision layer emits the events and
        ## they join the episode's stream here.
        allEvents.add(engine.events)

        var order = engine.order
        let turnIndex = episode.turnsUsed + 1
        ## The observation the seat was answering about, captured BEFORE the
        ## plan runs: it is the `view` field of this turn's directive record.
        let viewJson = episode.recordViewJson()
        let played = episode.applyPlan(order.moves)
        order.executed = played.executed
        allEvents.add(played.events)
        for i in 0 ..< played.bytes.len:
          replay.frames.add(ReplayFrame(action: played.bytes[i],
            hash: played.hashes[i]))
        episode.seat.notes = order.notes
        if order.say.len > 0:
          episode.seat.say = order.say
          episode.seat.sayFramesLeft = max(1, config.sayFrames)
          inc episode.seat.saidTurns
        replay.chats.add(boundedDirectiveRecord(order, turnIndex,
          episode.levelIndex, cogAlias(0), viewJson))
        directiveEvents.add(DirectiveEvent(turn: turnIndex,
          level: episode.levelIndex, alias: cogAlias(0),
          source: $order.source, moves: order.moves,
          executed: order.executed, latencyMs: order.latencyMs,
          repaired: order.repaired))
        withLock stateLock:
          shared.episode = episode
        broadcastLive()

      if episode.levelOpen:
        replay.frames.add(ReplayFrame(action: ActionLevelBoundary,
          hash: episode.level.foldState(episode.levelIndex)))
        allEvents.add(episode.endLevel())
      if stopRecorded:
        break
  except CatchableError as error:
    reason = rsFault
    endRule = erSimFault
    stopDetail = error.msg
    if not stopRecorded:
      replay.chats.add(stopRecord(episode.totalFrames, $endRule))
    echo "procgen: sim fault, settling from the last completed frame: ",
      error.msg

  episode.settle(reason, endRule, stopDetail)
  allEvents.add(FrameEvent(kind: ekGauntletEnd, level: episode.plan.len,
    frame: episode.totalFrames, value: episode.unseenMilli(),
    extra: episode.seenMilli(), text: $endRule))
  allEvents.add(FrameEvent(kind: ekEnd, level: episode.plan.len,
    frame: episode.totalFrames, text: $reason))
  replay.chats.add(resultRecord(episode))

  withLock stateLock:
    shared.episode = episode
    shared.playing = false
    shared.finished = true
  broadcastLive()

  # The display hold, THEN the artifacts (design note §End conditions:
  # `complete` settles after the `gameOverFrames` display hold).
  sleep(max(0, config.gameOverFrames) * 20)

  # Artifacts.
  writeCogameUri(rt.resultsUri, "COGAME_RESULTS_URI",
    episode.procgenResultsJson())
  writeCogameUri(rt.replayUri, "COGAME_SAVE_REPLAY_URI", encodeReplay(replay))
  if rt.eventsUri.len > 0:
    writeCogameUri(rt.eventsUri, "COGAME_EVENTS_URI",
      eventsJsonl(allEvents, episode.totalFrames, GameVersion,
                  directiveEvents))
  if episode.seat.dead and rt.failureUri.len > 0:
    writeCogameUri(rt.failureUri, "COGAME_PLAYER_FAILURE_URI",
      playerFailureJson(0))

  echo "procgen: episode ", $reason, " (", $endRule, ") after ",
    episode.totalFrames, " frames, ", episode.turnsUsed, " turns; unseen ",
    episode.unseenMilli(), " seen ", episode.seenMilli()
  sendFinal()

  # A bounded shutdown grace in which `/healthz` and `/global` keep answering
  # (the lantern 0.1.3 scar), CLAMPED to the pod budget: on the pathological
  # path where every artifact URI hangs for its full timeout the artifacts
  # have already eaten the tail, and holding the process open for another
  # 20 s past 720 s buys nothing that the results write did not already
  # deliver.
  var graceUntil = getMonoTime() + initDuration(seconds = ShutdownGraceSeconds)
  let podDeadline = started + initDuration(seconds = PodBudgetSeconds)
  if graceUntil > podDeadline:
    graceUntil = podDeadline
  while getMonoTime() < graceUntil:
    sleep(250)
  httpServer.close()

proc runLocalReplay*(host: string, port: int, bytes: string) =
  ## Local developer replay mode, off `COGAME_LOAD_REPLAY_URI`. Serves the
  ## broadcast page from the asset route at `/`; there is no `/client/replay`
  ## path here or anywhere else, because the only replay viewer this game
  ## declares is the static wasm bundle.
  var rt = loadReplay(bytes)
  echo "procgen: local replay, ", rt.replay.frames.len, " frames, ",
    "mismatch at ", rt.mismatchFrame
  discard framePacket(rt)
  httpServer = newServer(buildRouter().toHandler(), websocketHandler)
  httpServer.serve(Port(port), host)
