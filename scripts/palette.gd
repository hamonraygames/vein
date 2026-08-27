class_name Palette
## Warm-on-dark identity palette. Was strictly five colours until PRISM (the
## fourth resource tier, a pentagon/Kiln) needed its own — still one hue per
## shape, still warm, still never the only channel a mechanic depends on.
##
## Shape always encodes meaning; colour is a redundant channel. The game is
## colourblind-safe by construction — never add a mechanic that only colour tells.

const BG := Color("0d0d10")

## Monospace everywhere, by explicit direction — one shared font resource for
## every custom-drawn readout (score_hud.gd, leaderboard_panel.gd,
## ranks_strip.gd, float_text.gd all draw_string against this instead of
## ThemeDB.fallback_font) so they match the project-wide Theme set in
## project.godot's gui/theme/custom, which every Label/Button already
## inherits automatically. Space Mono, SIL OFL 1.1 — see assets/CREDITS.md.
const MONO_FONT := preload("res://assets/fonts/SpaceMono-Regular.ttf")

## One fixed hue per shape, unchanged for a resource's whole life and IDENTICAL
## everywhere it appears — as a node's body, as the demand glyph inside the
## Heart, as a requirement glyph inside a tool, as a dot on a vein, as a
## buffer pip — all routed through of_res() so there is exactly one source of
## truth. Red used to be deliberately absent from every object (it read as
## HAZARD, the old "red triangle" confusion, and the only thing allowed to
## alarm was VOID) — reversed per explicit direction: the Heart is now a red
## heart, on purpose, the one object allowed to own the color everything
## else still avoids. REFINED was coral e4572e and is now teal-green, well
## clear of red. Everything but the Heart stays muted, not garish. Playtest:
## "the circles are very bold and dominant, both border width and colour;
## everything except the Heart is not good." Every resource is a DESATURATED
## tint in a soft register (bright saturated amber/teal/rose read as loud
## stickers against the dark, fighting the Heart for the eye) — the Heart's
## red is the one deliberate exception, brighter and warmer than the family
## on purpose, so the board still reads as one quiet organism with the Heart
## clearly its brightest, most alive point.
const RAW := Color("bb9a6b")      # circle   — soft sand-gold (was bright amber)
const REFINED := Color("7ea394")  # triangle — muted sage (was saturated teal)
const CLOTH := Color("b8b09a")    # square   — warm stone (was near-white bone, read as washed-out)
const PRISM := Color("b0879b")    # pentagon — dusty mauve (was hot rose)
const HEART := Color("e6483f")    # heart    — a real red (was ivory f5f2ea, was hexagon-shaped)
## The fifth resource, deepest of the ladder — VEIN.md always promised it
## ("the Heart demands hexagons, which only a rare Crucible can make").
## Continues the same soft/desaturated register as RAW..PRISM, one step
## further: a cool, quiet slate — the family's coldest member short of VOID,
## fitting for the rarest, hardest-won tier.
const HEXAGON := Color("8f97a8")  # hexagon  — pale slate

## Corruption. The one COLD colour in a warm-on-dark palette, and the only thing
## on screen that does not belong — a spent Well gone necrotic, and the poison it
## pumps down the vein you built to it.
const VOID := Color("6f5bd6")
const VOID_DIM := Color("2a2145")

## A raging node (corrupted AND orphaned — actively attacking its remaining
## neighbours, see game.gd's _tick_corruption/_start_poison_dart), and any
## neighbour it just turned. Deliberately the Heart's own red rather than a
## new hue — red was reserved for the Heart alone specifically because it
## reads as danger/alarm, and a raging node IS that same alarm: not a
## passive corpse anymore, an active attacker. Shape still tells the Heart
## apart from everything else, so "shape always encodes meaning" still
## holds even with two red things on screen.
const RAGE := HEART

## Veins carry the whole read of the board, so they cannot be near-background.
## The first pass had them at #2c262e-#4a3f48 against a #0d0d10 canvas, which
## vanished on a phone in daylight — you could not see your own network.
const VEIN_IDLE := Color("4a4048")
const VEIN_LIVE := Color("9c7a52")
## A vein that connects nothing to nothing. It was #221e24 — three shades off
## the #0d0d10 background, i.e. the exact "vanishes on a phone in daylight"
## failure the two colours above exist to avoid, and it landed on the worst
## case: playtest reported that connecting two shapes not yet reachable from
## the Heart draws a line you cannot see. Now a plain line like every other
## vein, just the dimmest of them: it sits below VEIN_IDLE so "this does
## nothing" still reads at a glance, but well clear of the background so the
## connection the player just made is always there to see. (A dashed stroke
## was tried for that second job and rejected — a broken line among solid
## ones read as a rendering fault, not as a dead vein.)
const VEIN_INERT := Color("3f3746")
## Engorged and about to burst. Darker and angrier than a live vein, never
## brighter — a straining vessel should read as bruised, not as energised.
const VEIN_STRAINED := Color("6b2230")

const WARM := Color("ffb765")     # the rescue flash

## Score readout (the "+x" delivery pop and the running total) — deliberately
## NOT Palette.HEART. Real feedback: red on the score reads as danger/damage,
## the opposite of what a gain should feel like, now that the Heart itself
## owns red as its identity color. A near-white keeps score legible and
## clearly its own channel, not a second meaning piggybacking on the Heart's.
const SCORE := Color("ede8dc")

## Leaderboard rank-change chevrons (see leaderboard_panel.gd/ranks_strip.gd)
## — a deliberate, one-off exception to "shape always encodes meaning,
## colour is redundant" above: this is a meta UI indicator about the
## LEADERBOARD, not a resource on the board, so plain up-good/down-bad
## green/red is the clearer, more universally legible choice here than
## inventing a third channel.
const RANK_UP := Color("6fcf7a")
const RANK_DOWN := Color("e0555a")

## The #1 leaderboard crown (see leaderboard_panel.gd's row and vnode.gd's
## Heart, which wears the same one) — another deliberate exception like
## RANK_UP/DOWN above: this is a meta "you're first" badge, not a resource
## on the board, so it's exempt from "every resource stays desaturated" and
## gets to read as an actual gold.
const GOLD := Color("f0c14b")


static func of_res(kind: int) -> Color:
	match kind:
		0: return RAW
		1: return REFINED
		2: return CLOTH
		3: return PRISM
		4: return VOID
		5: return HEXAGON
		6: return SCORE
	return HEART
