## Two name spaces, kept apart on purpose — and a THIRD split specific to
## this game.
##
## Forked from `coworld-ctf`'s `src/ctf/roster.nim` with teams deleted: there
## is one seat, `slots` is gone from the runtime config, and `cogAlias(0)`
## returns `COG-alpha` from the starter's identity array.
##
## IN-GAME the cog is `COG-alpha`. That alias is the only name in the
## observation, the prompt, the reply, the `say`, the feed and the board
## label. The seat's REAL policy name (`daveey`, `daveey-1`, `Baseline (1)`)
## lives only in `results.names`, in the replay's join record, and in the
## viewer's scorebug plate and endcard.
##
## The third split: the seat is never told WHICH levels are seen and which are
## unseen, nor any level's seed. The spectator is told both.
## `tests/test_procgen_identity_privacy.nim` asserts all three.

import sim_types

const
  IdentityNames* = ["alpha", "beta", "gamma", "delta"]

proc cogAlias*(slot: int): string =
  if slot < 0 or slot >= IdentityNames.len:
    return "COG-?"
  "COG-" & IdentityNames[slot]

proc defaultPlayerName*(slot: int): string =
  "Cog" & $(slot + 1)

proc seatCount*(config: GameConfig): int =
  max(1, min(Seats, config.numAgents))
