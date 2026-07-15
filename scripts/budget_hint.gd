extends Node2D
## The vein budget, without a number on screen.
##
## A row of short strokes along the bottom edge: lit ones are vessels you still
## hold, spent ones are ghosts. This is the only persistent overlay in the game
## and it stays wordless.

const STROKE_W := 3.0
const STROKE_H := 11.0
const GAP := 9.0
const MARGIN_BOTTOM := 26.0


func _draw() -> void:
	var game := get_parent()
	if game == null or not game.has_method("veins_used"):
		return
	var total: int = game.budget
	var used: int = game.veins_used()
	if total <= 0:
		return

	var vp := get_viewport_rect().size
	var span := float(total) * STROKE_W + float(total - 1) * GAP
	var x := (vp.x - span) * 0.5
	var y := vp.y - MARGIN_BOTTOM

	for i in total:
		var spent := i < used
		var col := Palette.VEIN_LIVE if spent else Palette.HEART
		col.a = 0.22 if spent else 0.55
		var h := STROKE_H * (0.6 if spent else 1.0)
		draw_line(Vector2(x, y - h * 0.5), Vector2(x, y + h * 0.5), col, STROKE_W, true)
		x += STROKE_W + GAP
