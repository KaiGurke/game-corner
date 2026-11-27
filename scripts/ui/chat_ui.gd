extends CanvasLayer
## Chat UI with two separate layers:
##   1) History (MessageScroll) — full log while the box is OPEN (scrollable)
##   2) Live (LiveList) — only newly sent/received lines while CLOSED
## Live messages stack from the bottom and grow upward so image embeds are not
## clipped at the bottom. They are never height-trimmed; each fades out on its own.

signal message_submitted(text: String)
signal input_opened
signal input_closed

@export_group("Layout")
@export var panel_anchor_left: float = 0.0
@export var panel_anchor_top: float = 0.38
@export var panel_anchor_right: float = 0.42
@export var panel_anchor_bottom: float = 0.82
@export var panel_margin: int = 12
@export var max_messages: int = 80
@export var message_hold_seconds: float = 6.0
@export var message_fade_seconds: float = 2.5
@export var max_image_height: float = 180.0

@export_group("Colors")
@export var panel_color: Color = Color(0.05, 0.05, 0.08, 0.55)
@export var input_bg_color: Color = Color(0.08, 0.08, 0.12, 0.85)
@export var text_color: Color = Color(0.92, 0.92, 0.95, 1.0)
@export var name_color: Color = Color(0.45, 0.85, 1.0, 1.0)
@export var system_color: Color = Color(1.0, 0.85, 0.35, 1.0)
@export var font_size: int = 18

@onready var root_panel: PanelContainer = $Root
@onready var vbox: VBoxContainer = $Root/VBox
@onready var _message_area: Control = $Root/VBox/MessageArea
@onready var _scroll: ScrollContainer = $Root/VBox/MessageArea/MessageScroll
@onready var _message_list: VBoxContainer = $Root/VBox/MessageArea/MessageScroll/MessageList
@onready var _live_layer: Control = $Root/VBox/MessageArea/LiveLayer
@onready var _live_list: VBoxContainer = $Root/VBox/MessageArea/LiveLayer/LiveList
@onready var input_row: HBoxContainer = $Root/VBox/InputRow
@onready var line_edit: LineEdit = $Root/VBox/InputRow/LineEdit
@onready var send_button: Button = $Root/VBox/InputRow/SendButton

## Live-layer entries only: { row, age, sender, text, system }
var _live_entries: Array = []
var _input_active: bool = false
var _font: Font = null
var _emoji_registry: ChatEmojiRegistry = ChatEmojiRegistry.new()
var _image_loader: ChatImageLoader = null
var _emoji_btn: Button = null
var _emoji_popup: PopupPanel = null
var _url_re: RegEx = null
var _emoji_re: RegEx = null
## Mid-fade lives saved across open: { sender, text, system, age }
var _live_fades: Array = []
## Messages that arrived while the box was open (typed/received, not history rebuild)
var _session_new: Array = []
var _rebuilding_history: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 1
	_font = _load_font("res://assets/fonts/HomeVideo-Regular.ttf")
	_url_re = RegEx.new()
	_url_re.compile("\"(https?://[^\"]+)\"")
	_emoji_re = RegEx.new()
	_emoji_re.compile(":([A-Za-z0-9_]+):")

	_image_loader = ChatImageLoader.new()
	_image_loader.name = "ChatImageLoader"
	add_child(_image_loader)
	_image_loader.image_ready.connect(_on_image_ready)
	_image_loader.image_failed.connect(_on_image_failed)

	# Ensure live layer exists even if scene is older
	if _live_layer == null and _message_area:
		_live_layer = _message_area.get_node_or_null("LiveLayer") as Control
	if _live_list == null and _live_layer:
		_live_list = _live_layer.get_node_or_null("LiveList") as VBoxContainer
	if _live_layer == null and _message_area:
		_live_layer = Control.new()
		_live_layer.name = "LiveLayer"
		_live_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_live_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_message_area.add_child(_live_layer)
	if _live_list == null and _live_layer:
		_live_list = VBoxContainer.new()
		_live_list.name = "LiveList"
		_live_list.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		_live_list.anchor_top = 1.0
		_live_list.anchor_bottom = 1.0
		_live_list.grow_vertical = Control.GROW_DIRECTION_BEGIN
		_live_list.alignment = BoxContainer.ALIGNMENT_END
		_live_list.add_theme_constant_override("separation", 4)
		_live_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_live_layer.add_child(_live_list)

	if _message_list:
		_message_list.alignment = BoxContainer.ALIGNMENT_END
		_message_list.add_theme_constant_override("separation", 4)
	if _live_list:
		_live_list.alignment = BoxContainer.ALIGNMENT_END
		_live_list.add_theme_constant_override("separation", 4)
		_live_list.grow_vertical = Control.GROW_DIRECTION_BEGIN
	if _message_area:
		_message_area.clip_contents = true
	if _scroll:
		_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	_emoji_registry.ensure_scanned()
	_setup_emoji_button()
	_apply_appearance()
	if input_row:
		input_row.visible = true
	_set_input_row_shown(false)
	_set_layer_mode(false)
	if line_edit:
		line_edit.text_submitted.connect(_on_text_submitted)
		line_edit.max_length = 500
	if send_button:
		send_button.pressed.connect(_on_send_pressed)
	_set_interactive(false)
	_set_background_visible(false)


