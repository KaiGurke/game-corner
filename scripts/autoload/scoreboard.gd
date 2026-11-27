extends CanvasLayer
## Tab scoreboard: name (host), K/D/A, ping. Hold Tab to show.

const NAME_COL_WIDTH := 260.0
const STAT_COL_WIDTH := 50.0
const PING_COL_WIDTH := 90.0

var _list: VBoxContainer
var _title: Label
var _panel: PanelContainer

var font_bold = _load_font("res://assets/fonts/HomeVideo-Bold.ttf")
var font_regular = _load_font("res://assets/fonts/HomeVideo-Regular.ttf")

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 50
	_build_ui()
	visible = false

func _load_font(path: String):
	var path_lower = path.to_lower()
	var font_file = FontFile.new()
	if path_lower.ends_with(".ttf") or path_lower.ends_with(".otf"):
		font_file.load_dynamic_font(path)
		return font_file
	else:
		push_error("Invalid font file format.")

func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -420
	_panel.offset_right = 420
	_panel.offset_top = -300
	_panel.offset_bottom = 300
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.235, 0.235, 0.67, 0.878)
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	style.content_margin_left = 20
	style.content_margin_right = 20
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	_panel.add_theme_stylebox_override("panel", style)
	root.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_panel.add_child(vbox)

	_title = Label.new()
	_title.text = "Game | Gamemode | Map"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 40)
	_title.add_theme_font_override("font", font_bold)
	#_title.add_theme_font_override("font", "res://assets/fonts/HomeVideo-Bold.ttf")
	vbox.add_child(_title)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	vbox.add_child(header)
	_name_col(header, "Name", true)
	_col(header, "K", STAT_COL_WIDTH, true, 20)
	_col(header, "D", STAT_COL_WIDTH, true, 20)
	_col(header, "A", STAT_COL_WIDTH, true, 20)
	_col(header, "Ping", PING_COL_WIDTH, true, 20)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	vbox.add_child(_list)


## Fixed-width name column so long usernames clip with ellipsis and never shift K/D/A/Ping.
func _name_col(parent: HBoxContainer, text: String, is_header: bool, host_color: bool = false) -> void:
	# Outer Control owns the fixed width so the HBox never grows with long names.
	var cell := Control.new()
	cell.custom_minimum_size = Vector2(NAME_COL_WIDTH, 0)
	cell.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	cell.clip_contents = true
	parent.add_child(cell)

	var l := Label.new()
	l.text = text
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.add_theme_font_size_override("font_size", 20)
	l.add_theme_font_override("font", font_bold if is_header else font_regular)
	if host_color:
		l.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	cell.add_child(l)

	# Let the label's content height drive the row; width stays locked to NAME_COL_WIDTH.
	var text_h := l.get_minimum_size().y
	if text_h > 0.0:
		cell.custom_minimum_size.y = text_h


func _col(parent: HBoxContainer, text: String, width: float, right: bool, font_size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(width, 0)
	l.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_font_override("font", font_bold)
	if right:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	parent.add_child(l)
	return l


func _unhandled_input(event: InputEvent) -> void:
	if not _can_show():
		if visible:
			visible = false
		return
	if event.is_action_pressed("scoreboard"):
		visible = true
		_refresh()
		get_viewport().set_input_as_handled()
	elif event.is_action_released("scoreboard"):
		visible = false
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if visible:
		_refresh()


func _can_show() -> bool:
	if NetworkManager == null:
		return false
	return NetworkManager.is_online() or NetworkManager.is_in_game


func _refresh() -> void:
	if _list == null or NetworkManager == null:
		return
	if _title:
		_title.text = NetworkManager.get_scoreboard_title()
	for c in _list.get_children():
		c.queue_free()
	for row in NetworkManager.get_scoreboard_rows():
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)

		var base_name := str(row.get("name", "?"))
		var is_host := bool(row.get("is_host", false))
		var display_name := ("%s (host)" % base_name) if is_host else base_name
		_name_col(h, display_name, false, is_host)

		_stat_label(h, int(row.get("kills", 0)), STAT_COL_WIDTH)
		_stat_label(h, int(row.get("deaths", 0)), STAT_COL_WIDTH)
		_stat_label(h, int(row.get("assists", 0)), STAT_COL_WIDTH)

		var ping_l := Label.new()
		var ping: int = int(row.get("ping", -1))
		ping_l.text = "—" if ping < 0 else "%d ms" % ping
		ping_l.custom_minimum_size = Vector2(PING_COL_WIDTH, 0)
		ping_l.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		ping_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		ping_l.add_theme_font_size_override("font_size", 20)
		ping_l.add_theme_font_override("font", font_regular)
		h.add_child(ping_l)

		_list.add_child(h)


func _stat_label(parent: HBoxContainer, value: int, width: float) -> void:
	var l := Label.new()
	l.text = str(value)
	l.custom_minimum_size = Vector2(width, 0)
	l.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.add_theme_font_size_override("font_size", 20)
	l.add_theme_font_override("font", font_regular)
	parent.add_child(l)
