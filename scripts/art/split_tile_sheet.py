#!/usr/bin/env python3
"""Split the nano-banana sheets into the board sprites the viewer draws.

Sources (committed under scripts/art/source/, generated with
gemini-2.5-flash-image per coworld-builder playbooks/art-nanobanana.md, the
Softmax cog passed as an inline_data style anchor):

  cog_sheet.png       the player cog: side-left, side-right, front, back, a
                      mid-jump pose and a digging pose.
  entities_sheet.png  gem, pellet, boulder, falling boulder, and the hostile
                      hunter cog.
  tiles_sheet.png     bedrock, dirt, platform beam, ladder, spike band, floor,
                      barred door, lit doorway.

Gemini does not return alpha and the "pure green" backdrop comes back as SOME
green with a tinted edge and, often, a slightly different green behind each
sprite. So the key here is not a flood fill from the border but a GREENNESS
test -- a pixel is backdrop when its green channel dominates both others --
which removes every shade of the backdrop at once and keeps the sprites,
including the cyan gem (cyan has green ~= blue) and the amber cog.

Sprites are then found as connected components, ordered left-to-right and
top-to-bottom, cropped, padded square and resized to 128 px RGBA. Facings the
generator did not draw are DERIVED (mirrored) rather than invented, and the
derivation is named in the table below so nothing here is mysterious.

Outputs (128 px RGBA, committed; CI does not regenerate art):

  data/cog_l.png data/cog_r.png data/cog_u.png data/cog_d.png
  data/cog_jump.png data/cog_dig.png
  data/ent_gem.png data/ent_pellet.png data/ent_boulder.png
  data/ent_boulder_falling.png
  data/ent_hunter_l.png data/ent_hunter_r.png data/ent_hunter_u.png
  data/ent_hunter_d.png
  data/tile_bedrock.png data/tile_dirt.png data/tile_platform.png
  data/tile_ladder.png data/tile_spike.png data/tile_floor.png
  data/tile_exit_locked.png data/tile_exit_open.png

Usage:  python3 scripts/art/split_tile_sheet.py
"""

from __future__ import annotations

import os
import sys
from collections import deque

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SOURCE = os.path.join(HERE, "source")
OUT = os.path.join(ROOT, "data")
SIZE = 128


def keyed(path):
    """RGBA with every backdrop green made transparent."""
    image = Image.open(path).convert("RGB")
    width, height = image.size
    pixels = image.load()
    out = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    target = out.load()
    for y in range(height):
        for x in range(width):
            r, g, b = pixels[x, y]
            # Backdrop: the green channel dominates BOTH others by a margin.
            # Cyan (g ~= b) and amber (r > g) survive; every shade of the
            # green screen, including the lighter boxes the generator drew
            # behind each sprite, does not.
            if g > r * 115 // 100 + 8 and g > b * 115 // 100 + 8:
                continue
            target[x, y] = (r, g, b, 255)
    return out


def components(image, min_pixels=400):
    """Connected components of opaque pixels, as (x0, y0, x1, y1) boxes."""
    width, height = image.size
    alpha = image.split()[3].load()
    seen = [[False] * width for _ in range(height)]
    boxes = []
    for sy in range(height):
        for sx in range(width):
            if seen[sy][sx] or alpha[sx, sy] == 0:
                continue
            queue = deque([(sx, sy)])
            seen[sy][sx] = True
            x0 = x1 = sx
            y0 = y1 = sy
            count = 0
            while queue:
                x, y = queue.popleft()
                count += 1
                x0, x1 = min(x0, x), max(x1, x)
                y0, y1 = min(y0, y), max(y1, y)
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < width and 0 <= ny < height and \
                            not seen[ny][nx] and alpha[nx, ny] != 0:
                        seen[ny][nx] = True
                        queue.append((nx, ny))
            if count >= min_pixels:
                boxes.append((x0, y0, x1 + 1, y1 + 1, count))
    return boxes


def merge(boxes, gap=12):
    """Merge boxes that overlap or nearly touch: outlines and speed lines are
    separate components of one sprite."""
    merged = []
    for box in sorted(boxes, key=lambda b: (b[0], b[1])):
        x0, y0, x1, y1, count = box
        hit = None
        for i, (mx0, my0, mx1, my1, mcount) in enumerate(merged):
            if x0 < mx1 + gap and mx0 < x1 + gap and \
                    y0 < my1 + gap and my0 < y1 + gap:
                hit = i
                break
        if hit is None:
            merged.append([x0, y0, x1, y1, count])
        else:
            mx0, my0, mx1, my1, mcount = merged[hit]
            merged[hit] = [min(mx0, x0), min(my0, y0), max(mx1, x1),
                           max(my1, y1), mcount + count]
    return merged


def ordered(boxes, row_tolerance=80):
    """Reading order: top-to-bottom by row band, then left to right."""
    rows = []
    for box in sorted(boxes, key=lambda b: b[1]):
        placed = False
        for row in rows:
            if abs(row[0][1] - box[1]) <= row_tolerance:
                row.append(box)
                placed = True
                break
        if not placed:
            rows.append([box])
    out = []
    for row in rows:
        out.extend(sorted(row, key=lambda b: b[0]))
    return out


