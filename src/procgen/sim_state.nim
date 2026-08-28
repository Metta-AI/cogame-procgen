## Three integer RNG streams and the per-frame state hash.
##
## Forked from `coworld-ctf`'s `src/ctf/sim_state.nim`: the same 64-bit
## xorshift generator and the same separate-stream convention. Design note
## §Sim module -> Determinism:
##
##   setupRng  (seeded `seed`)              play order + which training seeds
##   testRng   (seeded `seed xor 0x7E57`)   the held-out seeds and nothing else
##   levelRng  (seeded from a LEVEL seed)   every draw inside a generator
##
## Separating them is what makes a level a pure function of its own seed
## regardless of the episode, and all three are drawn BEFORE any seat
## connects.

type
  Rng* = object
    state*: uint64

const TestStreamXor* = 0x7E57

proc initRng*(seed: int): Rng =
  ## Splitmix-style avalanche on the seed so two nearby seeds do not produce
  ## two nearby streams. Never zero: a zero state is a xorshift fixed point.
  var x = uint64(seed) * 0x9E3779B97F4A7C15'u64 + 0x1234567890ABCDEF'u64
  x = (x xor (x shr 30)) * 0xBF58476D1CE4E5B9'u64
  x = (x xor (x shr 27)) * 0x94D049BB133111EB'u64
  x = x xor (x shr 31)
  if x == 0: x = 0x9E3779B97F4A7C15'u64
  Rng(state: x)

proc next*(rng: var Rng): uint64 =
  var x = rng.state
  x = x xor (x shl 13)
  x = x xor (x shr 7)
  x = x xor (x shl 17)
  rng.state = x
  x

proc rand*(rng: var Rng, bound: int): int =
  ## Uniform in `0 ..< bound` for a positive bound.
  if bound <= 1:
    return 0
  int(rng.next() mod uint64(bound))

proc between*(rng: var Rng, lo, hi: int): int =
  ## Uniform in `lo .. hi`, inclusive.
  if hi <= lo:
    return lo
  lo + rng.rand(hi - lo + 1)

proc shuffle*[T](rng: var Rng, values: var seq[T]) =
  ## Fisher-Yates. The gauntlet's PLAY ORDER is exactly this; the split is
  ## never shuffled.
  var i = values.len - 1
  while i > 0:
    let j = rng.rand(i + 1)
    swap(values[i], values[j])
    dec i

proc fold*(hash: var uint64, value: int) =
  ## FNV-style fold. The per-frame `gameHash` is this over the whole level
  ## state; the viewer checks the chain and warns on divergence.
  hash = hash xor uint64(value + 0x9E37)
  hash = hash * 0x100000001B3'u64
  hash = hash xor (hash shr 29)

proc newHash*(): uint64 = 0xCBF29CE484222325'u64
