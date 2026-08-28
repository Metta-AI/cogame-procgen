## The reply schema: what a commander (LLM or scripted) may say, how a reply
## is parsed TOLERANTLY, and how an illegal reply is REPAIRED instead of
## rejected. There is no reply that leaves the cog unactuated.
##
## Lifted from `coworld-ctf`'s `src/ctf/directives.nim`: `truncateRunes`,
## `sanitizeSay`, `sanitizeNote` and `extractJsonObject` are that file's,
## verbatim, including the `{` and `}` exclusion in `sanitizeSay` (the replay
## chat stream tells a control record from a shout by a leading brace). Only
## the `Intent` enum and `CogOrder` are replaced, by `PlanOrder`.
##
## RUNE DISCIPLINE. Every cap in this file is measured in RUNES (Unicode
## codepoints) and every truncation lands on a rune boundary (`runeLen` /
## `runeSubStr`). Slicing a string by BYTE index anywhere on the path to the
## replay is forbidden: a byte-truncated multi-byte character renders fine in
## a browser and then fails a strict UTF-8 parser, which is exactly the class
## of bug that makes a replay unreadable to everything except the one viewer
## that happened to be lenient.

import std/[json, strutils, unicode]
import sim_types, tiles

type
  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  PlanOrder* = object
    ## One seat's whole order for one turn: a plan of up to `framesPerTurn`
    ## symbols, and nothing else.
    moves*: string              ## over the alphabet L R U D X .
    say*: string                ## <= MaxSayRunes, sanitized; SPECTATOR only
    notes*: string              ## <= MaxNoteRunes, private, handed back
    source*: DirectiveSource
    latencyMs*: int
    executed*: int              ## how many symbols actually ran
    repaired*: bool
    fromReply*: bool

  DirectiveError* = object of ValueError

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc boundedReply*(text: string): string =
  ## THE 4096-byte read cap. The cut lands on a RUNE boundary like every other
  ## cut in this file: it backs off any UTF-8 continuation bytes, so the
  ## capped text is still valid UTF-8 and a `say` sliced out of it can never
  ## carry half a codepoint.
  if text.len <= MaxReplyBytes:
    return text
  var cut = MaxReplyBytes
  while cut > 0 and (uint8(text[cut]) and 0b1100_0000'u8) == 0b1000_0000'u8:
    dec cut
  text[0 ..< cut]

proc sanitizeSay*(text: string): string =
  ## The spectator one-line channel: capped at MaxSayRunes on a rune boundary
  ## FIRST, then run through the starter's printable-ASCII shout sanitiser.
  ## Doing it in that order means the rune cut never leaves half a codepoint
  ## for the ASCII filter to smear.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    # Braces are excluded deliberately: the replay chat stream carries the
    # control records as JSON objects and tells them apart from a cog's shout
    # by a leading '{'.
    if value >= 32 and value < 127 and value != ord('{') and
        value != ord('}'):
      result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## The seat's private line, handed back to it next turn. Newlines collapse
  ## to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc sanitizeMoves*(text: string, framesPerTurn: int):
    tuple[moves: string, repaired: bool] =
  ## THE plan repair, and the only place a `moves` string is made legal:
  ## uppercased; characters outside the six symbols DROPPED; longer than
  ## `framesPerTurn` truncated on a RUNE boundary; empty or absent after
  ## filtering becomes `"."` — one wait frame, so the cog is always actuated.
  var kept = ""
  for rune in text.runes:
    let value = int(rune)
    if value < 32 or value > 126:
      result.repaired = true
      continue
    var ch = char(value)
    if ch >= 'a' and ch <= 'z':
      ch = char(ord(ch) - 32)
    if ch in {'L', 'R', 'U', 'D', 'X', '.'}:
      kept.add(ch)
    else:
      result.repaired = true
  let limit = max(1, framesPerTurn)
  if kept.runeLen > limit:
    kept = kept.truncateRunes(limit)
    result.repaired = true
  if kept.len == 0:
    kept = "."
    result.repaired = true
  result.moves = kept

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc parsePlanOrder*(payload: JsonNode, framesPerTurn: int): PlanOrder =
  ## Turns one parsed reply into a legal plan, REPAIRING every field the
  ## schema bounds rather than rejecting the reply. Raises `DirectiveError`
  ## only when the payload is not an object at all — the one condition the
  ## retry and then the scripted fallback exist for.
  if payload.isNil or payload.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")
  result.source = dsLlm
  result.fromReply = true
  let node = payload{"moves"}
  var raw = ""
  if node.isNil:
    result.repaired = true
  elif node.kind == JString:
    raw = node.getStr()
  else:
    result.repaired = true
  let repaired = sanitizeMoves(raw, framesPerTurn)
  result.moves = repaired.moves
  if repaired.repaired:
    result.repaired = true
  result.say = sanitizeSay(payload{"say"}.getStr())
  result.notes = sanitizeNote(payload{"notes"}.getStr())

proc directiveRecord*(order: PlanOrder, turn, level: int,
                      alias, viewJson: string): JsonNode =
  ## The replay chat record for one turn's directive. Re-applied at playback
  ## into NON-HASHED fields only: it drives the broadcast feed and
  ## `tools/replay_summary.py` and can never affect the simulation.
  result = %*{
    "k": "directive",
    "turn": turn,
    "level": level,
    "alias": alias,
    "source": $order.source,
    "latency_ms": order.latencyMs,
    "moves": order.moves,
    "executed": order.executed,
    "repaired": order.repaired,
    "say": order.say
  }
  if viewJson.len > 0:
    result["view"] = %viewJson

proc boundedDirectiveRecord*(order: PlanOrder, turn, level: int,
                             alias, viewJson: string): string =
  ## The serialized directive record, guaranteed <= MaxDirectiveRunes. The
  ## view is the only unbounded-in-practice field, so it is the one that is
  ## dropped; every cut still lands on a rune boundary. NEVER cut the
  ## SERIALIZED string — that would emit broken JSON, which is the exact
  ## failure the rune rule exists to prevent.
  result = $order.directiveRecord(turn, level, alias, viewJson)
  if result.runeLen <= MaxDirectiveRunes:
    return
  result = $order.directiveRecord(turn, level, alias, "")
  var trimmed = order
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and guard < 12:
    inc guard
    trimmed.say = trimmed.say.truncateRunes(max(0, trimmed.say.runeLen - 4))
    trimmed.notes = trimmed.notes.truncateRunes(
      max(0, trimmed.notes.runeLen - 16))
    result = $trimmed.directiveRecord(turn, level, alias, "")

proc planSymbols*(order: PlanOrder): string =
  ## The plan as the viewer draws it: one arrow per symbol.
  order.moves

proc legalAlphabet*(text: string): bool =
  ## Every symbol of a plan is one of the six. `tests/test_procgen_control.nim`
  ## asserts both baselines only ever emit these.
  if text.len == 0:
    return false
  for ch in text:
    if ch notin {'L', 'R', 'U', 'D', 'X', '.'}:
      return false
  true

proc alphabetSize*(): int = ActionAlphabet.len
