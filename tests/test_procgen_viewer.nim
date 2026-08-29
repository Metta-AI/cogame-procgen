## The viewer chrome (design note §Tests, numbered blocks 39-43).
##
## The page is the STARTER'S page plus an appended game block — never a
## rewrite that reuses its ids (cogame-gridlock, 2026-08-23). These
## assertions are what make that checkable.

import std/[os, sha1, strutils]
import procgen/[events, levels, sim_types, tiles, wire_constants]

var failures = 0
proc check(ok: bool, what: string) =
  if not ok:
    failures.inc
    echo "FAIL: ", what

const
  ChromeCommonPath = "client/chrome_common.js"
  PagePath = "client/replay_broadcast.html"
  CorePath = "client/broadcast_core.js"
  ## The byte length and the sha256 the design note pins. Nim's standard
  ## library ships sha1 and not sha256, so the sha256 is pinned here as the
  ## literal it is and CHECKED BY `ci.yml`'s "chrome_common.js is the pinned
  ## chrome" step with sha256sum; the sha1 and the length are checked here,
  ## and all three change together or not at all.
  ##
  ## The file is the starter's chrome plus ONE deliberate edit, made in this
  ## repo and re-pinned with it: the 0.5x rung on the speed ladder (the
  ## `SPEEDS` fallback and the speed->command map's `0.5: '5'`). Any OTHER
  ## drift is what these three pins exist to catch.
  ChromeCommonBytes = 40037
  ChromeCommonSha256 =
    "594ed4a72cd908922c982d0f3e3ffb04ae1d97568fcd5f5daa794042662a369c"
  ChromeCommonSha1 = "1dff4ef4241115084bb5a063ad95c5e159b904a8"
  BannerMarker = "PROCGEN additions to the inherited coworld-ctf chrome"

if not fileExists(PagePath):
  quit("test_procgen_viewer: " & PagePath & " is missing", 1)
let
  page = readFile(PagePath)
  core = readFile(CorePath)

# 39. chrome_common.js is byte-identical to its pin --------------------------
block:
  check fileExists(ChromeCommonPath), "39: client/chrome_common.js ships"
  let bytes = readFile(ChromeCommonPath)
  check bytes.len == ChromeCommonBytes,
    "39: chrome_common.js is exactly " & $ChromeCommonBytes &
      " bytes (got " & $bytes.len & ")"
  check ($secureHash(bytes)).toLowerAscii() == ChromeCommonSha1,
    "39: chrome_common.js is byte-identical to the pinned chrome"
  check ChromeCommonSha256.len == 64,
    "39: the sha256 the note pins is carried as a literal for ci.yml"
  check "window.ChromeCommon" in bytes,
    "39: and it is the starter's chrome, not a lookalike"

# 39b. the 0.5x rung reaches every shipped surface ---------------------------
block:
  ## The one shipped page is `client/replay_broadcast.html` (the Dockerfile
  ## splices it to `index.html`; there is no league shell in this fork). Three
  ## things have to agree for the half-speed chip to work, and each has bitten
  ## a sibling repo on its own:
  ##  - the engine ladder, which is what the wire block emits;
  ##  - the chrome's own SPEEDS fallback, which is what ACTUALLY runs here:
  ##    chrome_common.js reads `window.CTF_WIRE` (inherited, pinned) and this
  ##    fork emits `window.PROCGEN_WIRE`, so the chips are always built from
  ##    the fallback literal;
  ##  - the speed->command map, whose char the replay runtime must decode.
  let chrome = readFile(ChromeCommonPath)
  check PlaybackSpeeds[0] == 0.5,
    "39b: the engine ladder opens on the 0.5x rung"
  check "speeds:[0.5," in wireConstantsJs(),
    "39b: and the wire block emits it"
  check "var SPEEDS = WIRE.speeds || [0.5, 1, 2, 3, 4, 8, 16];" in chrome,
    "39b: the chrome's fallback ladder carries the 0.5x rung"
  check "map = { 0.5: '5'," in chrome,
    "39b: and maps it to the '5' command char"
  ## Space pauses on the shipped page, and the page relays raw digits, which
  ## is how '5' reaches the runtime from the keyboard as well as the chip.
  check "if (k === ' ') { ev.preventDefault(); togglePlay(); }" in page,
    "39b: Space pauses/unpauses on the shipped page"
  check "else if (k >= '1' && k <= '9') send(k);" in page,
    "39b: and the digit keys reach the runtime, '5' included"