func _load_font(path: String) -> Font:
	var path_lower := path.to_lower()
	if not (path_lower.ends_with(".ttf") or path_lower.ends_with(".otf")):
		return null
	var font_file := FontFile.new()
	font_file.load_dynamic_font(path)
	return font_file


func _setup_emoji_button() -> void:
	if input_row == null:
		return
	_emoji_btn = input_row.get_node_or_null("EmojiButton") as Button
	if _emoji_btn == null:
		_emoji_btn = Button.new()
		_emoji_btn.name = "EmojiButton"
		_emoji_btn.text = ":)"
		_emoji_btn.tooltip_text = "Emojis"
		_emoji_btn.custom_minimum_size = Vector2(36, 0)
		input_row.add_child(_emoji_btn)
		if send_button and send_button.get_parent() == input_row:
			input_row.move_child(_emoji_btn, send_button.get_index())
	_emoji_btn.pressed.connect(_on_emoji_button_pressed)
	if _font:
		_emoji_btn.add_theme_font_override("font", _font)
	_emoji_btn.add_theme_font_size_override("font_size", font_size)

	_emoji_popup = PopupPanel.new()
	_emoji_popup.name = "EmojiPopup"
	add_child(_emoji_popup)
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_emoji_popup.add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.name = "EmojiScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(scroll)
	var grid := GridContainer.new()
	grid.name = "EmojiGrid"
	grid.columns = 8
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	scroll.add_child(grid)
	_rebuild_emoji_grid(grid)


func _rebuild_emoji_grid(grid: GridContainer) -> void:
	for c in grid.get_children():
		c.queue_free()
	var entries: Array = _emoji_registry.all_entries()
	if entries.is_empty():
		var empty := Label.new()
		empty.text = "No emojis in\nassets/textures/emojis"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		if _font:
			empty.add_theme_font_override("font", _font)
		empty.add_theme_font_size_override("font_size", 14)
		grid.columns = 1
		grid.add_child(empty)
		return
	grid.columns = 6
	var cell := maxi(font_size + 8, 28)
	for e in entries:
		var b := Button.new()
		b.custom_minimum_size = Vector2(cell, cell)
		b.tooltip_text = ":%s:" % e.name
		b.flat = true
		var tex: Texture2D = e.texture
		if tex:
			b.icon = tex
			b.expand_icon = true
		else:
			b.text = e.name
		b.pressed.connect(_on_emoji_picked.bind(str(e.name)))
		grid.add_child(b)


