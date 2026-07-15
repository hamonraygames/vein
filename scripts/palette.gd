class_name Palette
## Strict five-colour palette, warm-on-dark.
##
## Shape always encodes meaning; colour is a redundant channel. The game is
## colourblind-safe by construction — never add a mechanic that only colour tells.

const BG := Color("0d0d10")

const RAW := Color("e8a33d")      # circle  — amber
const REFINED := Color("e4572e")  # triangle — coral
const CLOTH := Color("e8e3d3")    # square  — bone
const HEART := Color("f5f2ea")    # hexagon — white

const VEIN_IDLE := Color("2c262e")
const VEIN_LIVE := Color("4a3f48")
const VEIN_INERT := Color("1c191d")
## Engorged and about to burst. Darker and angrier than a live vein, never
## brighter — a straining vessel should read as bruised, not as energised.
const VEIN_STRAINED := Color("6b2230")

const WARM := Color("ffb765")     # the rescue flash


static func of_res(kind: int) -> Color:
	match kind:
		0: return RAW
		1: return REFINED
		2: return CLOTH
	return HEART
