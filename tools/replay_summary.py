#!/usr/bin/env python3
"""Print one strict-UTF-8 JSON object describing a procgen replay.

Python 3 standard library only: no Nim, no Docker, no dependencies. This is
the tool a spectator holding the bytes uses, and it is the phase-60 substitute
for the definition-of-done replay check, because this game's replay is the
starter's BINARY COWLDPGN stream rather than JSON:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                      # strict UTF-8 JSON: ok
    jq -r '.protocol, .results.reason, .results.scores, .results.levelReturns' /tmp/ep.json
    jq -r '[.actions[]|select(.source=="llm")]|length, .fallbacks, (.says|length)' /tmp/ep.json

Layout (little-endian; `str` is a u32 length followed by that many bytes):

    magic "COWLDPGN"  u32 format version
    str game name     str game version   str config JSON
    u32 joins         -> u32 slot, str name, str token
    u32 frames        -> one action byte (0=L 1=R 2=U 3=D 4=X 5=. 255=level
                         boundary) and a u64 gameHash
    u32 chats         -> str
"""

import json
import struct
import sys

MAGIC = b"COWLDPGN"
FORMAT_VERSION = 1
SYMBOLS = {0: "L", 1: "R", 2: "U", 3: "D", 4: "X", 5: ".", 255: "|"}


class Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, count):
        if self.pos + count > len(self.data):
            raise ValueError("replay truncated")
        out = self.data[self.pos:self.pos + count]
        self.pos += count
        return out

    def u32(self):
        return struct.unpack("<I", self.take(4))[0]

    def u64(self):
        return struct.unpack("<Q", self.take(8))[0]

    def text(self):
        # Every recorded string was truncated on a RUNE boundary by the
        # engine, so a strict decode is the right decode: a byte-truncated
        # multi-byte character would raise here rather than smuggle a lone
        # surrogate into the JSON.
        return self.take(self.u32()).decode("utf-8")


def summarize(path):
    data = open(path, "rb").read()
    if data[:len(MAGIC)] != MAGIC:
        raise ValueError("not a procgen replay: bad magic %r" % data[:8])
    reader = Reader(data[len(MAGIC):])
    version = reader.u32()
    if version != FORMAT_VERSION:
        raise ValueError("replay format version %d is not %d"
                         % (version, FORMAT_VERSION))
    game_name = reader.text()
    game_version = reader.text()
    config = json.loads(reader.text())

    joins = []
    for _ in range(reader.u32()):
        slot = reader.u32()
        name = reader.text()
        token = reader.text()
        joins.append({"slot": slot, "name": name, "token": bool(token)})

    frames = []
    for _ in range(reader.u32()):
        action = reader.take(1)[0]
        digest = reader.u64()
        frames.append((action, digest))

    chats = [reader.text() for _ in range(reader.u32())]

    actions = []
    says = []
    notes_count = 0
    fallbacks = 0
    interrupts = 0
    results = {}
    for record in chats:
        if not record.startswith("{"):
            continue
        try:
            node = json.loads(record)
        except ValueError:
            continue
        kind = node.get("k")
        if kind == "directive":
            actions.append({
                "turn": node.get("turn"),
                "level": node.get("level"),
                "source": node.get("source"),
                "moves": node.get("moves"),
                "executed": node.get("executed"),
                "repaired": node.get("repaired"),
            })
            if node.get("say"):
                says.append(node["say"])
            if node.get("moves") and node.get("executed", 0) < len(
                    node.get("moves", "")):
                interrupts += 1
        elif kind == "fallback":
            fallbacks += 1
        elif kind == "result":
            results = node.get("results", {})

    return {
        "protocol": config.get("protocol", "procgen/v1"),
        "gameName": game_name,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "variant": config.get("variant"),
        "difficulty": config.get("difficulty"),
        "levelCount": config.get("levelCount"),
        "levelKinds": config.get("levelKinds", []),
        "levelSeeds": config.get("levelSeeds", []),
        "levelSplit": config.get("levelSplit", []),
        "names": [j["name"] for j in joins],
        "aliases": config.get("aliases", []),
        "policyKinds": config.get("policyKinds", []),
        "frameCount": len(frames),
        "levels": sum(1 for action, _ in frames if action == 255),
        "actions": actions,
        "says": says,
        "notes_count": notes_count,
        "fallbacks": fallbacks,
        "interrupts": interrupts,
        "results": results,
    }


def main():
    if len(sys.argv) != 2:
        print("usage: replay_summary.py <file.replay>", file=sys.stderr)
        return 2
    summary = summarize(sys.argv[1])
    # ensure_ascii=False keeps the real text; the file is UTF-8 by construction
    # and every capped field was cut on a rune boundary.
    sys.stdout.write(json.dumps(summary, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