func _on_emoji_button_pressed() -> void:
	if _emoji_popup == null or _emoji_btn == null:
		return
	var grid := _emoji_popup.find_child("EmojiGrid", true, false) as GridContainer
	if grid:
		_rebuild_emoji_grid(grid)

	# Match chat panel width; open ABOVE the emoji button.
	var panel_w := 280
	if root_panel:
		panel_w = maxi(int(root_panel.size.x), 200)
	var popup_h := 220
	var btn_rect := _emoji_btn.get_global_rect()
	var x := int(root_panel.get_global_rect().position.x) if root_panel else int(btn_rect.position.x)
	var y := int(btn_rect.position.y) - popup_h - 4
	if y < 0:
		y = 0

	var scroll := _emoji_popup.find_child("EmojiScroll", true, false) as ScrollContainer
	if scroll:
		scroll.custom_minimum_size = Vector2(panel_w - 24, popup_h - 24)

	_emoji_popup.popup(Rect2i(x, y, panel_w, popup_h))


func _on_emoji_picked(emoji_name: String) -> void:
	if line_edit == null:
		return
	var token := ":%s:" % emoji_name
	var caret := line_edit.caret_column
	var t := line_edit.text
	line_edit.text = t.substr(0, caret) + token + t.substr(caret)
	line_edit.caret_column = caret + token.length()
	line_edit.grab_focus()
	if _emoji_popup:
		_emoji_popup.hide()


# ---------------------------------------------------------------------------
# Layer mode: history (open) vs live (closed)
# ---------------------------------------------------------------------------

func _set_layer_mode(open: bool) -> void:
	if _scroll:
		_scroll.visible = open
		_scroll.vertical_scroll_mode = (
			ScrollContainer.SCROLL_MODE_AUTO if open else ScrollContainer.SCROLL_MODE_DISABLED
		)
	if _live_layer:
		_live_layer.visible = not open


func _fade_lifetime() -> float:
	return message_hold_seconds + message_fade_seconds


func _process(delta: float) -> void:
	if _input_active or _live_entries.is_empty():
		return

	var to_remove: Array = []
	for i in range(_live_entries.size()):
		var e: Dictionary = _live_entries[i]
		var row: Control = e.get("row")
		if not is_instance_valid(row):
			to_remove.append(i)
			continue
		if not row.visible:
			continue  # waiting on image embed
		var age: float = float(e.get("age", 0.0)) + delta
		_live_entries[i]["age"] = age
		if age <= message_hold_seconds:
			row.modulate.a = 1.0
		else:
			var fade_t := (age - message_hold_seconds) / maxf(message_fade_seconds, 0.01)
			row.modulate.a = clampf(1.0 - fade_t, 0.0, 1.0)
			if fade_t >= 1.0:
				to_remove.append(i)

	to_remove.reverse()
	for idx in to_remove:
		var e2: Dictionary = _live_entries[idx]
		if is_instance_valid(e2.get("row")):
			e2.row.queue_free()
		_live_entries.remove_at(idx)


# ---------------------------------------------------------------------------
# Appearance / input chrome
# ---------------------------------------------------------------------------

func _apply_appearance() -> void:
	if root_panel == null:
		return
	root_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	root_panel.anchor_left = panel_anchor_left
	root_panel.anchor_top = panel_anchor_top
	root_panel.anchor_right = panel_anchor_right
	root_panel.anchor_bottom = panel_anchor_bottom
	root_panel.offset_left = panel_margin
	root_panel.offset_top = panel_margin
	root_panel.offset_right = -panel_margin
	root_panel.offset_bottom = -panel_margin

	if line_edit:
		var input_style := StyleBoxFlat.new()
		input_style.bg_color = input_bg_color
		input_style.corner_radius_top_left = 4
		input_style.corner_radius_top_right = 4
		input_style.corner_radius_bottom_left = 4
		input_style.corner_radius_bottom_right = 4
		input_style.content_margin_left = 8
		input_style.content_margin_right = 8
		line_edit.add_theme_stylebox_override("normal", input_style)
		line_edit.add_theme_font_size_override("font_size", font_size)
		if _font:
			line_edit.add_theme_font_override("font", _font)
	if send_button:
		send_button.add_theme_font_size_override("font_size", font_size)
		if _font:
			send_button.add_theme_font_override("font", _font)
	if _emoji_btn:
		_emoji_btn.add_theme_font_size_override("font_size", font_size)
		if _font:
			_emoji_btn.add_theme_font_override("font", _font)
	_set_background_visible(_input_active)


