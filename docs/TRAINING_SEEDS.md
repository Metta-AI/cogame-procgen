# Published training seeds

These 128 seeds are **public on purpose**. Every one of them names a level you can
generate, study, solve and hard-code, and a champion prompt that memorises all 128 is
playing the game as intended — it just earns nothing, because **the seen half is never
scored**. `scores[0]` is the mean return over the UNSEEN levels only.

Half of every episode's gauntlet is drawn from this table (which seed, and the play order,
come from the episode seed through `setupRng`); the other half is drawn fresh from
`[100000, 2147483646]` through `testRng`, a stream seeded `seed xor 0x7E57` that the seat
can neither observe nor influence. Every training seed here is below 5000, so the two sets
are **disjoint by construction** — `tests/test_procgen_seeding.nim` asserts it.

Reproduce any level with `generateLevel(kind, seed, difficulty)`
(`src/procgen/gen.nim`): it is a pure function of those three arguments, and
`tests/test_procgen_gen.nim` asserts the grids are identical across 500 seeds and between
the native build and the wasm build.

| archetype | seeds |
|---|---|
| `maze` | 1001–1032 |
| `chaser` | 2001–2032 |
| `climber` | 3001–3032 |
| `miner` | 4001–4032 |

## The full table

### `maze`

    1001  1002  1003  1004  1005  1006  1007  1008
    1009  1010  1011  1012  1013  1014  1015  1016
    1017  1018  1019  1020  1021  1022  1023  1024
    1025  1026  1027  1028  1029  1030  1031  1032

### `chaser`

    2001  2002  2003  2004  2005  2006  2007  2008
    2009  2010  2011  2012  2013  2014  2015  2016
    2017  2018  2019  2020  2021  2022  2023  2024
    2025  2026  2027  2028  2029  2030  2031  2032

### `climber`

    3001  3002  3003  3004  3005  3006  3007  3008
    3009  3010  3011  3012  3013  3014  3015  3016
    3017  3018  3019  3020  3021  3022  3023  3024
    3025  3026  3027  3028  3029  3030  3031  3032

### `miner`

    4001  4002  4003  4004  4005  4006  4007  4008
    4009  4010  4011  4012  4013  4014  4015  4016
    4017  4018  4019  4020  4021  4022  4023  4024
    4025  4026  4027  4028  4029  4030  4031  4032

## Difficulty

Each seed generates a different level at each of the three difficulties (`easy`,
`standard`, `hard`); the league default is `standard` and the `hardpool` variant plays
`hard`. The seed alone does not name a level — `(kind, seed, difficulty)` does.
