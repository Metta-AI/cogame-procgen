## The upstream facts this repo claims about OpenAI Procgen, transcribed with
## their citation, plus the five documented divergences.
## `tests/test_procgen_upstream.nim` asserts the shipped text still matches
## the design note, so a claim edited without its citation fails the build.
##
## THIS IS NOT A PORT. Procgen is a C++ engine (`gym3` / `libenv`, 64x64 RGB
## framebuffers) that cannot be embedded in a Nim coworld image and cannot be
## compiled to the replay viewer's wasm module. What this repo builds is an
## original suite of procedurally generated minigame archetypes written in Nim
## IN THE SPIRIT of Procgen, graded on held-out seeds.

import levels, tiles

type
  UpstreamFact* = object
    source*: string
    claim*: string
    landsAs*: string

  Divergence* = object
    id*: int
    upstream*: string
    here*: string
    why*: string

const
  UpstreamCitation* =
    "github.com/openai/procgen; Cobbe et al. 2020, Leveraging Procedural " &
    "Generation to Benchmark Reinforcement Learning"

  NotAPortSentence* =
    "This is a reimplementation in the spirit of Procgen, not a port of it."

  UpstreamFacts*: array[4, UpstreamFact] = [
    UpstreamFact(
      source: UpstreamCitation,
      claim: "training and test levels are drawn from the same generator but " &
        "are different levels, and the interesting number is the TEST return",
      landsAs: "scores[0] is the unseen-level mean and nothing else; the " &
        "seen mean exists only to display the generalisation gap"),
    UpstreamFact(
      source: UpstreamCitation,
      claim: "Procgen ships sixteen games sharing one engine and one action " &
        "interface",
      landsAs: "four archetypes share one 15x9 tile sim, one action " &
        "alphabet, one scoring formula and one renderer"),
    UpstreamFact(
      source: UpstreamCitation,
      claim: "Procgen levels are seed-deterministic: a seed reproduces a " &
        "level exactly",
      landsAs: "generateLevel(archetype, seed, difficulty) is a pure " &
        "function, asserted byte-identical across 500 seeds and across " &
        "native and wasm"),
    UpstreamFact(
      source: UpstreamCitation,
      claim: "Procgen's observation is a 64x64x3 frame and its action space " &
        "has 15 entries",
      landsAs: "BOTH DIVERGE HERE: the observation is symbolic and the " &
        "alphabet is six symbols; see divergences 2 and 3")
  ]

  Divergences*: array[5, Divergence] = [
    Divergence(id: 1,
      upstream: "OpenAI Procgen is a C++ engine with sixteen games",
      here: "no Procgen C++ code, no gym3, no libenv, no upstream asset; " &
        "four original archetypes named after Procgen games",
      why: "the archetypes are in the same spirit; the rules are written " &
        "here, and docs/RULES.md opens by saying so"),
    Divergence(id: 2,
      upstream: "the observation is a 64x64x3 pixel frame",
      here: "the observation is symbolic: an ASCII tile grid plus " &
        "structured integer fields",
      why: "the fleet's policies are an LLM prompt policy and a scripted " &
        "baseline, not a convnet; a 4096-pixel byte array in a prompt is " &
        "unreadable and unscorable, and the decision the idea buys — route " &
        "through a level you have never seen — survives the change of " &
        "encoding intact"),
    Divergence(id: 3,
      upstream: "the action space is a 3 x 5 product, fifteen entries",
      here: "exactly six symbols: L R U D X .",
      why: "diagonals are a corner-cutting rules problem that adds a rule " &
        "and no decision, and the two spare specials are unused by every " &
        "archetype here; six is the smallest alphabet in which all four " &
        "archetypes are fully playable"),
    Divergence(id: 4,
      upstream: "the agent acts on every frame at 15 Hz",
      here: "a decision is a PLAN of up to six primitive frames, " &
        "interruptible by the danger interrupt",
      why: "one LLM call per frame at 15 Hz is three orders of magnitude " &
        "outside the episode budget"),
    Divergence(id: 5,
      upstream: "the test seeds are a fixed set held by the server",
      here: "the unseen seeds are drawn fresh per episode from " &
        "[100000, 2147483646] through a stream the policy cannot observe",
      why: "there is no fixed hidden set that can leak, and memorising is " &
        "worthless because the level did not exist when the prompt was " &
        "written — a stronger mechanism than a fixed held-out list")
  ]

  # The shipped constants the citations above bind. A rules edit that does not
  # move these fails tests/test_procgen_upstream.nim.
  UpstreamArchetypes* = 4
  UpstreamActionSymbols* = ActionAlphabet.len
  UpstreamBoardW* = BoardW
  UpstreamBoardH* = BoardH
  UpstreamKinds*: array[4, LevelKind] = [lkMaze, lkChaser, lkClimber, lkMiner]
