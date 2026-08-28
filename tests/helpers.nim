## Shared assertion helpers for the procgen suite.

import std/strutils

type Checker* = object
  name*: string
  failures*: int

proc newChecker*(name: string): Checker = Checker(name: name, failures: 0)

proc check*(c: var Checker, ok: bool, what: string) =
  if not ok:
    c.failures.inc
    echo "FAIL: ", what

proc report*(c: Checker) =
  if c.failures > 0:
    quit(c.name & ": " & $c.failures & " failures", 1)
  echo c.name, ": ok"

proc containsAll*(text: string, needles: openArray[string]): bool =
  for n in needles:
    if n notin text:
      return false
  true