func _set_background_visible(show_bg: bool) -> void:
	if root_panel == null:
		return
	var style := StyleBoxFlat.new()
	style.bg_color = panel_color if show_bg else Color(0, 0, 0, 0)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	root_panel.add_theme_stylebox_override("panel", style)


func _set_input_row_shown(shown: bool) -> void:
	if input_row == null:
		return
	input_row.visible = true
	input_row.modulate.a = 1.0 if shown else 0.0
	if line_edit:
		line_edit.editable = shown
		line_edit.mouse_filter = Control.MOUSE_FILTER_STOP if shown else Control.MOUSE_FILTER_IGNORE
	if send_button:
		send_button.disabled = not shown
		send_button.mouse_filter = Control.MOUSE_FILTER_STOP if shown else Control.MOUSE_FILTER_IGNORE
	if _emoji_btn:
		_emoji_btn.disabled = not shown
		_emoji_btn.mouse_filter = Control.MOUSE_FILTER_STOP if shown else Control.MOUSE_FILTER_IGNORE
	if not shown and _emoji_popup:
		_emoji_popup.hide()


func _set_filter_recursive(node: Node, filter: Control.MouseFilter) -> void:
	if node is Control:
		(node as Control).mouse_filter = filter
	for child in node.get_children():
		_set_filter_recursive(child, filter)


func _set_interactive(active: bool) -> void:
	if root_panel == null:
		return
	if not active:
		_set_filter_recursive(root_panel, Control.MOUSE_FILTER_IGNORE)
		if _scroll:
			_scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return
	_set_filter_recursive(root_panel, Control.MOUSE_FILTER_IGNORE)
	if line_edit:
		line_edit.mouse_filter = Control.MOUSE_FILTER_STOP
	if send_button:
		send_button.mouse_filter = Control.MOUSE_FILTER_STOP
	if _emoji_btn:
		_emoji_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	if input_row:
		input_row.mouse_filter = Control.MOUSE_FILTER_STOP
	if _scroll:
		_scroll.mouse_filter = Control.MOUSE_FILTER_STOP


func is_input_active() -> bool:
	return _input_active


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func open_input() -> void:
	_input_active = true
	_set_input_row_shown(true)
	# Save any mid-fade live messages, then switch to history layer.
	_stash_live_fades_from_entries()
	_session_new.clear()
	_clear_live_list()
	_set_layer_mode(true)
	_rebuild_from_history()
	_set_background_visible(true)
	_set_interactive(true)
	if line_edit:
		line_edit.editable = true
		line_edit.mouse_filter = Control.MOUSE_FILTER_STOP
		line_edit.clear()
		line_edit.call_deferred("grab_focus")
	if send_button:
		send_button.disabled = false
		send_button.mouse_filter = Control.MOUSE_FILTER_STOP
	if _emoji_btn:
		_emoji_btn.disabled = false
		_emoji_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	call_deferred("_scroll_history_to_bottom")
	input_opened.emit()


func close_input(restore_mouse: bool = true) -> void:
	if not _input_active:
		return
	_input_active = false
	if line_edit:
		line_edit.release_focus()
		line_edit.clear()
	_set_input_row_shown(false)
	_set_background_visible(false)
	_set_interactive(false)
	# History only while open — wipe it and show live layer with session + fades.
	_clear_history_list()
	_set_layer_mode(false)
	_restore_live_view()
	if restore_mouse:
		input_closed.emit()


func _rebuild_from_history() -> void:
	_clear_history_list()
	if ChatManager == null or not ChatManager.has_method("get_history"):
		return
	_rebuilding_history = true
	var hist: Array = ChatManager.get_history()
	for m in hist:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		_append_to_list(
			_message_list,
			str(m.get("sender", "?")),
			str(m.get("text", "")),
			bool(m.get("system", false)),
			0.0,
			false
		)
	_rebuilding_history = false


