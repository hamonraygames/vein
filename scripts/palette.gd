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
const BOOST := WARM               # instant one-shot pickups (SURGE/CLEANSE)
## A Relic is a persistent, ongoing trade-off — a genuinely different kind of
## "good thing happening" than an instant Boost grab, so it earns its own hue
## rather than sharing WARM: burnt orange, still warm, still clearly distinct
## at a glance (colour-blind-safe pairing relies on RELIC's hexagram
## silhouette too, not the colour alone).
const RELIC := Color("d97b3d")


static func of_res(kind: int) -> Color:
	match kind:
		0: return RAW
		1: return REFINED
		2: return CLOTH
		3: return PRISM
		4: return VOID
	return HEART
