## The replay chat records, in one pure module.
##
## They are written by the server, re-applied at playback into NON-HASHED
## fields only, and they drive the broadcast feed and
## `tools/replay_summary.py`. They can never affect the sim.
##
## `coworld-ctf` keeps these beside the decision loop in `decide.nim`; they
## live here instead so the headless episode runner, the fixture recorder and
## the tests can build a replay without importing the LLM transport (and its
## libcurl dependency) at all.

import std/json
import directives, sim

proc fallbackRecord*(turn, attempt: int, cause, detail: string): string =
  $(%*{
    "k": "fallback", "turn": turn, "slot": 0, "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

const UnregisteredSeatLog* = " never registered — playing pathfinder"
  ## The loud line the server prints for a seat that produced no `register`
  ## record (the grf-football 2026-08-27 scar: a lost register packet silently
  ## demoted a champion to the default script for a whole episode).

proc playerFailureJson*(slot: int): string =
  ## The CLOSED-SCHEMA player-failure payload, exactly two keys.
  $(%*{"message": "seat never registered; played the pathfinder baseline",
       "failed_policy_index": slot})

proc registerRecord*(slot: int, alias, policy, kind, baseline: string): string =
  ## The REDACTED registration record. The seat's prompt is never written:
  ## only the policy label, the kind, and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register", "slot": slot, "alias": alias,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind, "baseline": baseline
  })

proc genFallbackRecord*(level: int, kind: string, seed: int): string =
  ## The 41st-attempt hand-authored level. It has never fired in CI; the
  ## record exists so that if it ever does, the replay says so.
  $(%*{"k": "gen_fallback", "level": level, "kind": kind, "seed": seed})

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc stopRecord*(frame: int, endRule: string): string =
  ## The load-bearing wall-clock or fault stop. A wall-clock fact cannot be
  ## re-derived from sim state, so it is recorded as ONE record applied by the
  ## SAME proc on record and on playback (the particle-worlds scar).
  $(%*{"k": "stop", "frame": frame, "endRule": endRule})

proc resultRecord*(episode: Episode): string =
  ## The episode's whole results document, written once into the replay chat
  ## stream at episode end. It is what makes the replay SELF-SUFFICIENT.
  "{\"k\":\"result\",\"results\":" & episode.procgenResultsJson() & "}"
