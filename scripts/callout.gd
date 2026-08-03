extends Node
## Fun, loud, deliberately NOT diegetic milestone reactions — a big on-screen
## text pop for a combo streak, a score milestone, a narrow escape, or a new
## personal best. Autoload so any part of game.gd can fire one without
## threading a reference through.
##
## These were text + a spoken voice line, paired so the two could never
## mismatch. The voice half is gone entirely ("get rid of all text sounds,
## they're annoying, just keep the text"), which collapses each pool from
## {text, voice} dictionaries to plain strings and takes the pairing problem
## with it.
##
## Picking WHETHER a category-crossing moment fires at all is also
## randomised (see FIRE_CHANCE) — a callout on every single threshold, every
## single run, reads as a slot machine ticking over, not a reaction.

const CalloutBannerScene := preload("res://scripts/callout_banner.gd")

## Text only. Every entry used to carry a "voice" key naming a spoken clip
## played alongside the banner; those are gone — "get rid of all text sounds,
## they're annoying, just keep the text" — along with the whole voice pool in
## audio.gd that served them.
const POOLS := {
	"combo": {
		"entries": ["POWER UP", "ON FIRE", "UNSTOPPABLE"],
		"color": "score",
	},
	"milestone": {
		"entries": ["LEVEL UP", "KEEP GOING", "FEED IT"],
		"color": "score",
	},
	"rescue": {
		"entries": ["THAT WAS CLOSE", "SAVED", "PHEW"],
		"color": "warm",
	},
	"best": {
		"entries": ["NEW HIGH SCORE"],
		"color": "warm",
	},
}

## A callout firing right on top of the last one reads as noisy rather than
## as a reaction to something that just happened. Widened from the original
## 3.0/0.55 after playtest feedback that it fired far too often — these are
## meant to feel rare and earned, not a running commentary.
const MIN_GAP := 7.0
## Not every crossed threshold fires (see the file comment) — combo/milestone
## pass through this roll; rescue/best are rare enough on their own that
## gating them further would just make them feel like they should have
## fired and silently didn't (see fire()'s `force` argument).
const FIRE_CHANCE := 0.3

var _rng := RandomNumberGenerator.new()
var _last_at := -INF
var _last_text := {}


func _ready() -> void:
	_rng.randomize()


## `layer` is where the banner gets added (a Node2D already in the tree —
## game.gd's vein_layer for every call site so far) and `at` is where it's
## centered, in that layer's local space. `force` skips the FIRE_CHANCE roll.
func fire(category: String, layer: Node2D, at: Vector2, force := false) -> void:
	if not POOLS.has(category) or layer == null:
		return
	var now := Time.get_ticks_msec() * 0.001
	if now - _last_at < MIN_GAP:
		return
	if not force and _rng.randf() > FIRE_CHANCE:
		return
	_last_at = now

	var pool: Dictionary = POOLS[category]
	var text: String = _pick(category, pool["entries"])
	var col: Color = Palette.WARM if pool.get("color", "") == "warm" else Palette.SCORE

	var banner: Node2D = CalloutBannerScene.new()
	layer.add_child(banner)
	banner.spawn(text, at, col)


## Rerolls once on an immediate repeat rather than tracking full history —
## each pool is small enough that one reroll all but rules out showing the
## same entry twice back to back.
func _pick(category: String, options: Array) -> String:
	if options.size() <= 1:
		return options[0]
	var choice: String = options[_rng.randi() % options.size()]
	if choice == _last_text.get(category, ""):
		choice = options[_rng.randi() % options.size()]
	_last_text[category] = choice
	return choice
