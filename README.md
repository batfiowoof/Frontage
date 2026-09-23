# Frontage

A 2D prototype in Godot 4.7: a turn-based, Civ-like campaign on a hex map, with
real-time, Total War-like battles whenever two armies meet. Multiplayer over ENet
with a listen server (one player hosts), server-authoritative.

## Requirements

- Windows
- Godot 4.7.2. The `.cmd` scripts expect it at
  `C:\Users\bojid\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe`;
  edit that path in them if yours lives elsewhere.

On a fresh clone, `play.cmd` builds Godot's import cache once before it launches.

## Play

	play.cmd                  two windows, host and client, on the campaign
	play.cmd solo             one window, you against an AI
	play.cmd demo             two windows, straight into a staged battle
	play.cmd fight            one window, a staged battle against an AI
	play.cmd replay <path>    watch a recorded battle (saved to user://replays/)

**Campaign:** left-click an army, click a tile to march, click your own town to
recruit or build, End Turn bottom-right. WASD or drag to pan, wheel to zoom.

**Battle:** deploy in your half, then press begin. Left-click or box-drag to select,
right-click to move, right-drag to draw the line (its length sets the frontage),
right-click an enemy to attack it. G guards, H skirmishes, Ctrl+1-9 / 1-9 are control
groups, and holding Space shows the routes your regiments are marching.

## Tests

	test.cmd       unit suite, headless, ~1s
	nettest.cmd    two processes: mirror, order validation
	camptest.cmd   two processes: campaign -> battle -> campaign, replay determinism
	aitest.cmd     two AIs play a campaign unattended

## Layout

	sim/     pure game logic, RefCounted only, runs headless
	net/     transport, serialization, order validation
	view/    nodes, rendering, input, cameras
	tests/   headless asserts
	assets/  CC0 / OFL art and fonts

## Optional: Jev

The AI opponent can have its decisions scored by TypeSafe's Jev. Copy `.env.example`
to `.env` and set `TYPESAFE_API_KEY`. Without a key the AI plays its built-in heuristics
and every test still passes.

## More

`CLAUDE.md` has the architecture rules, the combat model and the measurements behind
the tuning.
