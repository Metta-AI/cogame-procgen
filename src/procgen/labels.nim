## Plain-language board and feed labels. Never internal notation: the feed
## says `COG-alpha takes gem 3 of 4`, not `COLLECT l3 c3/4`.
##
## Forked from `coworld-ctf`'s `src/ctf/labels.nim`, which scopes itself to
## the vocabulary a spectator reads. `tests/test_procgen_label_contract.nim`
## asserts the emitted set equals `tests/label_manifest.txt`, regenerated in
## the same commit as any label change.

import std/strutils
import levels, roster

proc deathPhrase*(cause: DeathCause, alias: string): string =
  case cause
  of dcCaught: "a hunter catches " & alias
  of dcFell: alias & " falls into the pit"
  of dcSpiked: alias & " steps on the spikes"
  of dcCrushed: "a boulder lands on " & alias
  of dcNone: alias & " is out"

proc kindWord*(kind: LevelKind): string = ($kind).toUpperAscii()

proc dangerWord*(kind: LevelKind): string =
  ## What the danger interrupt was looking at, named per archetype (design
  ## note §Why a turn is a plan): a hunter within one tile in `chaser`, a
  ## falling boulder in the cog's column in `miner`, a free fall in `climber`.
  ## `maze` has no hazards and never interrupts, so its phrase is the generic
  ## one the spike rule would use.
  case kind
  of lkChaser: "hunter alongside"
  of lkMiner: "boulder overhead"
  of lkClimber: "falling"
  of lkMaze: "danger alongside"

proc feedRow*(e: FrameEvent, kind: LevelKind, outcome: LevelOutcome): string =
  ## One plain-language match-feed row, or an empty string for a kind the feed
  ## does not carry.
  let alias = cogAlias(0)
  case e.kind
  of ekLevelStart:
    "LEVEL " & $e.level & " of " & $e.value & " — " & kindWord(kind)
  of ekCollect:
    alias & " takes " & (if e.text == "pellet": "pellet " else: "gem ") &
      $e.value & " of " & $e.extra
  of ekExitOpen:
    "the exit unlocks"
  of ekDeath:
    var cause = dcNone
    try:
      cause = parseEnum[DeathCause](e.text)
    except ValueError:
      discard
    ## The frame is the one the scrubber is on, so a spectator reading the
    ## feed can go back to it.
    deathPhrase(cause, alias) & " — level over at " & $e.abs
  of ekInterrupt:
    "plan cut short — " & dangerWord(kind)
  of ekLevelEnd:
    case outcome
    of loCleared: alias & " clears " & kindWord(kind) & " — " & $e.value
    of loDied: alias & " is out on " & kindWord(kind) & " — " & $e.value
    of loTimeup:
      alias & " runs out of turns on " & kindWord(kind) & " — " & $e.value
    of loUnplayed: ""
  of ekSay:
    alias & ": \"" & e.text & "\""
  of ekFallback:
    alias & " MISSED THE CALL — pathfinder plan (" & e.text & ")"
  of ekGauntletEnd:
    "GAUNTLET OVER — unseen mean " & $e.value
  else:
    ""

const LabelVocabulary* = [
  "LEVEL ", " of ", "takes gem ", "takes pellet ", "the exit unlocks",
  "a hunter catches ", " falls into the pit", " steps on the spikes",
  "a boulder lands on ", " is out", " — level over at ",
  "plan cut short — hunter alongside", "plan cut short — boulder overhead",
  "plan cut short — falling", "plan cut short — danger alongside",
  " clears ", " is out on ", " runs out of turns on ",
  "MISSED THE CALL — pathfinder plan",
  "GAUNTLET OVER — unseen mean ",
  "MAZE", "CHASER", "CLIMBER", "MINER"]

proc labelManifest*(): string =
  LabelVocabulary.join("\n") & "\n"