func _stash_live_fades_from_entries() -> void:
	for e in _live_entries:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var row: Control = e.get("row")
		if not is_instance_valid(row) or not row.visible:
			continue
		var age := float(e.get("age", 0.0))
		if age >= _fade_lifetime():
			continue
		_live_fades.append({
			"sender": str(e.get("sender", "")),
			"text": str(e.get("text", "")),
			"system": bool(e.get("system", false)),
			"age": age,
		})


func _restore_live_view() -> void:
	_clear_live_list()
	var shown: Dictionary = {}

	for f in _live_fades:
		if typeof(f) != TYPE_DICTIONARY:
			continue
		var age := float(f.get("age", 0.0))
		if age >= _fade_lifetime():
			continue
		var key := "%s\n%s\n%s" % [f.get("sender", ""), f.get("text", ""), f.get("system", false)]
		if shown.has(key):
			continue
		shown[key] = true
		_append_to_list(
			_live_list,
			str(f.get("sender", "?")),
			str(f.get("text", "")),
			bool(f.get("system", false)),
			age,
			true
		)

	for m in _session_new:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var key2 := "%s\n%s\n%s" % [m.get("sender", ""), m.get("text", ""), m.get("system", false)]
		if shown.has(key2):
			continue
		shown[key2] = true
		_append_to_list(
			_live_list,
			str(m.get("sender", "?")),
			str(m.get("text", "")),
			bool(m.get("system", false)),
			0.0,
			true
		)

	_live_fades.clear()
	_session_new.clear()


func _clear_history_list() -> void:
	if _message_list == null:
		return
	for c in _message_list.get_children():
		c.queue_free()


func _clear_live_list() -> void:
	for e in _live_entries:
		if is_instance_valid(e.get("row")):
			e.row.queue_free()
	_live_entries.clear()
	if _live_list:
		for c in _live_list.get_children():
			c.queue_free()


# ---------------------------------------------------------------------------
# Public append — routes to history (open) or live (closed)
# ---------------------------------------------------------------------------

func append_message(sender: String, text: String, is_system: bool = false, initial_age: float = 0.0) -> void:
	if _input_active:
		# Visible in open history; also remember for closed live view (unless rebuild).
		if not _rebuilding_history:
			_session_new.append({"sender": sender, "text": text, "system": is_system})
		_append_to_list(_message_list, sender, text, is_system, 0.0, false)
		call_deferred("_scroll_history_to_bottom")
	else:
		_append_to_list(_live_list, sender, text, is_system, initial_age, true)


