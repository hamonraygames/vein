extends Node2D
## The vein budget: how many more veins you may draw — the "line inventory".
##
## A row of strokes along the bottom edge — lit ones are vessels you still hold,
## spent ones are ghosts. It stays wordless, but it is not allowed to be subtle:
## budget is the resource every decision in the game spends, and at 3px wide and
## 22% alpha it was invisible on a phone. Lit strokes now read at a glance, and
## the row flashes when you have nothing left, because "I cannot afford this" is
## the single most important thing the board can tell you mid-drag.
##
## It also FLASHES on every spend and every refund (see flash(), called from
## game.gd's _add_vein/_remove_vein). Playtest: first-timers didn't realise
## veins were a limited resource at all — pulsing the whole row the instant one
## is used or a cut gives one back draws the eye straight to the inventory and
## teaches "these are finite" without a word.

const STROKE_W := 5.0
const STROKE_H := 16.0
const GAP := 8.0
const MARGIN_BOTTOM := 30.0

var _flash := 0.0
## The stroke index that just changed, so the flash can pop that one hardest
## (the vein you just spent, or the slot a cut just handed back). -1 = none.
var _flash_i := -1


## Pulse the inventory. `at_index` is the slot that changed (draw or refund),
## which glows brightest; the whole row lifts too.
func flash(at_index: int = -1) -> void:
	_flash = 1.0
	_flash_i = at_index
	queue_redraw()


func _process(delta: float) -> void:
	var game := get_parent()
	var tapped_out: bool = game != null and game.has_method("veins_used") \
		and game.veins_used() >= game.budget
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 2.6)
		queue_redraw()
	elif tapped_out:
		# Keep animating the empty-budget throb.
		queue_redraw()


func _draw() -> void:
	var game := get_parent()
	if game == null or not game.has_method("veins_used"):
		return
	var total: int = game.budget
	var used: int = game.veins_used()
	if total <= 0:
		return

	var vp: Vector2 = game.design_size()
	var span := float(total) * STROKE_W + float(total - 1) * GAP
	var x := (vp.x - span) * 0.5
	var y := vp.y - MARGIN_BOTTOM

	var tapped_out := used >= total
	var throb := 0.0
	if tapped_out:
		throb = 0.5 + 0.5 * sin(float(Time.get_ticks_msec()) * 0.005)

	# The whole row lifts and brightens on a spend/refund.
	var lift := _flash * 4.0

	for i in total:
		var spent := i < used
		var col: Color
		var h := STROKE_H
		if spent:
			col = Palette.VEIN_STRAINED if tapped_out else Palette.VEIN_IDLE
			col.a = 0.30 + throb * 0.35
			h *= 0.7
		else:
			col = Palette.HEART
			col.a = 0.9
		# The just-changed slot pops hardest; every slot shares the row-wide
		# lift so the flash reads as one event, not a single flickering tick.
		var pop := _flash * (0.6 if i == _flash_i else 0.25)
		col = col.lerp(Palette.WARM, pop)
		col.a = clampf(col.a + pop * 0.4, 0.0, 1.0)
		var hh := h + _flash * (7.0 if i == _flash_i else 3.0)
		draw_line(Vector2(x, y - hh * 0.5 - lift), Vector2(x, y + hh * 0.5 - lift),
			col, STROKE_W, true)
		x += STROKE_W + GAP
