# Wire protocol

## The Coworld contract

| Direction | Variable | Meaning |
|---|---|---|
| in | `COGAME_CONFIG_URI` | the episode's `game_config` |
| out | `COGAME_RESULTS_URI` | the results document (closed schema) |
| out | `COGAME_SAVE_REPLAY_URI` | the binary `COWLDPGN` replay |
| out | `COGAME_PLAYER_FAILURE_URI` | one `{"message","failed_policy_index"}` payload |
| out | `COGAME_EVENTS_URI` | the tier-2 JSON-lines analysis stream |
| local | `COGAME_LOAD_REPLAY_URI` | developer replay mode, never declared to the platform |
| — | `COGAME_HOST` / `COGAME_PORT` | where to listen (`HOST` / `PORT` also accepted) |

The player socket lives at `/player?slot=0&token=<t>` and is **closed unless the token
matches the seat**. `/global` is the spectator stream; `/healthz`, `/client/player` and
`/client/global` answer the certifier's browser probes and keep answering for a bounded
shutdown grace after the artifacts are written.

## Per-seat observation

The whole level is in every observation — this game is **fully observed** — in tiles,
integers only.

```json
{
  "level": {"index": 3, "of": 8, "kind": "miner", "w": 15, "h": 9,
            "difficulty": "standard"},
  "turn": 4, "turns_left_this_level": 6, "frame": 18, "frames_per_turn": 6,
  "map": [
    "###############",
    "#@:::*::::::::#",
    "#:::##::O:::::#",
    "#::::::::::::*#",
    "#:O:::###:::::#",
    "#::::::*::::::#",
    "#:::::::::::O:#",
    "#*::::::::::+:#",
    "###############"
  ],
  "legend": {"#":"bedrock", ":":"dirt", "O":"boulder", "*":"gem", "o":"pellet",
             "+":"locked exit", "E":"open exit", "=":"platform", "H":"ladder",
             "^":"spikes", ".":"empty", "@":"you", "X":"hunter"},
  "you": {"at": [1,1], "last_dir": "R", "alive": true,
          "jump_fuel": 0, "fall_depth": 0, "dash_cooldown": 0},
  "collected": 0, "collect_total": 4, "exit_open": false, "exit_at": [12,7],
  "exit_distance": 19, "nearest_gem": [5,1], "nearest_gem_distance": 4,
  "hunters": [], "falling": [],
  "actions": [
    {"a":"L","to":[0,1],"legal":false,"effect":"blocked","kills":false},
    {"a":"R","to":[2,1],"legal":true, "effect":"dig","kills":false},
    {"a":"U","to":[1,0],"legal":false,"effect":"blocked","kills":false},
    {"a":"D","to":[1,2],"legal":true, "effect":"dig","kills":false},
    {"a":"X","to":[2,1],"legal":true, "effect":"dig_in_place","kills":false},
    {"a":".","to":[1,1],"legal":true, "effect":"wait","kills":false}
  ],
  "levels_done": [
    {"index":1,"kind":"maze","outcome":"cleared","return":1000},
    {"index":2,"kind":"chaser","outcome":"died","return":425}
  ],
  "your_notes": "gem at 5,1 is clean; boulder at 8,2 sits over the direct line"
}
```

`actions[]` always has exactly six entries in the wire order `L, R, U, D, X, .`, and it is
the **precomputed legal choice set**: `legal`, `to`, `effect` and `kills` all come from the
resolver's own `applyAction` / `passable` procs. One predicate, five callers — the
observation can never claim something the resolver disagrees with.

**Hidden from the seat**, explicitly and by test
(`tests/test_procgen_identity_privacy.nim`):

* the level's seed, and every other level's seed;
* whether this level (or any level) is `seen` or `unseen`, and the counts of each;
* the kind, seed and split of levels not yet played;
* the `setupRng` / `testRng` / `levelRng` states;
* the seat's **real policy/player name** — only `COG-alpha` appears anywhere;
* the running `seenMilli` / `unseenMilli` / `gapMilli`, and therefore `scores[0]`.

## Reply schema

```json
{"moves":"RRXDDL","say":"digging under the rock","notes":"gem 4 needs a side escape at 11,6"}
```

| Field | Cap | Repair |
|---|---|---|
| `moves` | **6 runes** over `L R U D X .` | uppercased; anything outside the six is DROPPED; longer than six truncated on a RUNE boundary; empty or absent becomes `"."` |
| `say` | **24 runes**, spectator-only | rune-boundary truncation, then the printable shout filter (which also strips `{` and `}`) |
| `notes` | **160 runes**, private | newlines collapsed, then rune-boundary truncation |

The whole reply is read with a **4096-byte** cap and the JSON is extracted tolerantly
(markdown fences and surrounding prose survive). **Every truncation lands on a rune
boundary.** The validator **repairs, never rejects**: there is no reply that leaves the cog
unactuated. Any repair increments `ordersRejected`.

`PLAYER_PROMPT` is itself capped at 4000 runes and is never echoed into the replay or the
results.

## The replay

Binary `COWLDPGN`: a header, the config JSON (seed, variant, difficulty, `levelKinds`,
`levelSeeds`, `levelSplit`, the cadence constants, the real player name, the alias), the
join record, **one action byte per sim frame** (`0=L 1=R 2=U 3=D 4=X 5=. 255=level
boundary`) plus a per-frame `gameHash`, and the chat records (`register`, `directive`,
`fallback`, `gen_fallback`, `budget_guard`, `stop`, `result`).

**The level grids are not recorded** and do not need to be: `generateLevel(kind, seed,
difficulty)` is a pure function, so the wasm viewer re-generates all eight levels from
`levelKinds` + `levelSeeds` + `difficulty`, and the per-frame `gameHash` proves it — which
is exactly the deterministic replay verification the idea asks for.

`python3 tools/replay_summary.py <file>` prints one strict-UTF-8 JSON object describing any
replay, using only the Python 3 standard library.

## Events

`COGAME_EVENTS_URI` gets one JSON object per line plus a trailing summary row. The
broadcast vocabulary is a closed enum of seventeen kinds: `gamestart`, `levelstart`, `plan`,
`step`, `collect`, `dig`, `push`, `fall`, `hunter`, `interrupt`, `death`, `exitopen`,
`levelend`, `say`, `fallback`, `gauntletend` and `end`. Seven of them make scrubber beats:
`levelstart`, `collect`, `exitopen`, `death`, `levelend`, `fallback`, `gauntletend`.
