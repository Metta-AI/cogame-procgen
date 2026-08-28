## The board and feed label vocabulary equals `tests/label_manifest.txt`
## (design note §Tests, numbered test 45; the starter's `test_label_contract`
## pattern). Regenerate the manifest in the SAME COMMIT as any label change:
##
##   nim r --path:src tests/test_procgen_label_contract.nim --write

import std/[os, strutils]
import procgen/[labels, levels, roster, tiles]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

const ManifestPath = "tests/label_manifest.txt"

if paramCount() >= 1 and paramStr(1) == "--write":
  writeFile(ManifestPath, labelManifest())
  echo "wrote ", ManifestPath
  quit(0)

block:
  if not fileExists(ManifestPath):
    check false, "45: tests/label_manifest.txt is missing"
  else:
    check readFile(ManifestPath) == labelManifest(),
      "45: the emitted label vocabulary differs from tests/label_manifest.txt" &
      " -- regenerate it in the same commit as the label change"

# every feed row is plain language, never internal notation ------------------
block:
  let kinds = [ekLevelStart, ekCollect, ekExitOpen, ekDeath, ekInterrupt,
               ekLevelEnd, ekSay, ekFallback, ekGauntletEnd]
  for kind in kinds:
    let e = FrameEvent(kind: kind, level: 3, frame: 12, value: 3, extra: 4,
      text: (if kind == ekDeath: "caught"
             elif kind == ekSay: "digging under the rock"
             elif kind == ekFallback: "timeout"
             elif kind == ekCollect: "gem"
             else: ""))
    let row = feedRow(e, lkMiner, loCleared)
    check row.len > 0, "45: " & $kind & " has a feed row"
    for notation in ["ekCollect", "milli", "dcCaught", "lkMiner", "{", "}"]:
      check notation notin row,
        "45: the feed says plain language, never " & notation & ": " & row
  ## The alias, never the policy name.
  let row = feedRow(FrameEvent(kind: ekCollect, level: 1, value: 2, extra: 4,
    text: "gem"), lkMaze, loCleared)
  check cogAlias(0) in row, "45: the feed names the in-game alias"
  check "daveey" notin row, "45: and never a real policy name"

if failures > 0:
  quit("test_procgen_label_contract: " & $failures & " failures", 1)
echo "test_procgen_label_contract: ok"
