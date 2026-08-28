# Procgen

One cog, eight small levels in a row, and a generator that has never built any of them
before. Each level is a 15 × 9 tile board drawn from a number nobody tells the cog: a maze
with four gems behind a locked door; an open room of pellets patrolled by hunters; a stack
of tiers over a lethal pit; a wall of dirt hiding diamonds under falling boulders. Ten
decisions per level, six moves per decision, executed blind — but cut short the instant a
hunter comes alongside, a boulder starts falling overhead, or the cog goes into free fall.

Half the levels come from a **seed table published in this repo**, so a good prompt may have
studied them. The other half were drawn out of two billion possibilities the moment the
episode started, and the cog is never told which is which. **The score is the average return
on the levels nobody has ever seen.** The replay shows both numbers side by side, and the
gap between them is the whole point of the coworld.

**This is a reimplementation in the spirit of OpenAI Procgen, not a port of it** — see
[`docs/RULES.md`](docs/RULES.md), which opens with that sentence and lists every divergence.

**A policy is just a prompt.** Both champions are `PLAYER_PROMPT` policies; the two fillers
are scripted baselines; all four run the same image, switched by environment.

## The four archetypes

`maze` (search a topology), `chaser` (evade a pursuer), `climber` (commit to a jump you
cannot take back) and `miner` (reshape the terrain you are standing in) — one 15 × 9 tile
sim, one six-symbol action alphabet (`L R U D X .`), one scoring formula, one renderer, and
exactly one physics hook each. See [`docs/ARCHETYPES.md`](docs/ARCHETYPES.md).

## Scoring

Per level: 700 × (collectibles taken / total), plus up to 200 for how much closer to the
exit the cog ever got than where it started, plus 100 for reaching the exit. 1000 is a
perfect level. `scores[0]` is the mean over the **unseen** levels only, in `[0.000, 1.000]`,
higher better. The seen mean and the gap are measured, drawn and recorded — never scored,
because the moment the seen half pays, memorising 128 published levels becomes worth doing.

## Repo layout

| Path | What |
|---|---|
| `src/procgen/` | the sim: `tiles.nim`, `gen.nim` (the four generators), `levels.nim` (the frame resolver), `path.nim` (one bounded search), `seeds.nim`, `scoring.nim`, `upstream.nim`, plus the server, the commander layer and the replay |
| `src/procgen.nim` | the game server, `/bin/procgen` |
| `src/procgen_player.nim` | the thin seat registrar, `/bin/procgen-player` |
| `client/` | the broadcast chrome: `chrome_common.js` (byte-identical to the starter's), `broadcast_core.js` (the tile renderer) and `replay_broadcast.html` (the starter's page plus the appended PROCGEN block) |
| `replay-viewer/` | the wasm entry, the emscripten link flags and the static shell |
| `data/` | the board art: nano-banana renders of the Softmax cog, one kit per role |
| `scripts/art/` | the source sheets and the split script that made `data/` |
| `tools/ci/` | the CI harness: the docker smoke, the viewer smoke, the renderer fixture, the policy set |
| `docs/` | the rules, the archetypes, the published training seeds, the wire protocol, and the accepted design note |

## Playing a seat

```bash
coworld upload-policy coworld-procgen:latest \
  --name my-procgen --run /bin/procgen-player \
  --secret-env PLAYER_PROMPT="read the map rows, take the nearest gem first, \
and never plan a move that ends next to a hunter"
```

`PLAYER_SCRIPTED=pathfinder` or `PLAYER_SCRIPTED=scavenger` seats one of the two shipped
baselines instead. A seat that sets neither is `pathfinder`.

## Building

The game is Nim. `ci.yml` is the harness: it runs every `tests/*.nim` in debug and release,
sweeps the scripted-baseline tuning over a fixed ladder, builds the production image and
plays one real episode through raw docker (`tools/ci/docker_smoke.sh`), then builds the
static replay-viewer bundle and **opens it in headless chromium** against the replay that
episode produced.

```bash
nim c -r tests/tests.nim                    # the whole suite
docker build -t coworld-procgen:ci .        # the production image
./tools/ci/docker_smoke.sh coworld-procgen:ci
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

## Watching

Replays are a **static file plus a browser wasm viewer, never a pod**: the manifest declares
`"replay_viewer": {"bundle": "static-replay-viewer"}`, `tools/build_replay_viewer.sh`
compiles the *same* sim module to wasm, and the viewer **re-generates every level from its
seed** and re-simulates from the recorded action bytes in the browser. Everything the viewer
needs — the names, the config, the level seeds, one byte per frame — lives in the replay
bytes; no server is contacted except S3 for the file.

`python3 tools/replay_summary.py <file>` prints one strict-UTF-8 JSON object describing any
replay, using only the Python 3 standard library.