def square(image, box, size=SIZE):
    x0, y0, x1, y1 = box[0], box[1], box[2], box[3]
    crop = image.crop((x0, y0, x1, y1))
    side = max(crop.width, crop.height)
    padded = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    padded.paste(crop, ((side - crop.width) // 2, (side - crop.height) // 2))
    return padded.resize((size, size), Image.LANCZOS)


def sprites(name, min_pixels=400):
    path = os.path.join(SOURCE, name)
    image = keyed(path)
    boxes = ordered(merge(components(image, min_pixels)))
    print("%s: %d sprites" % (name, len(boxes)))
    return [square(image, box) for box in boxes]


def profile(image):
    """The mean colour and the near-white fraction of one keyed sprite. What
    a sprite IS is read off its own pixels rather than off its position, so a
    generator that lays the row out differently next time still splits."""
    pixels = image.convert("RGBA").load()
    width, height = image.size
    total = 0
    r = g = b = 0
    white = 0
    for y in range(height):
        for x in range(width):
            pr, pg, pb, pa = pixels[x, y]
            if pa == 0:
                continue
            total += 1
            r += pr
            g += pg
            b += pb
            if pr > 225 and pg > 225 and pb > 225:
                white += 1
    if total == 0:
        return (0, 0, 0, 0.0)
    return (r // total, g // total, b // total, white * 1000 // total)


def save(image, name):
    image.save(os.path.join(OUT, name + ".png"))
    print("  wrote data/%s.png" % name)


def mirror(image):
    return image.transpose(Image.FLIP_LEFT_RIGHT)


def main():
    os.makedirs(OUT, exist_ok=True)

    # ---- the player cog ----------------------------------------------------
    # The sheet draws: side-left, side-right, front, back, jump, dig. `u` is
    # the BACK view (moving away from the camera) and `d` is the FRONT view
    # (moving toward it), which is the convention every top-down-ish tile game
    # uses and the one drawCog reads.
    cog = sprites("cog_sheet.png")
    if len(cog) < 6:
        print("cog_sheet: expected 6 poses, got %d" % len(cog))
        return 1
    # The generator drew BOTH side poses facing the same way, so the
    # right-facing sprite is the left one mirrored -- derived, not invented,
    # and said out loud here rather than left as a coincidence. Pose 2 is
    # therefore unused. `d` is the FRONT view (moving toward the camera) and
    # `u` the BACK view, which is what drawCog reads.
    save(cog[0], "cog_l")
    save(mirror(cog[0]), "cog_r")
    save(cog[2], "cog_d")
    save(cog[3], "cog_u")
    save(cog[4], "cog_jump")
    save(cog[5], "cog_dig")

    # ---- entities ----------------------------------------------------------
    # gem, pellet, boulder, falling boulder, hunter... The generator draws the
    # hunter in two of the four facings; the other two are MIRRORED from them,
    # which is honest for a symmetric chassis and is why they are derived here
    # rather than asked for again.
    ent = sprites("entities_sheet.png")
    if len(ent) < 5:
        print("entities_sheet: expected at least 5 sprites, got %d" % len(ent))
        return 1
    gem = pellet = None
    hunters = []
    boulders = []
    for image in ent:
        r, g, b, white = profile(image)
        if b > r * 130 // 100 and g > r * 110 // 100:
            gem = image                       # cyan crystal
        elif r > g * 140 // 100 and r > b * 140 // 100:
            hunters.append(image)             # the red hostile cog
        elif r > 170 and g > 170 and b < g:
            pellet = image                    # pale cream pellet
        else:
            boulders.append((white, image))   # grey rock; white = speed lines
    if gem is None or pellet is None or not hunters or not boulders:
        print("entities_sheet: could not classify (%d hunters, %d boulders)"
              % (len(hunters), len(boulders)))
        return 1
    boulders.sort(key=lambda pair: pair[0])
    save(gem, "ent_gem")
    save(pellet, "ent_pellet")
    save(boulders[0][1], "ent_boulder")
    # The FALLING boulder is the one the generator drew with speed lines: the
    # most near-white pixels of the grey sprites.
    save(boulders[-1][1], "ent_boulder_falling")
    hunter_a = hunters[0]
    hunter_b = hunters[1] if len(hunters) > 1 else mirror(hunters[0])
    save(hunter_a, "ent_hunter_l")
    save(mirror(hunter_a), "ent_hunter_r")
    save(hunter_b, "ent_hunter_d")
    save(mirror(hunter_b), "ent_hunter_u")

    # ---- tiles -------------------------------------------------------------
    tiles = sprites("tiles_sheet.png", min_pixels=1200)
    wanted = ["tile_bedrock", "tile_dirt", "tile_platform", "tile_ladder",
              "tile_spike", "tile_floor", "tile_exit_locked",
              "tile_exit_open"]
    if len(tiles) < len(wanted):
        print("tiles_sheet: expected %d tiles, got %d"
              % (len(wanted), len(tiles)))
        return 1
    for name, image in zip(wanted, tiles[:len(wanted)]):
        save(image, name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
