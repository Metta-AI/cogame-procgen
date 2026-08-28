## The decision layer: the per-turn loop that asks the seat which plan its
## cog runs next, and always has an answer.
##
## Forked from `coworld-ctf`'s `src/ctf/decide.nim`, keeping the whole
## per-turn loop shape: the budget guard, the rate floor, the batch call with
## `attempt1Ms` / `retryMs` / `turnBudgetMs`, the throttle fail-fast, the
## final fallback ladder and its `cause` enum, and the exact `falling back`
## log phrase phase 60 greps. Only the observation (`seatViewJson`, which
## lives in `sim.nim` so the replay record can build it without libcurl), the
## parse call and the fallback baseline change.
##
## Cadence: ONE batch per turn carrying ONE request. Procgen is a single-seat
## sequential game, so the batch degenerates to a batch of one — deliberately
## through `curly.makeRequests` rather than around it, because the batch path
## is where the deadline handling, the throttle detection, the retry ladder
## and the fallback accounting live. At most two batches per turn (attempt +
## retry).
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, and the whole turn is
## wrapped in a monotonic `turnBudgetMs` deadline. A provider throttle with no
## other candidate model skips the retry outright (it cannot land) and fails
## fast to the scripted layer for that turn. On a second failure the seat
## plays the `pathfinder` plan and a `fallback` record names the cause.

import std/[json, monotimes, os, strutils, times]
import curly
import baselines, control, directives, levels, llm, records, sim, tiles
export records

type
  SeatPolicy* = object
    ## What the seat registered as. A seat that registers with neither field —
    ## or never registers at all — is `pathfinder`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    seat*: SeatPolicy
    order*: PlanOrder
    haveOrder*: bool
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool               ## the budget guard fired; scripted from here
    events*: seq[FrameEvent]
      ## The `fallback` events this turn produced. The sim cannot derive them
      ## — a fallback is a fact about the TRANSPORT, not about the level — so
      ## the decision layer emits them and the server folds them into the
      ## episode's event stream.

proc initDecisionEngine*(config: GameConfig): DecisionEngine =
  result.client = newLlmClient(config)
  result.seat.baseline = blPathfinder
  result.seat.label = "pathfinder"

proc policyKind*(engine: DecisionEngine): string =
  if engine.seat.isLlm: "llm" else: "scripted"

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc scriptedFor*(engine: DecisionEngine, episode: Episode): PlanOrder =
  scriptedPlan(episode.level, engine.seat.baseline,
    episode.config.framesPerTurn, episode.config.fallLethal)