func _append_to_list(
	parent: VBoxContainer,
	sender: String,
	text: String,
	is_system: bool,
	initial_age: float,
	is_live: bool
) -> void:
	if parent == null:
		return

	var parsed := _parse_message_content(text)
	var body_text: String = parsed.text
	var image_urls: PackedStringArray = parsed.urls

	var safe_body := body_text.replace("[", "[lb]")
	safe_body = _apply_emoji_bbcode(safe_body)

	# Image-only messages still show the sender name so the line is never blank.
	var line: String
	if is_system:
		if safe_body.strip_edges().is_empty() and image_urls.size() > 0:
			line = "[color=#%s][image][/color]" % system_color.to_html(false)
		else:
			line = "[color=#%s]%s[/color]" % [system_color.to_html(false), safe_body]
	else:
		if safe_body.strip_edges().is_empty() and image_urls.size() > 0:
			line = "[color=#%s]%s[/color]:" % [
				name_color.to_html(false), sender.replace("[", "[lb]"),
			]
		else:
			line = "[color=#%s]%s[/color]: [color=#%s]%s[/color]" % [
				name_color.to_html(false), sender.replace("[", "[lb]"),
				text_color.to_html(false), safe_body,
			]

	var row := VBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 4)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("normal_font_size", font_size)
	if _font:
		label.add_theme_font_override("normal_font", _font)
	label.add_theme_color_override("default_color", text_color)
	var pad := StyleBoxEmpty.new()
	pad.content_margin_left = 4
	pad.content_margin_right = 2
	label.add_theme_stylebox_override("normal", pad)
	label.text = line

	var list_w := _list_width(parent)
	label.custom_minimum_size = Vector2(list_w, float(font_size) + 6.0)
	row.add_child(label)

	var pending := 0
	for url in image_urls:
		var slot := TextureRect.new()
		slot.name = "ImgSlot"
		slot.set_meta("chat_image_url", url)
		slot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		slot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		slot.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.custom_minimum_size = Vector2(0, 0)
		slot.visible = false
		row.add_child(slot)
		var cached := _image_loader.get_cached(url) if _image_loader else null
		if cached:
			_apply_texture_to_slot(slot, cached, false)
		elif _image_loader:
			pending += 1
			_image_loader.request_image(url)
		else:
			pending += 1

	row.set_meta("pending_images", pending)
	row.set_meta("is_live", is_live)
	# Always show the name line immediately. Image slots fill in when ready
	# (GIFs can take a moment on a worker thread). Never leave a blank row.
	row.visible = true
	row.modulate.a = 1.0

	parent.add_child(row)

	if is_live:
		# Cap live backlog (oldest first) without height-trimming the newest.
		while _live_entries.size() >= max_messages:
			var old: Dictionary = _live_entries.pop_front()
			if is_instance_valid(old.get("row")):
				old.row.queue_free()
		_live_entries.append({
			"row": row,
			"age": maxf(initial_age, 0.0),
			"sender": sender,
			"text": text,
			"system": is_system,
		})

	if pending <= 0:
		call_deferred("_finalize_row", row, parent)


func _parse_message_content(text: String) -> Dictionary:
	var urls: PackedStringArray = []
	var remaining := text
	if _url_re:
		var matches := _url_re.search_all(text)
		for i in range(matches.size() - 1, -1, -1):
			var m: RegExMatch = matches[i]
			var url := m.get_string(1)
			if url.to_lower().begins_with("http://") or url.to_lower().begins_with("https://"):
				urls.insert(0, url)
				remaining = remaining.substr(0, m.get_start()) + remaining.substr(m.get_end())
	remaining = remaining.strip_edges()
	while remaining.find("  ") >= 0:
		remaining = remaining.replace("  ", " ")
	return {"text": remaining, "urls": urls}


func _apply_emoji_bbcode(text: String) -> String:
	if _emoji_re == null:
		return text
	var out := text
	var matches := _emoji_re.search_all(text)
	for i in range(matches.size() - 1, -1, -1):
		var m: RegExMatch = matches[i]
		var ename := m.get_string(1)
		var path := _emoji_registry.get_path(ename)
		if path.is_empty():
			continue
		var tag := "[img=%d]%s[/img]" % [font_size, path]
		out = out.substr(0, m.get_start()) + tag + out.substr(m.get_end())
	return out


func _apply_texture_to_slot(slot: TextureRect, tex: Texture2D, settle: bool = true) -> void:
	if not is_instance_valid(slot) or tex == null:
		return
	slot.texture = tex
	var tw := float(tex.get_width())
	var th := float(tex.get_height())
	if tw < 1.0 or th < 1.0:
		return
	var max_w := _list_width(_live_list if (slot.get_parent() and slot.get_parent().get_meta("is_live", false)) else _message_list)
	# Prefer parent list width
	var parent_row := slot.get_parent() as Control
	if parent_row and parent_row.get_parent() is VBoxContainer:
		max_w = _list_width(parent_row.get_parent() as VBoxContainer)
	var max_h := max_image_height
	var scale := minf(max_w / tw, max_h / th)
	scale = minf(scale, 2.0)
	var dw := tw * scale
	var dh := th * scale
	slot.custom_minimum_size = Vector2(dw, dh)
	slot.size = Vector2(dw, dh)
	slot.visible = true
	if settle and parent_row:
		_settle_pending_image(parent_row)


