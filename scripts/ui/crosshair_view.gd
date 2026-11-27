extends Control
class_name CrosshairView
## Draws a CrosshairProfile centered on this control.

var profile: CrosshairProfile = null
## When true, ignore game visibility rules (always draw for settings preview).
var preview_mode: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if profile == null:
		profile = CrosshairProfile.make_default()


func set_profile(p: CrosshairProfile) -> void:
	profile = p
	queue_redraw()


func _draw() -> void:
	if profile == null:
		return
	var center := size * 0.5
	_draw_element(center, CrosshairProfile.EL_OUTER_CIRCLE)
	_draw_element(center, CrosshairProfile.EL_INNER_CIRCLE)
	_draw_element(center, CrosshairProfile.EL_OUTER_LINES)
	_draw_element(center, CrosshairProfile.EL_INNER_LINES)
	_draw_element(center, CrosshairProfile.EL_DOT)


func _draw_element(center: Vector2, key: String) -> void:
	var e: Dictionary = profile.get_element(key)
	if not bool(e.get("enabled", false)):
		return
	var col: Color = e.get("color", Color.GREEN)
	col.a = clampf(float(e.get("opacity", 1.0)), 0.0, 1.0)
	var outline_on := bool(e.get("outline_enabled", true))
	var ocol: Color = e.get("outline_color", Color.BLACK)
	var othick := maxf(float(e.get("outline_thickness", 1.0)), 0.0)
	var thick := maxf(float(e.get("thickness", 2.0)), 0.5)

	match key:
		CrosshairProfile.EL_DOT:
			var radius := maxf(float(e.get("size", 2.0)), 0.5) * 0.5
			if outline_on and othick > 0.0:
				draw_circle(center, radius + othick, ocol)
			draw_circle(center, radius, col)

		CrosshairProfile.EL_INNER_LINES, CrosshairProfile.EL_OUTER_LINES:
			var length := maxf(float(e.get("length", 6.0)), 0.0)
			var gap := maxf(float(e.get("gap", 3.0)), 0.0)
			if length <= 0.0:
				return
			_draw_cross_lines(center, gap, length, thick, col, outline_on, ocol, othick)

		CrosshairProfile.EL_INNER_CIRCLE, CrosshairProfile.EL_OUTER_CIRCLE:
			var radius := maxf(float(e.get("radius", 20.0)), 0.5)
			if outline_on and othick > 0.0:
				_draw_ring(center, radius, thick + othick * 2.0, ocol)
			_draw_ring(center, radius, thick, col)


func _draw_cross_lines(
	center: Vector2, gap: float, length: float, thick: float,
	col: Color, outline_on: bool, ocol: Color, othick: float
) -> void:
	# Four arms: up, down, left, right
	var arms: Array = [
		[Vector2(0, -1), Vector2(0, -1)],  # up
		[Vector2(0, 1), Vector2(0, 1)],    # down
		[Vector2(-1, 0), Vector2(-1, 0)],  # left
		[Vector2(1, 0), Vector2(1, 0)],    # right
	]
	for arm in arms:
		var dir: Vector2 = arm[0]
		var a := center + dir * gap
		var b := center + dir * (gap + length)
		if outline_on and othick > 0.0:
			draw_line(a, b, ocol, thick + othick * 2.0, true)
		draw_line(a, b, col, thick, true)


func _draw_ring(center: Vector2, radius: float, thickness: float, col: Color) -> void:
	## Stroke-only circle approximated with a polyline.
	var points := 64
	var half_t := thickness * 0.5
	# Draw as thick polyline along the circle
	var pts := PackedVector2Array()
	for i in range(points + 1):
		var ang := TAU * float(i) / float(points)
		pts.append(center + Vector2(cos(ang), sin(ang)) * radius)
	draw_polyline(pts, col, thickness, true)
