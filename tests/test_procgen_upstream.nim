## The upstream claims and the five divergences (design note §Upstream,
## consulted and pinned; numbered test 19).
##
## A claim edited without editing its citation fails here.

import std/[os, strutils]
import procgen/[levels, tiles, upstream]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

# 19. the transcribed upstream facts ----------------------------------------
block:
  check UpstreamFacts.len == 4, "19: four transcribed upstream facts"
  for fact in UpstreamFacts:
    check fact.source.len > 0 and fact.claim.len > 0 and fact.landsAs.len > 0,
      "19: every fact carries its source, its claim and where it lands"
    check "procgen" in fact.source.toLowerAscii(),
      "19: every fact cites the upstream repo or the paper"
  check "Cobbe" in UpstreamCitation and "openai/procgen" in UpstreamCitation,
    "19: the citation names the repo and the paper"

# the five divergences -------------------------------------------------------
block:
  check Divergences.len == 5, "19: five documented divergences"
  for i, d in Divergences:
    check d.id == i + 1, "19: the divergences are numbered 1..5"
    check d.upstream.len > 0 and d.here.len > 0 and d.why.len > 0,
      "19: every divergence says what upstream does, what happens here, and why"
  check "C++" in Divergences[0].upstream, "19: divergence 1 is `not a port`"
  check "pixel" in Divergences[1].upstream,
    "19: divergence 2 is the symbolic observation"
  check "fifteen" in Divergences[2].upstream,
    "19: divergence 3 is the six-symbol alphabet"
  check "L R U D X ." in Divergences[2].here,
    "19: divergence 3 names the alphabet it ships"
  check "15 Hz" in Divergences[3].upstream,
    "19: divergence 4 is the plan of six frames"
  check "fixed set" in Divergences[4].upstream,
    "19: divergence 5 is the fresh per-episode draw"

# the shipped constants the citations bind -----------------------------------
block:
  check UpstreamArchetypes == 4, "19: four archetypes ship"
  check UpstreamActionSymbols == 6, "19: six action symbols ship"
  check UpstreamBoardW == 15 and UpstreamBoardH == 9, "19: the board is 15 x 9"
  var kinds = 0
  for kind in LevelKind.low .. LevelKind.high:
    inc kinds
  check kinds == UpstreamArchetypes,
    "19: the LevelKind enum is the four the citation binds"
  check UpstreamKinds[0] == lkMaze and UpstreamKinds[3] == lkMiner,
    "19: the four archetypes are the ones named"

# docs/RULES.md opens with the reimplementation sentence ---------------------
block:
  const RulesPath = "docs/RULES.md"
  if not fileExists(RulesPath):
    check false, "19: docs/RULES.md is missing"
  else:
    let text = readFile(RulesPath)
    let head = text[0 ..< min(700, text.len)].replace("**", "")
    check NotAPortSentence in head,
      "19: docs/RULES.md OPENS with the reimplementation-not-a-port sentence"
    check "Divergences" in text,
      "19: docs/RULES.md carries the divergences section"

if failures > 0:
  quit("test_procgen_upstream: " & $failures & " failures", 1)
echo "test_procgen_upstream: ok"