func _settle_pending_image(row: Control) -> void:
	if not is_instance_valid(row):
		return
	var left := maxi(int(row.get_meta("pending_images", 0)) - 1, 0)
	row.set_meta("pending_images", left)
	if left > 0:
		return
	row.visible = true
	row.modulate.a = 1.0
	var parent := row.get_parent() as VBoxContainer
	call_deferred("_finalize_row", row, parent)


func _on_image_ready(url: String, texture: Texture2D) -> void:
	for list in [_live_list, _message_list]:
		if list == null:
			continue
		for row in list.get_children():
			if not is_instance_valid(row) or not (row is Control):
				continue
			for child in row.get_children():
				if not is_instance_valid(child):
					continue
				if child is TextureRect and child.has_meta("chat_image_url"):
					if str(child.get_meta("chat_image_url")) == url:
						var slot := child as TextureRect
						if slot.texture != null:
							continue
						_apply_texture_to_slot(slot, texture, true)


func _on_image_failed(url: String, _reason: String) -> void:
	# GIFs (and other undecodable images) land here — drop the slot, reveal the row.
	for list in [_live_list, _message_list]:
		if list == null:
			continue
		for row in list.get_children():
			if not is_instance_valid(row) or not (row is Control):
				continue
			var matched := false
			for child in row.get_children():
				if not is_instance_valid(child):
					continue
				if not (child is TextureRect and child.has_meta("chat_image_url")):
					continue
				if str(child.get_meta("chat_image_url")) != url:
					continue
				matched = true
				# Remove immediately so finalize never sees a freed instance via `is`.
				row.remove_child(child)
				child.free()
			if matched:
				_settle_pending_image(row as Control)


func _list_width(list: VBoxContainer) -> float:
	if list and is_instance_valid(list) and list.size.x > 1.0:
		return list.size.x
	if _message_area and _message_area.size.x > 1.0:
		return _message_area.size.x
	if _scroll and _scroll.size.x > 1.0:
		return _scroll.size.x
	return 320.0


func _finalize_row(row: Control, parent: VBoxContainer) -> void:
	if not is_instance_valid(row):
		return
	var w := _list_width(parent)
	var total_h := 0.0
	# Snapshot children first — slots may be freed mid-loop when a GIF fails.
	var children: Array = row.get_children()
	for child in children:
		if not is_instance_valid(child):
			continue
		if child is RichTextLabel:
			var label := child as RichTextLabel
			label.custom_minimum_size.x = w
			await get_tree().process_frame
			if not is_instance_valid(row) or not is_instance_valid(label):
				return
			var h := float(label.get_content_height())
			if h < float(font_size):
				h = float(font_size) + 6.0
			label.custom_minimum_size = Vector2(w, h)
			label.size = Vector2(w, h)
			total_h += h
		elif child is TextureRect:
			var slot := child as TextureRect
			if slot.visible:
				total_h += slot.custom_minimum_size.y
	if not is_instance_valid(row):
		return
	var child_count := 0
	for c in row.get_children():
		if is_instance_valid(c):
			child_count += 1
	total_h += maxf(0, child_count - 1) * 4.0
	row.custom_minimum_size = Vector2(w, maxf(total_h, float(font_size) + 6.0))
	# Live list is bottom-anchored with GROW_DIRECTION_BEGIN — increasing
	# min height pushes content upward so the image bottom stays on-screen.
	if _input_active and parent == _message_list:
		await _scroll_history_to_bottom()


func _scroll_history_to_bottom() -> void:
	if _scroll == null:
		return
	await get_tree().process_frame
	if not is_instance_valid(_scroll):
		return
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func clear_log() -> void:
	_clear_history_list()
	_clear_live_list()


func _on_text_submitted(text: String) -> void:
	_submit(text)


func _on_send_pressed() -> void:
	_submit(line_edit.text if line_edit else "")


func _submit(text: String) -> void:
	var cleaned := text.strip_edges()
	if cleaned.is_empty():
		close_input()
		return
	message_submitted.emit(cleaned)
	if line_edit:
		line_edit.clear()
		line_edit.release_focus()
	close_input(true)