# 40. the page is the starter's plus an appended block -----------------------
block:
  let at = page.find(BannerMarker)
  check at > 0, "40: the appended game block carries its banner comment"
  let head = page[0 ..< at]
  ## The inherited head is the starter's page: its markup ids, its
  ## locker-room loader, its embed mode, its feed and banner queues, its
  ## transport wiring and its relayout() fixed-point band fit.
  for needle in ["<!-- WIRE_CONSTANTS -->", "<!-- CHROME_COMMON -->",
                 "<!-- BROADCAST_CORE -->", "window.ChromeCommon",
                 "function relayout()", "new ResizeObserver(relayout)",
                 "dismissLockerRoom", "function pushFeed(row)",
                 "function banner(text, cls)", "function seekToFraction",
                 "data-embed", "PB_CTX = {"]:
    check needle in head,
      "40: the inherited head keeps the starter's " & needle
  ## The game block is APPENDED after it, and installs through the starter's
  ## own splice hook.
  let tail = page[at .. ^1]
  check "window.ProcgenChrome" in tail,
    "40: the block publishes the chrome object the page installs"
  check "if (window.ProcgenChrome) window.ProcgenChrome.install(PB_CTX);" in head,
    "40: and the INHERITED head is what calls install(PB_CTX)"
  check "window.ProcgenChrome.frame(s, PB_CTX, jumped)" in head,
    "40: the starter's frame hook drives it, with the same signature"
  ## The procs the note's "kept and pinned function-by-function" list names
  ## are not in broadcast_core.js in EITHER repo: the feed queue, the banner
  ## queue and the seek helper live in the inherited HEAD of this page, and
  ## the beat/lull machinery and the speed chips live in chrome_common.js,
  ## which is byte-identical (block 39). Pin them where they actually are —
  ## `pushFeed`'s SIGNATURE included (the cogball 0.1.4 latch scar).
  for needle in ["function pushFeed(row)", "function clearFeed()",
                 "function banner(text, cls)", "function pumpBanner()",
                 "function clearBanners()", "function seekToFraction",
                 "function relayout()", "function dismissLockerRoom",
                 "?embed=1"]:
    check needle in head,
      "40: the inherited head still owns " & needle
  let chrome = readFile(ChromeCommonPath)
  for needle in ["markBeat", "ingestLullSpans", "renderLullSpans",
                 "renderTransport", "speedchips"]:
    check needle in chrome,
      "40: the beat/lull machinery and the speed chips stay in the " &
        "byte-identical chrome_common.js: " & needle
  ## broadcast_core.js is a REWRITE of the draw layer, so what is pinned in it
  ## is the interface: the factory, the method surface and the canvas/DPR
  ## sizing the page drives it through.
  for needle in ["window.BroadcastCore", "create: function (config)",
                 "ingest:", "sendCommand:", "setViewportSize:",
                 "setViewportFit:", "getTransform:", "getPaceStats:",
                 "onFirstFrame", "onTransform", "devicePixelRatio"]:
    check needle in core, "40: broadcast_core keeps " & needle

# 41. no shadowed chrome aliases ---------------------------------------------
block:
  ## The tandem 2026-08-23 hoisting trap: a game-block `function markBeat`
  ## would shadow the alias block's `var markBeat = C.markBeat` and render
  ## unlabelled div markers that never seek.
  ##
  ## The scan reads the block's CODE: the banner comment and the `//` lines
  ## inside it name the aliases on purpose, and a doc comment is not a
  ## binding.
  let at = page.find(BannerMarker)
  var tail = ""
  let bannerEnd = page.find("-->", at)
  for line in page[(if bannerEnd > 0: bannerEnd + 3 else: at) .. ^1].splitLines():
    if line.strip().startsWith("//") or line.strip().startsWith("*"):
      continue
    tail.add(line)
    tail.add("\n")
  for alias in ["markBeat", "renderClock", "renderTransport", "ingestBeats",
                "ingestLullSpans", "renderLullSpans", "renderBeatMarkers",
                "ingestLeadSeries", "recordMomentum", "renderMomentum",
                "setVerdict", "getSpoilers", "setSpoilers", "esc", "fmt",
                "setName", "pushFeed", "banner"]:
    check ("function " & alias & "(") notin tail,
      "41: the game block must not define " & alias &
        " -- it would shadow the chrome alias"
    check ("var " & alias & " =") notin tail,
      "41: the game block must not re-bind " & alias
  check "function procgenBeat(" in tail,
    "41: the beat builder is procgenBeat, never markBeat"
  check "markBeat" notin tail,
    "41: the game block never touches the chrome's markBeat at all"