proc turn*(engine: var DecisionEngine, episode: var Episode,
           elapsedSeconds: int): seq[string] =
  ## Runs ONE decision turn and installs the seat's plan. Returns the replay
  ## chat records this turn produced. Never raises: every failure path ends in
  ## a legal plan.
  let
    turnIndex = episode.turnsUsed + 1
    budget = initDuration(milliseconds = max(1, episode.config.turnBudgetMs))
  ## Throttle state is PER TURN: a 429 on turn k says nothing about turn k+1.
  engine.client.throttled = false
  engine.events.setLen(0)
  engine.haveOrder = false

  template noteFallback(why: string) =
    ## A template, not a closure: `engine` is a var parameter and cannot be
    ## captured.
    engine.events.add(FrameEvent(kind: ekFallback, level: episode.levelIndex,
      turn: turnIndex, frame: episode.level.frame, at: episode.level.cog,
      text: why))

  # --- budget guard: settle EARLY rather than overrun -----------------------
  if not engine.llmOff:
    let turnSeconds = episode.config.turnBudgetSeconds()
    if elapsedSeconds + 2 * turnSeconds >
        episode.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(turnIndex,
        max(0, episode.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "procgen: budget guard fired at turn ", turnIndex,
        "; remaining turns play pathfinder"

  # --- does this turn need a call? -----------------------------------------
  var needsCall = false
  if engine.seat.isLlm and not engine.llmOff and not engine.client.disabled:
    needsCall = true
  elif engine.seat.isLlm:
    ## An LLM seat that CANNOT call the LLM this turn is a FALLBACK, not a
    ## scripted policy. Recording it is what makes `llmTurns 0 /
    ## fallbackTurns N` countable rather than silently zero.
    engine.order = fallbackPlan(episode.level, episode.config.framesPerTurn,
      episode.config.fallLethal)
    engine.haveOrder = true
    inc episode.seat.fallbackTurns
    let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
    result.add(fallbackRecord(turnIndex, 1, cause,
      "the LLM is unavailable for this turn; playing pathfinder"))
    noteFallback(cause)
    echo "procgen llm: seat 0 falling back to pathfinder (", cause,
      ") on turn ", turnIndex
  else:
    engine.order = engine.scriptedFor(episode)
    engine.haveOrder = true

  if not needsCall:
    return

  # --- the rate floor -------------------------------------------------------
  # The Bedrock sidecar caps 30 requests per minute PER EPISODE. Holding the
  # START of consecutive batches `turnSpacingMs` apart pins one seat at
  # 60000 div 2500 = 24 requests per minute. The cert fixture sets it to 0, so
  # offline runs pay nothing.
  if engine.batchStarted and episode.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < episode.config.turnSpacingMs:
      sleep(episode.config.turnSpacingMs - since)
  engine.lastBatchStart = getMonoTime()
  engine.batchStarted = true

  let turnStart = getMonoTime()
  var
    attempt = 0
    open = true
  while open and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      result.add(fallbackRecord(turnIndex, attempt + 1, "timeout",
        "per-turn budget exhausted before attempt " & $(attempt + 1)))
      noteFallback("timeout")
      break
    let deadlineMs =
      if attempt == 0: episode.config.attempt1Ms else: episode.config.retryMs
    var user = episode.seatViewJson()
    if attempt > 0:
      user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
        "the JSON object described above, starting with '{', naming one " &
        "\"moves\" string of up to six letters from LRUDX. .")
    let request = engine.client.requestFor(
      SystemPrompt, userMessage(engine.seat.prompt, user))
    ## ONE batch per turn, carrying ONE request — the starter's batch path,
    ## unchanged, degenerating to a batch of one.
    var batch: RequestBatch
    batch.post(request.url, request.headers, request.body, "0")
    let started = getMonoTime()
    ## curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    ## SECONDS, so this conversion FLOORS — and sim_config REJECTS a
    ## sub-second value, so the floor below is an identity.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var cause = "parse_error"
    try:
      let text = boundedReply(engine.client.textOf(
        responses[0].response, responses[0].error, batch[0].url))
      var order = parsePlanOrder(extractJsonObject(text),
        episode.config.framesPerTurn)
      order.source = dsLlm
      order.latencyMs = latency
      if order.repaired:
        inc episode.seat.ordersRejected
      engine.order = order
      engine.haveOrder = true
      inc episode.seat.llmTurns
      open = false
    except CatchableError as error:
      if responses[0].error.len > 0:
        cause = (if "timeout" in responses[0].error.toLowerAscii():
                   "timeout" else: "transport_error")
      elif error.msg.startsWith("llm throttled"):
        cause = "throttled"
      result.add(fallbackRecord(turnIndex, attempt + 1, cause, error.msg))
      ## `will retry` — NEVER `falling back`: only a genuine fallback may say
      ## that, because phase 60 greps the game log for it.
      echo "procgen llm: seat 0 attempt ", attempt + 1,
        " failed, will retry: ", error.msg
    inc attempt
    if engine.client.throttled and open:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way.
      echo "procgen llm: provider throttled with no other candidate; the ",
        "seat falls back for turn ", turnIndex
      break

  if open:
    engine.order = fallbackPlan(episode.level, episode.config.framesPerTurn,
      episode.config.fallLethal)
    engine.haveOrder = true
    inc episode.seat.fallbackTurns
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(turnIndex, 2, cause,
      "seat fell back to the pathfinder plan"))
    noteFallback(cause)
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "procgen llm: seat 0 falling back to pathfinder (", cause,
      ") on turn ", turnIndex
