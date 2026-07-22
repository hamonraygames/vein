class_name Palette
## Warm-on-dark identity palette. Was strictly five colours until PRISM (the
## fourth resource tier, a pentagon/Kiln) needed its own — still one hue per
## shape, still warm, still never the only channel a mechanic depends on.
##
## Shape always encodes meaning; colour is a redundant channel. The game is
## colourblind-safe by construction — never add a mechanic that only colour tells.

const BG := Color("0d0d10")

## One fixed hue per shape, unchanged for a resource's whole life and IDENTICAL
## everywhere it appears — as a node's body, as the demand glyph inside the
## Heart, as a requirement glyph inside a tool, as a dot on a vein, as a
## buffer pip — all routed through of_res() so there is exactly one source of
## truth. Red is deliberately absent from every object: it reads as HAZARD
## (the old "red triangle" confusion), and the only thing allowed to alarm is
## VOID. REFINED was coral e4572e and is now teal-green, well clear of red.
## Muted, not garish. Playtest: "the circles are very bold and dominant, both
## border width and colour; everything except the Heart is not good." The
## Heart's soft ivory is the reference for the whole family — every resource
## is now a DESATURATED tint in that same register (bright saturated amber/
## teal/rose read as loud stickers against the dark, fighting the Heart for
## the eye). Lower saturation, similar softness, so the board reads as one
## quiet organism with the Heart clearly its brightest point.
const RAW := Color("bb9a6b")      # circle   — soft sand-gold (was bright amber)
const REFINED := Color("7ea394")  # triangle — muted sage (was saturated teal)
const CLOTH := Color("b8b09a")    # square   — warm stone (was near-white bone, read as washed-out)
const PRISM := Color("b0879b")    # pentagon — dusty mauve (was hot rose)
const HEART := Color("f5f2ea")    # hexagon  — ivory (kept: the one bright point)

## Corruption. The one COLD colour in a warm-on-dark palette, and the only thing
## on screen that does not belong — a spent Well gone necrotic, and the poison it
## pumps down the vein you built to it.
const VOID := Color("6f5bd6")
const VOID_DIM := Color("2a2145")

## Veins carry the whole read of the board, so they cannot be near-background.
## The first pass had them at #2c262e-#4a3f48 against a #0d0d10 canvas, which
## vanished on a phone in daylight — you could not see your own network.
const VEIN_IDLE := Color("4a4048")
const VEIN_LIVE := Color("9c7a52")
const VEIN_INERT := Color("221e24")
## Engorged and about to burst. Darker and angrier than a live vein, never
## brighter — a straining vessel should read as bruised, not as energised.
const VEIN_STRAINED := Color("6b2230")

const WARM := Color("ffb765")     # the rescue flash


static func of_res(kind: int) -> Color:
	match kind:
		0: return RAW
		1: return REFINED
		2: return CLOTH
		3: return PRISM
		4: return VOID
	return HEART
