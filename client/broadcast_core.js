// broadcast_core.js — procgen board renderer + frame-packet client.
//
// FORKED from coworld-ctf's client/broadcast_core.js. That file is paintbot's
// continuous-2-D draw layer over the Bitworld sprite protocol; this game is a
// 15 x 9 integer tile grid, so the sprite/layer compositor, every weapon,
// paint, hill, flag and fog draw call, the first-person pipeline and the whole
// zoom/pan/minimap surface are DELETED (design note §Viewer -> Chrome
// provenance: #viewpanel goes entirely — every level in every archetype is the
// same fixed rectangle with no off-frame area). What is KEPT is the shape the
// page depends on: the same `window.BroadcastCore.create` factory and the same
// method surface, the canvas/DPR sizing, the letterbox fit and its
// `onTransform` callback, the status/text callbacks, the first-frame signal
// and the pace stats.
//
// ADDED: drawTiles, drawCog (four facings, a jump squash and a dig pose),
// drawEntities (gems, pellets, boulders with a fall streak, hunters with eyes,
// spikes), drawExit (BARRED vs LIT — the single most important state change on
// the board, so it is a silhouette change and not a colour change),
// drawPlanTrail and drawSplitBar.
//
// The wire is one JSON frame packet per drawn frame (see
// src/procgen/broadcast.nim). Its `chrome` field is handed to onText, exactly
// as the starter smuggled its chrome document through the same channel the
// board rides, so the HUD survives every playback path.
//
// Dependency-free IIFE; runs in a Window and in a Dedicated Worker with an
// OffscreenCanvas, one implementation, so protocol and rendering fixes cannot
// drift between the two delivery modes.
(function () {
  'use strict';

  var globalScope = typeof window !== 'undefined' ? window : self;
  var requestFrame = typeof globalScope.requestAnimationFrame === 'function'
    ? globalScope.requestAnimationFrame.bind(globalScope)
    : function (cb) { return setTimeout(function () { cb(Date.now()); }, 16); };
  var cancelFrame = typeof globalScope.cancelAnimationFrame === 'function'
    ? globalScope.cancelAnimationFrame.bind(globalScope)
    : clearTimeout;

  var WIRE = globalScope.PROCGEN_WIRE || {};
  var BOARD_W = WIRE.boardW || 15;
  var BOARD_H = WIRE.boardH || 9;
  // The tile enum, by ORDINAL — the wire value src/procgen/tiles.nim emits.
  var T_EMPTY = 0, T_WALL = 1, T_DIRT = 2, T_BOULDER = 3, T_GEM = 4,
      T_PELLET = 5, T_EXIT_LOCKED = 6, T_EXIT_OPEN = 7, T_PLATFORM = 8,
      T_LADDER = 9, T_SPIKE = 10;
  var TILE_SPRITE = {};
  TILE_SPRITE[T_WALL] = 'tile_bedrock';
  TILE_SPRITE[T_DIRT] = 'tile_dirt';
  TILE_SPRITE[T_PLATFORM] = 'tile_platform';
  TILE_SPRITE[T_LADDER] = 'tile_ladder';
  TILE_SPRITE[T_SPIKE] = 'tile_spike';
  TILE_SPRITE[T_EXIT_LOCKED] = 'tile_exit_locked';
  TILE_SPRITE[T_EXIT_OPEN] = 'tile_exit_open';
  TILE_SPRITE[T_EMPTY] = 'tile_floor';
  var ENTITY_SPRITE = {};
  ENTITY_SPRITE[T_GEM] = 'ent_gem';
  ENTITY_SPRITE[T_PELLET] = 'ent_pellet';
  ENTITY_SPRITE[T_BOULDER] = 'ent_boulder';
  var COG_FACING = ['cog_l', 'cog_r', 'cog_u', 'cog_d'];
  var HUNTER_FACING = ['ent_hunter_l', 'ent_hunter_r', 'ent_hunter_u',
                       'ent_hunter_d'];
  var textDecoder = new TextDecoder('utf-8');

  var INK = '#2a1f16', PAPER = '#f2e8d8', AMBER = '#e8a33d',
      HAZARD = '#e0523a', SLATE = '#3f7cc4', GHOST = '#8a7f72';

  // ---- sprite kit ---------------------------------------------------------
  // Every character sprite is a nano-banana render of the Softmax cog, split
  // by scripts/art/split_tile_sheet.py and shipped next to this file in the
  // static bundle. Loading is best-effort and never blocks a frame: until an
  // image lands the tile draws as its procedural plate in the same palette, so
  // a slow asset can never stop the board from rendering.
  var art = {};
  var artBase = '.';
  function loadArt(name) {
    if (art[name] !== undefined) return;
    art[name] = null;
    var url = artBase + '/' + name + '.png';
    if (typeof createImageBitmap === 'function' &&
        typeof fetch === 'function') {
      fetch(url, { credentials: 'omit' })
        .then(function (r) { return r.ok ? r.blob() : null; })
        .then(function (b) { return b ? createImageBitmap(b) : null; })
        .then(function (bmp) { if (bmp) art[name] = bmp; })
        .catch(function () { });
    } else if (typeof Image === 'function') {
      var img = new Image();
      img.onload = function () { art[name] = img; };
      img.src = url;
    }
  }
  function loadKit() {
    var names = ['tile_bedrock', 'tile_dirt', 'tile_platform', 'tile_ladder',
      'tile_spike', 'tile_floor', 'tile_exit_locked', 'tile_exit_open',
      'ent_gem', 'ent_pellet', 'ent_boulder', 'ent_boulder_falling',
      'ent_hunter_l', 'ent_hunter_r', 'ent_hunter_u', 'ent_hunter_d',
      'cog_l', 'cog_r', 'cog_u', 'cog_d', 'cog_jump', 'cog_dig'];
    for (var i = 0; i < names.length; i++) loadArt(names[i]);
  }

  // ---- the say bubble's type ----------------------------------------------
  // The bubble is laid out from the cap the SERVER enforces (MaxSayRunes),
  // measured in the font it is drawn in — never from whatever string happens
  // to be in flight, which is how a remark grows into whatever is above it
  // (the cogchemists 2026-08-24 scar).
  var MAX_SAY_RUNES = WIRE.maxSayRunes || 24;
  var SAY_FACE = 'system-ui, sans-serif';
  var SAY_CAP_SAMPLE = new Array(MAX_SAY_RUNES + 1).join('W');
  var sayCapWidths = {};
  function sayFontFor(cell) { return Math.max(9, Math.round(cell * 0.42)); }
  function sayBandFor(cell) { return Math.round(sayFontFor(cell) * 1.8) + 4; }
  function loadSayFace() {
    if (typeof globalScope.FontFace !== 'function' || !globalScope.fonts) return;
    try {
      var face = new globalScope.FontFace('procgenface',
        'url(' + artBase + '/font.ttf)');
      face.load().then(function (loaded) {
        globalScope.fonts.add(loaded);
        SAY_FACE = '"procgenface", system-ui, sans-serif';
        sayCapWidths = {};              // re-measure the cap in the real face
      }).catch(function () { });
    } catch (error) { /* the fallback stack is already correct */ }
  }
  function shade(hex, f) {
    var n = parseInt(hex.slice(1), 16);
    var r = Math.max(0, Math.min(255, Math.round(((n >> 16) & 255) * f)));
    var g = Math.max(0, Math.min(255, Math.round(((n >> 8) & 255) * f)));
    var b = Math.max(0, Math.min(255, Math.round((n & 255) * f)));
    return 'rgb(' + r + ',' + g + ',' + b + ')';
  }
  function roundRect(ctx, x, y, w, h, r) {
    var rr = Math.min(r, w / 2, h / 2);
    ctx.beginPath();
    ctx.moveTo(x + rr, y);
    ctx.arcTo(x + w, y, x + w, y + h, rr);
    ctx.arcTo(x + w, y + h, x, y + h, rr);
    ctx.arcTo(x, y + h, x, y, rr);
    ctx.arcTo(x, y, x + w, y, rr);
    ctx.closePath();
  }

  function BroadcastCore(config) {
    var canvas = config.canvas;
    var onText = config.onText || function () { };
    var onStatus = config.onStatus || function () { };
    var onFirstFrame = config.onFirstFrame || function () { };
    var onTransform = config.onTransform || function () { };
    var onSendPacket = config.onSendPacket || null;
    var ctx = canvas.getContext('2d');

    var state = null;
    var chromeJson = '';
    var firstFrameFired = false;
    var rafHandle = null;
    var dirty = false;
    var stopped = false;
    var drawCount = 0;
    var viewportWidth = Number(config.viewportWidth) || 0;
    var viewportHeight = Number(config.viewportHeight) || 0;
    var pixelRatio = Number(config.devicePixelRatio) ||
      (globalScope.devicePixelRatio || 1);
    var transform = {
      scale: 1, offsetX: 0, offsetY: 0, nativeW: 1, nativeH: 1,
      zoom: 1, minZoom: 1, maxZoom: 1, fitScale: 1,
      focusX: 0, focusY: 0, visW: 1, visH: 1
    };

    loadKit();
    loadSayFace();

    function cssSize() {
      var w = viewportWidth || canvas.width || 1;
      var h = viewportHeight || canvas.height || 1;
      return { w: Math.max(1, w), h: Math.max(1, h) };
    }

    function syncCanvas() {
      var size = cssSize();
      var w = Math.max(1, Math.round(size.w * pixelRatio));
      var h = Math.max(1, Math.round(size.h * pixelRatio));
      if (canvas.width !== w) canvas.width = w;
      if (canvas.height !== h) canvas.height = h;
    }

    function boardGeometry() {
      var size = cssSize();
      var bw = (state && state.board && state.board.w) || BOARD_W;
      var bh = (state && state.board && state.board.h) || BOARD_H;
      var availW = size.w * pixelRatio;
      var availH = size.h * pixelRatio;
      // The say band and the split bar are RESERVED whether or not anybody is
      // speaking, so the board does not move when a remark lands and a
      // top-row cog's bubble always has somewhere to go.
      var cell = Math.max(2, Math.floor(Math.min(availW / bw, availH / bh)));
      var band = sayBandFor(cell);
      var barH = Math.max(6, Math.round(cell * 0.34));
      cell = Math.max(2, Math.floor(
        Math.min(availW / bw, Math.max(1, availH - band - barH) / bh)));
      band = sayBandFor(cell);
      barH = Math.max(6, Math.round(cell * 0.34));
      var pxW = cell * bw;
      var pxH = cell * bh;
      var ox = Math.round((availW - pxW) / 2);
      var oy = band + Math.round(Math.max(0, availH - band - barH - pxH) / 2);
      return { cell: cell, ox: ox, oy: oy, w: bw, h: bh, pxW: pxW, pxH: pxH,
               band: band, barH: barH, availW: availW, availH: availH };
    }

    function publishTransform(g) {
      var next = {
        scale: g.cell, offsetX: g.ox, offsetY: g.oy,
        nativeW: g.w, nativeH: g.h,
        zoom: 1, minZoom: 1, maxZoom: 1, fitScale: g.cell,
        focusX: g.w / 2, focusY: g.h / 2, visW: g.w, visH: g.h
      };
      if (next.scale !== transform.scale || next.offsetX !== transform.offsetX ||
          next.offsetY !== transform.offsetY ||
          next.nativeW !== transform.nativeW ||
          next.nativeH !== transform.nativeH) {
        transform = next;
        onTransform(transform);
      }
    }

    // ---- the board ---------------------------------------------------------
    function drawFloor(g) {
      ctx.fillStyle = '#16110d';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      var grad = ctx.createLinearGradient(g.ox, g.oy, g.ox, g.oy + g.pxH);
      grad.addColorStop(0, '#241a12');
      grad.addColorStop(1, '#17110c');
      ctx.fillStyle = grad;
      ctx.fillRect(g.ox, g.oy, g.pxW, g.pxH);
      // A faint scanline wash — the native-pixel CRT floor.
      ctx.fillStyle = 'rgba(0,0,0,0.16)';
      for (var y = 0; y < g.pxH; y += 3) {
        ctx.fillRect(g.ox, g.oy + y, g.pxW, 1);
      }
    }

    function tileAt(x, y) {
      var cells = state.grid || [];
      var index = y * ((state.board && state.board.w) || BOARD_W) + x;
      return cells[index] === undefined ? T_EMPTY : cells[index];
    }

    function drawSprite(name, x, y, cell, alpha) {
      var img = art[name];
      if (!img) return false;
      if (alpha !== undefined && alpha < 1) ctx.globalAlpha = alpha;
      ctx.drawImage(img, x, y, cell, cell);
      ctx.globalAlpha = 1;
      return true;
    }

    function drawTiles(g) {
      for (var y = 0; y < g.h; y++) {
        for (var x = 0; x < g.w; x++) {
          var t = tileAt(x, y);
          var px = g.ox + x * g.cell;
          var py = g.oy + y * g.cell;
          if (t === T_EMPTY) continue;
          if (t === T_GEM || t === T_PELLET || t === T_BOULDER) continue;
          if (t === T_EXIT_LOCKED || t === T_EXIT_OPEN) continue;
          if (drawSprite(TILE_SPRITE[t], px, py, g.cell)) continue;
          // Procedural fallback, in the bake's palette. Silhouette first:
          // bedrock is a riveted block, dirt a granular fill, a platform a
          // beam, a ladder rungs, spikes a lit hazard band.
          if (t === T_WALL) {
            ctx.fillStyle = '#3b2f24';
            ctx.fillRect(px, py, g.cell, g.cell);
            ctx.fillStyle = 'rgba(242,232,216,0.10)';
            ctx.fillRect(px + 2, py + 2, g.cell - 4, 2);
            ctx.fillStyle = 'rgba(0,0,0,0.25)';
            ctx.fillRect(px + 2, py + g.cell - 4, g.cell - 4, 2);
          } else if (t === T_DIRT) {
            ctx.fillStyle = '#6b4a2c';
            ctx.fillRect(px, py, g.cell, g.cell);
            ctx.fillStyle = 'rgba(0,0,0,0.22)';
            for (var d = 0; d < 5; d++) {
              ctx.fillRect(px + ((d * 7) % (g.cell - 3)),
                py + ((d * 11) % (g.cell - 3)), 2, 2);
            }
          } else if (t === T_PLATFORM) {
            ctx.fillStyle = '#8a6a44';
            ctx.fillRect(px, py + g.cell * 0.18, g.cell, g.cell * 0.64);
            ctx.fillStyle = 'rgba(0,0,0,0.3)';
            ctx.fillRect(px, py + g.cell * 0.7, g.cell, 2);
          } else if (t === T_LADDER) {
            ctx.strokeStyle = AMBER;
            ctx.lineWidth = Math.max(1, g.cell / 12);
            ctx.beginPath();
            ctx.moveTo(px + g.cell * 0.28, py);
            ctx.lineTo(px + g.cell * 0.28, py + g.cell);
            ctx.moveTo(px + g.cell * 0.72, py);
            ctx.lineTo(px + g.cell * 0.72, py + g.cell);
            for (var r = 1; r <= 2; r++) {
              ctx.moveTo(px + g.cell * 0.28, py + g.cell * r / 3);
              ctx.lineTo(px + g.cell * 0.72, py + g.cell * r / 3);
            }
            ctx.stroke();
          } else if (t === T_SPIKE) {
            ctx.fillStyle = HAZARD;
            for (var s = 0; s < 3; s++) {
              ctx.beginPath();
              ctx.moveTo(px + g.cell * (0.1 + s * 0.3), py + g.cell);
              ctx.lineTo(px + g.cell * (0.25 + s * 0.3), py + g.cell * 0.3);
              ctx.lineTo(px + g.cell * (0.4 + s * 0.3), py + g.cell);
              ctx.closePath();
              ctx.fill();
            }
          }
        }
      }
    }

    function isFalling(x, y) {
      var list = state.falling || [];
      for (var i = 0; i < list.length; i++) {
        if (list[i][0] === x && list[i][1] === y) return true;
      }
      return false;
    }

    function drawEntities(g, phase) {
      for (var y = 0; y < g.h; y++) {
        for (var x = 0; x < g.w; x++) {
          var t = tileAt(x, y);
          if (t !== T_GEM && t !== T_PELLET && t !== T_BOULDER) continue;
          var px = g.ox + x * g.cell;
          var py = g.oy + y * g.cell;
          if (t === T_BOULDER && isFalling(x, y)) {
            // A falling boulder gets a motion streak: the one entity on the
            // board that can kill from off-screen must never be still.
            ctx.fillStyle = 'rgba(232,163,61,0.28)';
            ctx.fillRect(px + g.cell * 0.3, py - g.cell * 0.6,
              g.cell * 0.4, g.cell * 0.6);
            if (drawSprite('ent_boulder_falling', px, py, g.cell)) continue;
          }
          if (drawSprite(ENTITY_SPRITE[t], px, py, g.cell)) continue;
          if (t === T_BOULDER) {
            ctx.fillStyle = '#7b7168';
            ctx.beginPath();
            ctx.arc(px + g.cell / 2, py + g.cell / 2, g.cell * 0.4, 0,
              Math.PI * 2);
            ctx.fill();
            ctx.strokeStyle = 'rgba(0,0,0,0.35)';
            ctx.lineWidth = Math.max(1, g.cell / 14);
            ctx.stroke();
          } else {
            // Gems and pellets PULSE, so a collectible is never mistaken for
            // scenery.
            var pulse = 0.82 + 0.18 * Math.sin(phase * 6.28);
            ctx.fillStyle = t === T_GEM ? '#7fd3f0' : PAPER;
            ctx.beginPath();
            if (t === T_GEM) {
              var cx = px + g.cell / 2, cy = py + g.cell / 2;
              var rr = g.cell * 0.3 * pulse;
              ctx.moveTo(cx, cy - rr);
              ctx.lineTo(cx + rr, cy);
              ctx.lineTo(cx, cy + rr);
              ctx.lineTo(cx - rr, cy);
              ctx.closePath();
            } else {
              ctx.arc(px + g.cell / 2, py + g.cell / 2, g.cell * 0.17 * pulse,
                0, Math.PI * 2);
            }
            ctx.fill();
          }
        }
      }
    }

    function drawExit(g) {
      var exit = state.exit || { x: 0, y: 0, open: false };
      var px = g.ox + exit.x * g.cell;
      var py = g.oy + exit.y * g.cell;
      var name = exit.open ? 'tile_exit_open' : 'tile_exit_locked';
      if (drawSprite(name, px, py, g.cell)) return;
      // BARRED while locked, a LIT DOORWAY once open: a silhouette change,
      // not a colour change, so it survives at 13 screen pixels a tile.
      ctx.fillStyle = exit.open ? '#f6e2a8' : '#241a12';
      ctx.fillRect(px + g.cell * 0.12, py + g.cell * 0.08,
        g.cell * 0.76, g.cell * 0.9);
      ctx.strokeStyle = exit.open ? AMBER : GHOST;
      ctx.lineWidth = Math.max(1, g.cell / 12);
      ctx.strokeRect(px + g.cell * 0.12, py + g.cell * 0.08,
        g.cell * 0.76, g.cell * 0.9);
      if (!exit.open) {
        ctx.beginPath();
        for (var b = 1; b <= 3; b++) {
          ctx.moveTo(px + g.cell * 0.12, py + g.cell * (0.08 + b * 0.22));
          ctx.lineTo(px + g.cell * 0.88, py + g.cell * (0.08 + b * 0.22));
        }
        ctx.stroke();
      }
    }

    function drawHunters(g) {
      var list = state.hunters || [];
      var cog = state.cog || { x: 0, y: 0 };
      for (var i = 0; i < list.length; i++) {
        var hx = list[i][0], hy = list[i][1];
        var px = g.ox + hx * g.cell;
        var py = g.oy + hy * g.cell;
        // The eyes TRACK the cog, so a spectator can read who is being hunted.
        var dx = cog.x - hx, dy = cog.y - hy;
        var facing = Math.abs(dx) >= Math.abs(dy)
          ? (dx < 0 ? 0 : 1) : (dy < 0 ? 2 : 3);
        if (drawSprite(HUNTER_FACING[facing], px, py, g.cell)) continue;
        ctx.fillStyle = '#8a3a52';
        roundRect(ctx, px + g.cell * 0.1, py + g.cell * 0.1,
          g.cell * 0.8, g.cell * 0.8, g.cell * 0.22);
        ctx.fill();
        ctx.fillStyle = PAPER;
        var ex = px + g.cell * (0.5 + (dx < 0 ? -0.12 : dx > 0 ? 0.12 : 0));
        var ey = py + g.cell * (0.44 + (dy < 0 ? -0.08 : dy > 0 ? 0.08 : 0));
        ctx.beginPath();
        ctx.arc(ex - g.cell * 0.12, ey, g.cell * 0.08, 0, Math.PI * 2);
        ctx.arc(ex + g.cell * 0.12, ey, g.cell * 0.08, 0, Math.PI * 2);
        ctx.fill();
      }
    }

    function drawCog(g, alpha) {
      var cog = state.cog || { x: 0, y: 0, dir: 1, alive: true };
      var px = g.ox + (cog.px + (cog.x - cog.px) * alpha) * g.cell;
      var py = g.oy + (cog.py + (cog.y - cog.py) * alpha) * g.cell;
      var name = COG_FACING[cog.dir === undefined ? 1 : cog.dir];
      if (cog.jump > 0) name = 'cog_jump';
      if (!cog.alive) {
        ctx.globalAlpha = 0.45;
      }
      if (!drawSprite(name, px, py, g.cell)) {
        var squash = cog.fall > 0 ? 0.86 : 1;
        ctx.fillStyle = cog.alive ? AMBER : GHOST;
        roundRect(ctx, px + g.cell * 0.1,
          py + g.cell * (0.1 + (1 - squash) * 0.4),
          g.cell * 0.8, g.cell * 0.8 * squash, g.cell * 0.24);
        ctx.fill();
        ctx.fillStyle = INK;
        ctx.fillRect(px + g.cell * 0.28, py + g.cell * 0.4,
          g.cell * 0.44, g.cell * 0.12);
      }
      ctx.globalAlpha = 1;
      if (!cog.alive) {
        ctx.strokeStyle = HAZARD;
        ctx.lineWidth = Math.max(2, g.cell / 6);
        ctx.beginPath();
        ctx.moveTo(px + g.cell * 0.15, py + g.cell * 0.15);
        ctx.lineTo(px + g.cell * 0.85, py + g.cell * 0.85);
        ctx.moveTo(px + g.cell * 0.85, py + g.cell * 0.15);
        ctx.lineTo(px + g.cell * 0.15, py + g.cell * 0.85);
        ctx.stroke();
      }
    }

    // The readout that makes an LLM's actual decision visible: the turn's six
    // symbols drawn as a ghost arrow chain from the cog, consumed one arrow
    // per frame as it executes. The unspent tail of an INTERRUPTED plan greys
    // out and a small CUT tag appears.
    function drawPlanTrail(g) {
      var plan = state.plan || { moves: '', run: 0, cut: false };
      var moves = String(plan.moves || '');
      if (!moves.length) return;
      var cog = state.cog || { x: 0, y: 0 };
      var x = cog.px === undefined ? cog.x : cog.px;
      var y = cog.py === undefined ? cog.y : cog.py;
      ctx.lineWidth = Math.max(1, g.cell / 10);
      ctx.font = Math.max(8, Math.round(g.cell * 0.4)) + 'px ' + SAY_FACE;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      for (var i = 0; i < moves.length; i++) {
        var m = moves.charAt(i);
        if (m === 'L') x -= 1;
        else if (m === 'R') x += 1;
        else if (m === 'U') y -= 1;
        else if (m === 'D') y += 1;
        var cx = g.ox + (x + 0.5) * g.cell;
        var cy = g.oy + (y + 0.5) * g.cell;
        var spent = i < plan.run;
        ctx.globalAlpha = spent ? 0.16 : 0.55;
        ctx.strokeStyle = spent ? GHOST : AMBER;
        ctx.beginPath();
        ctx.arc(cx, cy, g.cell * 0.22, 0, Math.PI * 2);
        ctx.stroke();
        if (m === 'X' || m === '.') {
          ctx.fillStyle = spent ? GHOST : AMBER;
          ctx.fillText(m, cx, cy);
        }
        ctx.globalAlpha = 1;
      }
      if (plan.cut && plan.run < moves.length) {
        var tx = g.ox + (x + 0.5) * g.cell;
        var ty = g.oy + (y + 0.5) * g.cell;
        ctx.fillStyle = HAZARD;
        ctx.font = Math.max(7, Math.round(g.cell * 0.3)) + 'px ' + SAY_FACE;
        ctx.fillText('CUT', tx, Math.max(6, ty - g.cell * 0.5));
      }
      ctx.textAlign = 'left';
      ctx.textBaseline = 'alphabetic';
    }

    // The idea's "seen levels vs unseen split score", drawn literally under
    // the board: one bar per level in play order, seen bars in SLATE and
    // unseen bars in AMBER, with the two mean lines. Full width from the
    // pre-scan on the first frame.
    function drawSplitBar(g) {
      var chrome = state.chrome || {};
      var split = chrome.splitbar;
      if (!split || !split.bars || !split.bars.length) return;
      var bars = split.bars;
      var top = g.oy + g.pxH + Math.round(g.barH * 0.2);
      var h = g.barH;
      var w = g.pxW / bars.length;
      var current = chrome.level || 0;
      for (var i = 0; i < bars.length; i++) {
        var bx = g.ox + i * w;
        ctx.fillStyle = 'rgba(242,232,216,0.10)';
        ctx.fillRect(bx + 1, top, w - 2, h);
        var value = Math.max(0, Math.min(1000, bars[i]['return'] || 0));
        var fill = Math.round(h * value / 1000);
        ctx.fillStyle = bars[i].split === 'unseen' ? AMBER : SLATE;
        ctx.globalAlpha = (i + 1) === current ? 1 : 0.8;
        ctx.fillRect(bx + 1, top + h - fill, w - 2, fill);
        ctx.globalAlpha = 1;
      }
      var seenY = top + h - Math.round(h * (split.seenMilli || 0) / 1000);
      var unseenY = top + h - Math.round(h * (split.unseenMilli || 0) / 1000);
      ctx.strokeStyle = SLATE;
      ctx.setLineDash([4, 3]);
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(g.ox, seenY);
      ctx.lineTo(g.ox + g.pxW, seenY);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.strokeStyle = AMBER;
      ctx.beginPath();
      ctx.moveTo(g.ox, unseenY);
      ctx.lineTo(g.ox + g.pxW, unseenY);
      ctx.stroke();
    }

    function drawFlashes(g, alpha) {
      var list = state.flashes || [];
      for (var i = 0; i < list.length; i++) {
        var f = list[i];
        var cx = g.ox + (f.x + 0.5) * g.cell;
        var cy = g.oy + (f.y + 0.5) * g.cell;
        ctx.strokeStyle = f.k === 'death' ? HAZARD
          : f.k === 'exitopen' ? PAPER : AMBER;
        ctx.globalAlpha = Math.max(0, 1 - alpha);
        ctx.lineWidth = Math.max(2, g.cell / 6);
        ctx.beginPath();
        ctx.arc(cx, cy, g.cell * (0.3 + 0.5 * alpha), 0, Math.PI * 2);
        ctx.stroke();
        ctx.globalAlpha = 1;
      }
    }

    function sayBoxWidth(font) {
      if (sayCapWidths[font] === undefined) {
        var was = ctx.font;
        ctx.font = font + 'px ' + SAY_FACE;
        sayCapWidths[font] = Math.ceil(
          ctx.measureText(SAY_CAP_SAMPLE).width + font);
        ctx.font = was;
      }
      return sayCapWidths[font];
    }

    function drawBubbles(g) {
      var list = state.bubbles || [];
      if (!list.length) return;
      var font = sayFontFor(g.cell);
      while (font > 9 && sayBoxWidth(font) > g.pxW - 4) font -= 1;
      var w = Math.min(sayBoxWidth(font), Math.max(16, g.pxW - 4));
      var h = font * 1.8;
      ctx.font = font + 'px ' + SAY_FACE;
      ctx.textBaseline = 'middle';
      for (var i = 0; i < list.length; i++) {
        var b = list[i];
        var text = String(b.text || '');
        if (!text) continue;
        // The box is laid out from the server's own cap on this string and
        // then CLAMPED INSIDE THE CANVAS, so a bubble on a top-row cog is
        // never drawn at a negative y (the cogchemists 2026-08-24 scar): it
        // rides the reserved band above the board instead.
        var x = g.ox + (b.x + 0.5) * g.cell - w / 2;
        var y = g.oy + b.y * g.cell - h - 2;
        if (x < 2) x = 2;
        if (x + w > canvas.width - 2) x = canvas.width - w - 2;
        if (y < 2) y = 2;
        if (y + h > canvas.height - 2) y = canvas.height - h - 2;
        ctx.fillStyle = 'rgba(20,14,9,0.86)';
        roundRect(ctx, x, y, w, h, h / 3);
        ctx.fill();
        ctx.strokeStyle = AMBER;
        ctx.lineWidth = 1.5;
        ctx.stroke();
        ctx.fillStyle = PAPER;
        ctx.textAlign = 'center';
        ctx.fillText(text, x + w / 2, y + h / 2);
      }
      ctx.textAlign = 'left';
      ctx.textBaseline = 'alphabetic';
    }

    function draw() {
      if (!state) return;
      syncCanvas();
      var g = boardGeometry();
      publishTransform(g);
      var alpha = Math.max(0, Math.min(1, (state.alpha || 0) / 1000));
      var phase = (drawCount % 24) / 24;
      drawFloor(g);
      drawTiles(g);
      drawExit(g);
      drawEntities(g, phase);
      drawPlanTrail(g);
      drawHunters(g);
      drawCog(g, alpha);
      drawFlashes(g, alpha);
      drawSplitBar(g);
      drawBubbles(g);
      drawCount++;
      if (!firstFrameFired) {
        firstFrameFired = true;
        onStatus('live');
        onFirstFrame();
      }
    }

    function scheduleDraw() {
      if (dirty || stopped) return;
      dirty = true;
      rafHandle = requestFrame(function () {
        dirty = false;
        rafHandle = null;
        try { draw(); } catch (e) { onStatus('error'); throw e; }
      });
    }

    function ingest(bytes) {
      var text = typeof bytes === 'string'
        ? bytes : textDecoder.decode(bytes);
      var packet = JSON.parse(text);
      state = packet;
      if (!state.grid) state.grid = [];
      if (!state.hunters) state.hunters = [];
      if (!state.bubbles) state.bubbles = [];
      if (!state.flashes) state.flashes = [];
      var chrome = JSON.stringify(packet.chrome || {});
      if (chrome !== chromeJson) {
        chromeJson = chrome;
        onText(chrome);
      }
      draw();
    }

    return {
      ingest: ingest,
      start: function () { onStatus('connecting'); scheduleDraw(); },
      stop: function () {
        stopped = true;
        if (rafHandle) cancelFrame(rafHandle);
      },
      sendCommand: function (text) {
        if (onSendPacket) {
          onSendPacket(new TextEncoder().encode(String(text)));
        }
      },
      clickMap: function () { },
      setViewportSize: function (w, h, dpr) {
        viewportWidth = Number(w) || viewportWidth;
        viewportHeight = Number(h) || viewportHeight;
        pixelRatio = Number(dpr) || pixelRatio;
        scheduleDraw();
      },
      setViewportFit: function () { scheduleDraw(); },
      getTransform: function () { return transform; },
      // The zoom bar and the minimap (#viewpanel) are DROPPED for this game --
      // markup, CSS, wiring and stubs. Every level in every archetype and
      // every variant is the same fixed 15 x 9 rectangle with no off-frame
      // area, so there is nothing to pan to and nothing to shrink into a
      // minimap. The no-op stubs are gone too: a method that exists and does
      // nothing is indistinguishable from one that works.
      getPaceStats: function () {
        return { enabled: false, queued: 0, presented: 0, interval: 1000 / 24,
          draws: drawCount };
      }
    };
  }

  globalScope.BroadcastCore = {
    create: function (config) { return BroadcastCore(config); }
  };
})();
