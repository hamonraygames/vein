extends Node2D
## The vein budget: how many more veins you may draw.
##
## A row of strokes along the bottom edge — lit ones are vessels you still hold,
## spent ones are ghosts. It stays wordless, but it is not allowed to be subtle:
## budget is the resource every decision in the game spends, and at 3px wide and
## 22% alpha it was invisible on a phone. Lit strokes now read at a glance, and
## the row flashes when you have nothing left, because "I cannot afford this" is
## the single most important thing the board can tell you mid-drag.

const STROKE_W := 5.0
const STROKE_H := 16.0
const GAP := 8.0
const MARGIN_BOTTOM := 30.0


func _process(_delta: float) -> void:
	# Cheap: only redraws while the empty-budget pulse needs animating.
	var game := get_parent()
	if game != null and game.has_method("veins_used") and game.veins_used() >= game.budget:
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
		draw_line(Vector2(x, y - h * 0.5), Vector2(x, y + h * 0.5), col, STROKE_W, true)
		x += STROKE_W + GAP
