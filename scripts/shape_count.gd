extends Node2D
## Live shape-count readout: exactly how many of each family exist on the
## board right now — the same "show the player the finite thing they're
## managing" instinct budget_hint.gd already applies to veins, applied to
## shapes themselves. A shape glyph plus its live count as plain text (e.g.
## a triangle icon next to "×3") — explicit direction, a second deliberate
## exception to VEIN.md's "no HUD numbers" pillar alongside score_hud.gd's
## own score readout.
##
## Only the LIVE count, nothing about a cap/target — a family's row appears
## the instant its first live member actually exists on the board (not when
## the Heart merely starts craving that tier) and disappears if it ever
## drops back to zero. No pushed state: pure poll, same contract as
## budget_hint.gd — _draw() reads game's own live data fresh every redraw.
##
## Wells excluded on purpose — a swarm of up to 20 (see game.gd's
## MAX_LIVE_WELLS) makes a wide, fast-changing number that read as noise
## rather than useful information, not a "how many of this exist" a glance
## could actually use.

const ICON_S := 7.0
## One shared gap reused between EVERY consecutive pair (icon->×, ×->number)
## — drawing "×N" as a single string used to leave the icon->× gap (a fixed
## constant) visibly different from ×->number (just the font's own
## kerning). Three independently-positioned elements, one gap value.
const GAP := 9.0
const FONT_SIZE := 18
## Generous on purpose — a row sitting close to the one above/below it is
## easy to misread as belonging to the wrong family.
const ROW_GAP := 26.0

## Fixed, stable top-to-bottom order — the same ladder VEIN.md and every
## other tier-ordered readout in this codebase already uses. WELL
## deliberately omitted, see the header comment.
const KIND_ORDER: Array[int] = [
	VNode.Kind.FORGE, VNode.Kind.LOOM, VNode.Kind.KILN, VNode.Kind.CRUCIBLE,
]

var _font: Font


func _ready() -> void:
	_font = Palette.MONO_FONT


func _process(_delta: float) -> void:
	# Cheap enough to poll every frame — a handful of small draw calls, same
	# cost class as budget_hint's own always-redrawing row.
	queue_redraw()


func _draw() -> void:
	var game := get_parent()
	if game == null or not game.has_method("veins_used"):
		return

	# Bottom-left corner, stacked upward. The first family to ever have a
	# live member anchors right at the bottom edge margin (same Y baseline
	# budget_hint's own row sits on); each family after it stacks one row
	# higher, so the corner fills upward as the run progresses.
	var vp: Vector2 = game.design_size()
	var x0: float = game.EDGE_MARGIN_X
	var y: float = vp.y - game.EDGE_MARGIN_Y

	for kind in KIND_ORDER:
		var live: int = game._count_healthy_kind(kind)
		if live <= 0:
			continue
		var res := _res_for_kind(kind)
		_draw_row(Vector2(x0, y), res, Palette.of_res(res), live)
		y -= ROW_GAP


## Mirrors game.gd's own Kind->Res table (see _make_node) — kept local
## rather than reaching into game.gd's private mapping, same reasoning
## ghost_spawn.gd's own copy of it uses: a HUD widget has no business
## depending on that.
func _res_for_kind(kind: int) -> int:
	match kind:
		VNode.Kind.FORGE: return VNode.Res.REFINED
		VNode.Kind.LOOM: return VNode.Res.CLOTH
		VNode.Kind.KILN: return VNode.Res.PRISM
		VNode.Kind.CRUCIBLE: return VNode.Res.HEXAGON
	return VNode.Res.RAW


## One family's row: its identifying glyph, "×", and the count — three
## separately-positioned elements sharing one GAP and one baseline, not one
## combined string. Same MONO_FONT score_hud.gd's own readout uses, so the
## text on screen shares one voice.
func _draw_row(at: Vector2, res: int, col: Color, live: int) -> void:
	var icon := col
	icon.a = 0.85
	_draw_icon(at, res, icon)

	var txt_col := col
	txt_col.a = 0.9
	# Baseline that puts the text's own vertical CENTER on `at.y`, matching
	# the icon (already drawn centered on `at`) — get_string_size's height
	# is not the right basis for this (it varies per-string with descenders/
	# capitals), the font's fixed ascent/descent is.
	var ascent := _font.get_ascent(FONT_SIZE)
	var descent := _font.get_descent(FONT_SIZE)
	var baseline_y := at.y + (ascent - descent) * 0.5

	var x := at.x + ICON_S + GAP
	var cross := "×"
	draw_string(_font, Vector2(x, baseline_y), cross, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, txt_col)
	x += _font.get_string_size(cross, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x + GAP

	var num := str(live)
	draw_string(_font, Vector2(x, baseline_y), num, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, txt_col)


## Just the identifying glyph. Reuses VNode.demand_glyph_points (the same
## static, explicitly-reusable helper tutorial.gd and the Heart's own
## demand glyph already draw from) rather than reimplementing shape
## outlines.
func _draw_icon(at: Vector2, res: int, col: Color) -> void:
	var pts := VNode.demand_glyph_points(res, ICON_S)
	if pts.is_empty():
		draw_arc(at, ICON_S * VNode.DEMAND_GLYPH_CIRCLE_RATIO, 0.0, TAU, 22, col, 2.0, true)
		return
	var shifted := PackedVector2Array()
	for p in pts:
		shifted.append(p + at)
	draw_polyline(shifted, col, 2.0, true)
