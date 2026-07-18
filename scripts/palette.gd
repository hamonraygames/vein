class_name Palette
## Warm-on-dark identity palette. Was strictly five colours until PRISM (the
## fourth resource tier, a pentagon/Kiln) needed its own — still one hue per
## shape, still warm, still never the only channel a mechanic depends on.
##
## Shape always encodes meaning; colour is a redundant channel. The game is
## colourblind-safe by construction — never add a mechanic that only colour tells.

const BG := Color("0d0d10")

const RAW := Color("e8a33d")      # circle   — amber
const REFINED := Color("e4572e")  # triangle — coral
const CLOTH := Color("e8e3d3")    # square   — bone
const PRISM := Color("c2547a")    # pentagon — warm rose
const HEART := Color("f5f2ea")    # hexagon  — white

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
## Three booster families, three colours — feedback: "color code the
## different types of boosters, one time and persistent." BOOST (gold) is a
## ONE_OFF instant grab. RELIC (burnt orange) is a TIME_BASED perk — strong,
## temporary. PERSISTENT (jade) is a run-long perk — permanent, one slot,
## replaced rather than stacked. PERSISTENT and RELIC used to share this same
## burnt-orange hue (reasoned at the time as "both outlive a single grab"),
## which meant the one visual cue meant to separate "temporary" from
## "permanent" didn't actually cover the two families that most need telling
## apart, since both spawn as forks and both use the same effect pool.
## Shape still carries the real distinction (star vs hexagram vs diamond, and
## which inner glyph) — colour is the redundant, at-a-glance channel, per the
## rule above.
const BOOST := WARM
const RELIC := Color("d97b3d")
const PERSISTENT := Color("5aab6e")


static func of_res(kind: int) -> Color:
	match kind:
		0: return RAW
		1: return REFINED
		2: return CLOTH
		3: return PRISM
		4: return VOID
	return HEART
