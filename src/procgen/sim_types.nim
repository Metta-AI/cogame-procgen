## Engine-wide constants, the runtime `GameConfig`, and the rune caps every
## recorded string is measured against.
##
## Forked from `coworld-ctf`'s `src/ctf/sim_types.nim` (through its grid-game
## descendant): the same `GameVersion` / `ReplayFps` / `TargetFps` /
## `MaxSayRunes` / `MaxNoteRunes` / `MaxPromptRunes` discipline, retargeted
## from a continuous 2-D arena to a 15 x 9 integer tile grid. The paintball
## wire types, the weapon/paint/flag/hill state and the fog-of-war fields are
## deleted, not disabled (design note §Sim module).

import std/strutils

const
  GameVersion* = "1"
    ## GV1 (procgen gauntlet): eight seed-generated 15x9 levels, four
    ## archetypes, a six-symbol action alphabet, and a score that is the mean
    ## return over the UNSEEN half only.
    ##
    ## Bumped whenever the recorded replay stream changes meaning. Every
    ## committed fixture carries it and `tests/test_procgen_replay.nim` sweeps
    ## for a stale one. The HEADLINE on the declaration line is what
    ## `tools/ci/check_gameversion.sh` compares across branches: two branches
    ## can pick the same next number without seeing each other, and the same
    ## number attached to two different rules is the collision that makes an
    ## old replay re-simulate wrong.

  ReplayFps* = 24
  TargetFps* = 24

  MaxSayRunes* = 24
  MaxNoteRunes* = 160
  MaxPromptRunes* = 4000
  MaxFallbackDetailRunes* = 200
  MaxPolicyLabelRunes* = 64
  MaxDirectiveRunes* = 4000
  MaxReplyBytes* = 4096
  MaxStopDetailRunes* = 200

  Seats* = 1
    ## `num_agents`, fixed. The idea pins it ("Seats: 1") and the motive
    ## ("score attack on held-out seeds") is single-player by construction: a
    ## second seat on one level is a race, which is a different game with a
    ## different score.

  MaxFramesPerTurn* = 8
  MaxLevels* = 8

  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]
  ProtocolName* = "procgen/v1"
  ReplayMagic* = "COWLDPGN"
  ReplayFormatVersion* = 1
  GameName* = "procgen"

type
  ProcgenError* = object of CatchableError

  GameConfig* = object
    ## The runtime config, parsed from `COGAME_CONFIG_URI`. Every field is
    ## also a `config_schema` property in `coworld_manifest_template.json`,
    ## cross-checked by `tests/test_procgen_manifest.nim` block 36.
    seed*: int
    levelCount*: int
    turnsPerLevel*: int
    framesPerTurn*: int
    difficulty*: string           ## easy | standard | hard
    interruptOnDanger*: bool
    fallLethal*: int
    renderFramesPerStep*: int
    sayFrames*: int
    numAgents*: int
    minPlayers*: int
    fastMode*: bool
    showPlayerLabels*: bool
    attempt1Ms*: int
    retryMs*: int
    turnBudgetMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutSeconds*: int
    gameOverFrames*: int
    model*: string
    maxOutputTokens*: int
    playerNames*: seq[string]
    tokens*: seq[string]

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 1,
    levelCount: 8, turnsPerLevel: 10, framesPerTurn: 6,
    difficulty: "standard", interruptOnDanger: true, fallLethal: 4,
    renderFramesPerStep: 4, sayFrames: 12,
    numAgents: Seats, minPlayers: 1,
    fastMode: true, showPlayerLabels: false,
    attempt1Ms: 10000, retryMs: 5000,
    turnBudgetMs: 16000, turnSpacingMs: 2500,
    wallClockBudgetSeconds: 660, lobbyJoinTimeoutSeconds: 90,
    gameOverFrames: 12,
    model: "claude-haiku-4-5-20251001", maxOutputTokens: 900,
    playerNames: @[], tokens: @[])

proc turnBudgetSeconds*(config: GameConfig): int =
  (config.turnBudgetMs + 999) div 1000

proc normalizedDifficulty*(text: string): string =
  let key = text.strip().toLowerAscii()
  if key in ["easy", "standard", "hard"]: key else: "standard"
