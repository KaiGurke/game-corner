extends CanvasLayer
## Top-right kill feed. Panel/fonts match the Tab scoreboard; entry colours stay as configured.

@export var max_entries: int = 6
@export var entry_lifetime: float = 5.0
@export var fade_time: float = 1.0
@export var font_size: int = 20
## Kept as-is (not scoreboard palette).
@export var name_color: Color = Color(0.55, 0.85, 1.0)
@export var weapon_color: Color = Color(0.85, 0.85, 0.9)
@export var fall_color: Color = Color(1.0, 0.55, 0.35)
## Scoreboard-matched panel (Tab player list blue).
@export var panel_color: Color = Color(0.235, 0.235, 0.67, 0.878)

var _list: VBoxContainer
var _entries: Array = []  # {row: Control, age: float}
var font_regular = _load_font("res://assets/fonts/HomeVideo-Regular.ttf")
var font_bold = _load_font("res://assets/fonts/HomeVideo-Bold.ttf")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 55
	_build_ui()


func _load_font(path: String):
	var path_lower := path.to_lower()
	var font_file := FontFile.new()
	if path_lower.ends_with(".ttf") or path_lower.ends_with(".otf"):
		font_file.load_dynamic_font(path)
		return font_file
	push_error("Invalid font file format: %s" % path)
	return null


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_list = VBoxContainer.new()
	_list.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_list.anchor_left = 1.0
	_list.anchor_right = 1.0
	_list.anchor_top = 0.0
	_list.anchor_bottom = 0.0
	_list.offset_left = -420.0
	_list.offset_right = -16.0
	_list.offset_top = 16.0
	_list.offset_bottom = 320.0
	_list.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_list.alignment = BoxContainer.ALIGNMENT_BEGIN
	_list.add_theme_constant_override("separation", 6)
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_list)


func _process(delta: float) -> void:
	if _entries.is_empty():
		return
	var to_remove: Array = []
	for i in range(_entries.size()):
		var e: Dictionary = _entries[i]
		e.age = float(e.age) + delta
		var age: float = float(e.age)
		var row: Control = e.row
		if not is_instance_valid(row):
			to_remove.append(i)
			continue
		if age >= entry_lifetime:
			var fade_t := (age - entry_lifetime) / maxf(fade_time, 0.01)
			row.modulate.a = clampf(1.0 - fade_t, 0.0, 1.0)
			if fade_t >= 1.0:
				to_remove.append(i)
	# Remove from end so indices stay valid
	to_remove.reverse()
	for idx in to_remove:
		var e2: Dictionary = _entries[idx]
		if is_instance_valid(e2.row):
			e2.row.queue_free()
		_entries.remove_at(idx)


func add_kill(attacker: String, victim: String, weapon: String = "") -> void:
	var text := ""
	if weapon.is_empty():
		text = "[color=#%s]%s[/color]  killed  [color=#%s]%s[/color]" % [
			name_color.to_html(false), attacker,
			name_color.to_html(false), victim,
		]
	else:
		text = "[color=#%s]%s[/color]  [color=#%s][%s][/color]  [color=#%s]%s[/color]" % [
			name_color.to_html(false), attacker,
			weapon_color.to_html(false), weapon,
			name_color.to_html(false), victim,
		]
	_push_entry(text)


func add_fall(victim: String) -> void:
	var text := "[color=#%s]%s[/color]  [color=#%s]fell to their death[/color]" % [
		name_color.to_html(false), victim,
		fall_color.to_html(false),
	]
	_push_entry(text)


func add_death(victim: String) -> void:
	var text := "[color=#%s]%s[/color]  died" % [name_color.to_html(false), victim]
	_push_entry(text)


func _push_entry(bbcode: String) -> void:
	while _entries.size() >= max_entries:
		var old: Dictionary = _entries.pop_front()
		if is_instance_valid(old.row):
			old.row.queue_free()

	var row := PanelContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Match Tab scoreboard panel: same blue, radius, margins.
	var style := StyleBoxFlat.new()
	style.bg_color = panel_color
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	row.add_theme_stylebox_override("panel", style)

	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("normal_font_size", font_size)
	if font_regular:
		label.add_theme_font_override("normal_font", font_regular)
	if font_bold:
		label.add_theme_font_override("bold_font", font_bold)
	label.text = bbcode
	row.add_child(label)

	_list.add_child(row)
	_entries.append({"row": row, "age": 0.0})
