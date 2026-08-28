## The LLM transport, kept function-by-function from the starter, and the
## wall-clock arithmetic the cadence rests on.
##
## Only the `SystemPrompt*` const is this game's; everything else in
## `src/procgen/llm.nim` is `coworld-ctf`'s `src/ctf/llm.nim`, because all of
## it is scar tissue from real hosted failures.

import std/[os, strutils]
import procgen/[directives, llm, sim, sim_types]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

# the transport is the starter's ---------------------------------------------
block:
  let source = readFile("src/procgen/llm.nim")
  for pinned in ["proc resolveApiKey", "proc bedrockModelIds",
                 "proc tryNextBedrockModel", "proc bedrockUrl",
                 "proc newLlmClient", "proc requestFor", "proc textOf",
                 "proc operatorBlock", "proc userMessage"]:
    check pinned in source, "llm: the starter's " & pinned & " is kept"
  check "cut off at max_tokens" in source,
    "llm: the max_tokens raise is kept"
  check "us.anthropic.claude-haiku-4-5-20251001-v1:0" in source,
    "llm: haiku is the ONE bedrock candidate"
  check "claude-sonnet" notin source,
    "llm: no sonnet inference profile is a candidate (they time out)"
  check "LLM provider is unavailable" in source,
    "llm: the exact phrase phase 60 greps for"
  check "\"x-api-key\"" in source and "anthropic-version" in source,
    "llm: the Anthropic headers are the starter's"

# the client disables itself with no credentials -----------------------------
block:
  ## With no credentials the client is `disabled`, so every turn falls back
  ## INSTANTLY with no network wait -- which is what lets offline
  ## certification finish in seconds.
  if getEnv("ANTHROPIC_API_KEY").len == 0 and
      getEnv("AWS_BEARER_TOKEN_BEDROCK").len == 0 and
      getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").len == 0:
    let client = newLlmClient(defaultGameConfig())
    check client.disabled, "llm: with no credentials the client is disabled"
    check client.transport == ltNone, "llm: and the transport is none"

# maxOutputTokens is 900, not 400 --------------------------------------------
block:
  check defaultGameConfig().maxOutputTokens == 900,
    "llm: maxOutputTokens is 900 (the playbook's Bedrock note)"

# the system prompt is this game's, and it is complete -----------------------
block:
  for needed in ["L R U D X .", "[0,0] is the top-left tile",
                 "The exit is LOCKED until", "MUST begin with '{'",
                 "\"moves\"", "\"say\"", "\"notes\"",
                 "cut short the moment", "average over four of the eight",
                 "TEN decisions per level", "SIX moves"]:
    check needed in SystemPrompt,
      "llm: the system prompt must say `" & needed & "`"
  check "700 points" in SystemPrompt,
    "llm: the prompt states the scoring the seat is graded on"
  ## It must NOT leak the split.
  check "unseen" notin SystemPrompt,
    "llm: and it never tells the seat which levels are scored"
  ## The operator block is the seat's own prompt, weighted but subordinate.
  let block1 = operatorBlock("take the nearest gem")
  check "GUIDANCE FROM YOUR OPERATOR" in block1 and
    "take the nearest gem" in block1,
    "llm: the operator block carries the seat's prompt"
  check operatorBlock("").len == 0,
    "llm: and is empty for a scripted seat"
  let user = userMessage("guidance here", "{\"level\":{}}")
  check "guidance here" in user and "{\"level\":{}}" in user,
    "llm: the user message is the guidance then the view"

# the prompt cap is a RUNE cap -----------------------------------------------
block:
  var long = ""
  for _ in 0 ..< MaxPromptRunes + 200:
    long.add("\u{1F600}")
  let capped = operatorBlock(long)
  check capped.len > 0, "llm: a long prompt still produces a block"
  check capped.count("\u{1F600}") <= MaxPromptRunes,
    "llm: the prompt is truncated at MaxPromptRunes RUNES"

# the wall-clock arithmetic --------------------------------------------------
block:
  let config = defaultGameConfig()
  check config.attempt1Ms == 10000 and config.retryMs == 5000,
    "llm: attempt 1 is 10 s and the single retry is 5 s"
  check config.turnBudgetMs == 16000,
    "llm: the per-turn cap holds both calls plus slack"
  check config.turnSpacingMs == 2500,
    "llm: one seat at 60000/2500 = 24 requests a minute, inside the " &
    "sidecar's 30-per-minute per-episode cap"
  check config.wallClockBudgetSeconds == 660,
    "llm: the engine's own stop is 660 s"
  ## THE ARITHMETIC, OUT LOUD. episodeTimeoutSeconds is 1200 and this game
  ## plays inside 60 % of it (720 s). What bounds the episode is NOT
  ## `turns x turnBudget` — at 16 s a turn, 80 turns of worst case would be
  ## 1280 s — it is the BUDGET GUARD: the last turn that may call the LLM
  ## STARTS at `wallClockBudgetSeconds - 2 x turnBudgetSeconds` at the latest,
  ## and takes at most one spacing plus one turn budget, after which every
  ## remaining turn is microseconds of integer work. The episode settles with
  ## FEWER turns, never later.
  let
    turns = config.levelCount * config.turnsPerLevel
    lastLlmTurnStart =
      config.wallClockBudgetSeconds - 2 * config.turnBudgetSeconds()
    slowestTurnSeconds =
      (config.turnSpacingMs + config.turnBudgetMs + 999) div 1000
    lobbyAndTail = 50
    settledBy = lastLlmTurnStart + slowestTurnSeconds + lobbyAndTail
  check turns == 80, "llm: at most 80 decision turns"
  check settledBy <= 720,
    "llm: the budget guard settles the episode by " & $settledBy &
      " s, inside the 720 s budget"
  ## And the budget guard fires two turn budgets before the engine's own stop,
  ## so even the worst case settles `complete` rather than `deadline`.
  check config.wallClockBudgetSeconds - 2 * config.turnBudgetSeconds() < 660,
    "llm: the budget guard fires before the wall-clock stop"

if failures > 0:
  quit("test_procgen_llm: " & $failures & " failures", 1)
echo "test_procgen_llm: ok"