# 42. the beat CSS matches the emitted kinds ---------------------------------
block:
  var declared: seq[string]
  var i = 0
  while true:
    let at = page.find(".beat-marker.", i)
    if at < 0:
      break
    var j = at + len(".beat-marker.")
    var name = ""
    while j < page.len and (page[j].isAlphaNumeric() or page[j] == '-'):
      name.add(page[j])
      inc j
    if name.len > 0 and name notin declared:
      declared.add(name)
    i = at + 1
  var emitted: seq[string]
  for kind in BeatKinds:
    emitted.add($kind)
  for name in declared:
    check name in emitted,
      "42: .beat-marker." & name & " is styled but never emitted"
  for name in emitted:
    check name in declared,
      "42: " & name & " is emitted but has no .beat-marker CSS"
  ## The kinds the starter emitted and this game never does are GONE.
  for gone in ["kill", "steal", "return", "capture", "hillflip", "tagout"]:
    check (".beat-marker." & gone) notin page,
      "42: the starter's " & gone & " beat CSS is removed"

# 43. transport, endcard and the 360 px rules --------------------------------
block:
  check "#endcard { bottom: var(--band" in page or
    "bottom: var(--band, 0px)" in page,
    "43: the endcard stops at the transport band"
  check "root.style.setProperty('--band'" in page and
    "root.style.setProperty('--topband'" in page and
    "root.style.setProperty('--hudscale'" in page,
    "43: relayout() sets --band, --topband and --hudscale on :root"
  check "classList.remove('on')" in page,
    "43: and every seek dismisses the endcard"
  ## The board aspect is the CONSTANT 15/9, so relayout() never re-fits.
  check "var BOARD_W = 15, BOARD_H = 9;" in page,
    "43: BOARD_ASPECT is the constant 15/9"
  check BoardW == 15 and BoardH == 9,
    "43: and the engine agrees with the page"
  ## The four 360 px rules.
  check ".plate-name {" in page and "flex: 1 1 auto;" in page and
    "min-width: 3.2em;" in page,
    "43: .plate-name grows, shrinks and has a floor"
  check "@media (max-width: 640px)" in page,
    "43: labels are hidden under 640 px"
  check "#stage.tiny .plate .split-chip" in page,
    "43: under .tiny the SEEN/UNSEEN chip becomes an underline"
  check "#stage.tiny #momentum { height: 50%; }" in page,
    "43: under .tiny the split graph halves in height"
  check "#stage.tiny #killfeed .feed-row:nth-child(n+4)" in page,
    "43: under .tiny the feed shows three rows"
  ## Nothing the game block adds sits in the transport band.
  let at = page.find(BannerMarker)
  let tail = page[at .. ^1]
  check "#transport" notin tail,
    "43: no game-block element is positioned inside the transport band"
  ## The removed ids appear NOWHERE.
  for gone in ["viewpanel", "minimap", "zoombar", "zoom-in", "zoom-out",
               "zoom-slider", "zoom-read", "fpv", "fpv-canvas", "povBadge",
               "plates-r"]:
    check ("id=\"" & gone & "\"") notin page,
      "43: #" & gone & " is removed, markup and all"
    check ("$('" & gone & "')") notin page,
      "43: and nothing wires #" & gone & " up"
  check "attachMinimap" notin page and "attachMinimap" notin core,
    "43: the minimap is dropped entirely, stubs included"

if failures > 0:
  quit("test_procgen_viewer: " & $failures & " failures", 1)
echo "test_procgen_viewer: ok"
