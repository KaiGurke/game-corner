extends Control

## Settings menu with pending changes → Apply / Save.
## Controls: up to 3 binds per action (primary + 2 extra).

const SETTINGS_PATH := "user://settings.cfg"
const MAX_BINDS := 3

const BIND_SECTIONS := {
	"Movement": [
		{"action": "move_forward", "label": "Move Forward"},
		{"action": "move_backward", "label": "Move Backward"},
		{"action": "move_left", "label": "Move Left"},
		{"action": "move_right", "label": "Move Right"},
		{"action": "jump", "label": "Jump"},
		{"action": "crouch", "label": "Crouch"},
		{"action": "sprint", "label": "Sprint"},
		{"action": "sneak", "label": "Sneak"},
	],
	"Equipment": [
		{"action": "interact", "label": "Interact"},
		{"action": "reload", "label": "Reload"},
	],
	"Other": [
		{"action": "escape_menu", "label": "Menu / Escape"},
		{"action": "noclip", "label": "Noclip"},
	],
	"Misc": [
		{"action": "limbo_console_toggle", "label": "Dev Console"},
		{"action": "limbo_console_search_history", "label": "Console History"},
		{"action": "chat", "label": "Chat"},
		{"action": "scoreboard", "label": "Scoreboard"},
		{"action": "third_person", "label": "Third Person"},
	],
}

const RESOLUTION_CANDIDATES := [
	Vector2i(1280, 720),
	Vector2i(1366, 768),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
	Vector2i(3840, 2160),
]
const FPS_LIMITS := [30, 60, 120, 165, 300, 0]

@onready var controls_scroll: ScrollContainer = %ScrollContainer
@onready var section_movement: VBoxContainer = %SectionMovement
@onready var section_equipment: VBoxContainer = %SectionEquipment
@onready var section_other: VBoxContainer = %SectionOther
@onready var sensitivity_value_label: Label = %SensitivityValue
@onready var sensitivity_slider: HSlider = $TabContainer/General/ScrollContainer/Content/MouseSection/MouseVBox/SensitivityRow/SensitivitySlider

var _invert_check: CheckButton
var _status_label: Label

## Applied (live) values
var mouse_sensitivity: float = 1.0
var invert_mouse: bool = false
var master_volume: float = 1.0
var music_volume: float = 1.0
var ui_volume: float = 1.0
var window_mode_index: int = 0
var resolution_index: int = 0
var vsync_on: bool = true
var fps_limit_index: int = 1

## Pending (edited in UI, not live until Apply)
var _pending: Dictionary = {}
var _pending_binds: Dictionary = {}  # action -> Array[InputEvent]

var _listening_action: String = ""
var _listening_slot: int = -1
var _bind_buttons: Dictionary = {}  # "action:slot" -> Button

var _supported_resolutions: Array[Vector2i] = []
var _selected_resolution: Vector2i = Vector2i(1920, 1080)

## Crosshair editor state
var _pending_crosshair: CrosshairProfile = null
var _crosshair_preview: CrosshairView = null
var _crosshair_code_edit: LineEdit = null
var _crosshair_preset_option: OptionButton = null
var _crosshair_element_panels: Dictionary = {}  # key -> PanelContainer


func _ready() -> void:
	visible = false
	_ensure_misc_section()
	_ensure_invert_toggle()
	_ensure_apply_save_buttons()
	_ensure_crosshair_tab()
	_load_settings()
	_copy_applied_to_pending()
	_populate_supported_resolutions()
	_sync_ui_from_pending()
	_populate_bind_sections()
	_capture_current_binds_to_pending()
	_refresh_all_bind_labels()
	_sync_crosshair_ui_from_pending()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	# Capture rebind
	if not _listening_action.is_empty():
		if event is InputEventKey and event.pressed and not event.echo:
			if (event as InputEventKey).physical_keycode == KEY_ESCAPE:
				_cancel_listening()
				get_viewport().set_input_as_handled()
				return
			_finish_rebind(event)
			get_viewport().set_input_as_handled()
			return
		if event is InputEventMouseButton and event.pressed:
			_finish_rebind(event)
			get_viewport().set_input_as_handled()
			return
		return
	if event.is_action_pressed("escape_menu"):
		_close_menu()
		get_viewport().set_input_as_handled()


func _open_menu() -> void:
	visible = true
	_copy_applied_to_pending()
	_capture_current_binds_to_pending()
	_sync_ui_from_pending()
	_refresh_all_bind_labels()
	_set_status("")


func _close_menu() -> void:
	_cancel_listening()
	visible = false


# ---------------------------------------------------------------------------
# UI bootstrap helpers (scene patches without full rewrite)
# ---------------------------------------------------------------------------

func _ensure_invert_toggle() -> void:
	var mouse_vbox := get_node_or_null("TabContainer/General/ScrollContainer/Content/MouseSection/MouseVBox")
	if mouse_vbox == null:
		return
	if mouse_vbox.has_node("InvertRow"):
		_invert_check = mouse_vbox.get_node("InvertRow/InvertMouse") as CheckButton
	else:
		var row := HBoxContainer.new()
		row.name = "InvertRow"
		row.add_theme_constant_override("separation", 16)
		var label := Label.new()
		label.text = "Invert Mouse Y"
		label.custom_minimum_size = Vector2(180, 0)
		label.add_theme_font_size_override("font_size", 22)
		row.add_child(label)
		_invert_check = CheckButton.new()
		_invert_check.name = "InvertMouse"
		_invert_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_invert_check.toggled.connect(_on_invert_toggled)
		row.add_child(_invert_check)
		mouse_vbox.add_child(row)
	_ensure_hurt_sound_placeholder()


func _ensure_hurt_sound_placeholder() -> void:
	var content := get_node_or_null("TabContainer/General/ScrollContainer/Content")
	if content == null or content.has_node("HurtSoundSection"):
		return
	var header := Label.new()
	header.name = "HurtSoundHeader"
	header.text = "Hurt Sound"
	header.add_theme_font_size_override("font_size", 24)
	content.add_child(header)

	var section := PanelContainer.new()
	section.name = "HurtSoundSection"
	content.add_child(section)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	section.add_child(vbox)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	vbox.add_child(row)

	var info := Label.new()
	info.text = "Record a hurt sound others can hear"
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_font_size_override("font_size", 18)
	row.add_child(info)

	var btn := Button.new()
	btn.name = "RecordHurtSound"
	btn.text = "Record (Coming Soon)"
	btn.disabled = true
	btn.tooltip_text = "Placeholder — recording not implemented yet"
	btn.custom_minimum_size = Vector2(200, 0)
	row.add_child(btn)


func _ensure_misc_section() -> void:
	var content := get_node_or_null("TabContainer/Controls/HBox/ScrollContainer/Content")
	var nav := get_node_or_null("TabContainer/Controls/HBox/NavPanel/NavButtons")
	if content == null:
		return
	if not content.has_node("SectionMisc"):
		var section := VBoxContainer.new()
		section.name = "SectionMisc"
		section.add_theme_constant_override("separation", 8)
		var header := Label.new()
		header.name = "HeaderMisc"
		header.text = "Misc"
		header.add_theme_font_size_override("font_size", 26)
		section.add_child(header)
		var binds := VBoxContainer.new()
		binds.name = "BindsMisc"
		section.add_child(binds)
		content.add_child(section)
	if nav and not nav.has_node("BtnMisc"):
		var btn := Button.new()
		btn.name = "BtnMisc"
		btn.text = "Misc"
		btn.pressed.connect(_on_nav_misc_pressed)
		nav.add_child(btn)


func _ensure_apply_save_buttons() -> void:
	if has_node("FooterButtons"):
		return
	var footer := HBoxContainer.new()
	footer.name = "FooterButtons"
	footer.anchor_left = 0.5
	footer.anchor_right = 0.5
	footer.anchor_top = 1.0
	footer.anchor_bottom = 1.0
	footer.offset_left = -280.0
	footer.offset_right = 280.0
	footer.offset_top = -70.0
	footer.offset_bottom = -20.0
	footer.grow_horizontal = Control.GROW_DIRECTION_BOTH
	footer.add_theme_constant_override("separation", 12)
	footer.alignment = BoxContainer.ALIGNMENT_CENTER

	var apply_btn := Button.new()
	apply_btn.name = "ApplyButton"
	apply_btn.text = "Apply"
	apply_btn.custom_minimum_size = Vector2(120, 40)
	apply_btn.pressed.connect(_on_apply_pressed)
	footer.add_child(apply_btn)

	var save_btn := Button.new()
	save_btn.name = "SaveButton"
	save_btn.text = "Save"
	save_btn.custom_minimum_size = Vector2(120, 40)
	save_btn.pressed.connect(_on_save_pressed)
	footer.add_child(save_btn)

	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.custom_minimum_size = Vector2(200, 0)
	_status_label.add_theme_font_size_override("font_size", 16)
	footer.add_child(_status_label)

	add_child(footer)


# ---------------------------------------------------------------------------
# Pending / Apply / Save
# ---------------------------------------------------------------------------

func _copy_applied_to_pending() -> void:
	_pending = {
		"sensitivity": mouse_sensitivity,
		"invert_mouse": invert_mouse,
		"master_volume": master_volume,
		"music_volume": music_volume,
		"ui_volume": ui_volume,
		"window_mode": window_mode_index,
		"resolution": resolution_index,
		"vsync": vsync_on,
		"fps_limit": fps_limit_index,
	}
	if CrosshairManager:
		_pending_crosshair = CrosshairManager.profile.duplicate_profile()
	if _crosshair_preview:
		_sync_crosshair_ui_from_pending()


func _capture_current_binds_to_pending() -> void:
	_pending_binds.clear()
	for section in BIND_SECTIONS.values():
		for bind in section:
			var action: String = bind["action"]
			if not InputMap.has_action(action):
				InputMap.add_action(action)
			var events: Array = []
			for ev in InputMap.action_get_events(action):
				events.append(ev.duplicate())
			# Cap to MAX_BINDS
			while events.size() > MAX_BINDS:
				events.pop_back()
			_pending_binds[action] = events


func _sync_ui_from_pending() -> void:
	if sensitivity_slider:
		sensitivity_slider.set_value_no_signal(_pending.get("sensitivity", 1.0))
	_update_sensitivity_label(float(_pending.get("sensitivity", 1.0)))
	if _invert_check:
		_invert_check.set_pressed_no_signal(bool(_pending.get("invert_mouse", false)))
	# Volumes
	var master_s := get_node_or_null("TabContainer/Audio/AudioTabs/General/Volumes/MasterRow/MasterVolumeSlider") as HSlider
	var music_s := get_node_or_null("TabContainer/Audio/AudioTabs/General/Volumes/MusicRow/MusicVolumeSlider") as HSlider
	var ui_s := get_node_or_null("TabContainer/Audio/AudioTabs/General/Volumes/UIRow/UIVolumeSlider") as HSlider
	if master_s:
		master_s.set_value_no_signal(float(_pending.get("master_volume", 1.0)))
	if music_s:
		music_s.set_value_no_signal(float(_pending.get("music_volume", 1.0)))
	if ui_s:
		ui_s.set_value_no_signal(float(_pending.get("ui_volume", 1.0)))
	# Video
	var res_btn := _get_resolution_button()
	if res_btn and resolution_index < res_btn.item_count:
		res_btn.select(int(_pending.get("resolution", 0)))
	var mode_btn := find_child("WindowMode", true, false) as OptionButton
	if mode_btn and mode_btn is OptionButton:
		# Prefer the video tab's WindowMode option
		var video_mode := get_node_or_null("TabContainer/Video/VideoTabs/General/Rows/ControlsCol/WindowMode") as OptionButton
		if video_mode:
			video_mode.select(int(_pending.get("window_mode", 0)))
	var vsync_btn := get_node_or_null("TabContainer/Video/VideoTabs/General/Rows/ControlsCol/VSync") as CheckButton
	if vsync_btn:
		vsync_btn.set_pressed_no_signal(bool(_pending.get("vsync", true)))
	var fps_btn := get_node_or_null("TabContainer/Video/VideoTabs/General/Rows/ControlsCol/FPSLimit") as OptionButton
	if fps_btn:
		fps_btn.select(int(_pending.get("fps_limit", 1)))


func _on_apply_pressed() -> void:
	_apply_pending()
	_set_status("Applied")


func _on_save_pressed() -> void:
	_apply_pending()
	_save_settings()
	_set_status("Saved")


func _apply_pending() -> void:
	mouse_sensitivity = float(_pending.get("sensitivity", 1.0))
	invert_mouse = bool(_pending.get("invert_mouse", false))
	master_volume = float(_pending.get("master_volume", 1.0))
	music_volume = float(_pending.get("music_volume", 1.0))
	ui_volume = float(_pending.get("ui_volume", 1.0))

	var prev_mode := window_mode_index
	var prev_res := resolution_index
	var prev_vsync := vsync_on
	var prev_fps := fps_limit_index

	window_mode_index = int(_pending.get("window_mode", 0))
	resolution_index = int(_pending.get("resolution", 0))
	vsync_on = bool(_pending.get("vsync", true))
	fps_limit_index = int(_pending.get("fps_limit", 1))

	_apply_mouse_to_players()
	_apply_volumes()
	# Only touch display when video fields actually changed (Apply must not resize the window otherwise)
	var video_changed := (
		window_mode_index != prev_mode
		or resolution_index != prev_res
		or vsync_on != prev_vsync
		or fps_limit_index != prev_fps
	)
	if video_changed:
		_apply_video(window_mode_index != prev_mode or resolution_index != prev_res)
	_apply_binds_from_pending()
	_apply_crosshair_pending()


func _apply_mouse_to_players() -> void:
	for node in get_tree().get_nodes_in_group("player"):
		if "SENSITIVITY" in node:
			node.SENSITIVITY = mouse_sensitivity
		if "invert_mouse_y" in node:
			node.invert_mouse_y = invert_mouse
		elif node.has_method("set_invert_mouse"):
			node.set_invert_mouse(invert_mouse)


func _apply_volumes() -> void:
	var mid := AudioServer.get_bus_index("Master")
	if mid >= 0:
		AudioServer.set_bus_volume_db(mid, linear_to_db(master_volume))
	mid = AudioServer.get_bus_index("Music")
	if mid >= 0:
		AudioServer.set_bus_volume_db(mid, linear_to_db(music_volume))
	mid = AudioServer.get_bus_index("UI")
	if mid >= 0:
		AudioServer.set_bus_volume_db(mid, linear_to_db(ui_volume))


func _apply_video(resize_window: bool = true) -> void:
	if resize_window:
		if resolution_index >= 0 and resolution_index < _supported_resolutions.size():
			_selected_resolution = _supported_resolutions[resolution_index]
		_commit_window_mode(window_mode_index)
	if vsync_on:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	if fps_limit_index >= 0 and fps_limit_index < FPS_LIMITS.size():
		Engine.max_fps = FPS_LIMITS[fps_limit_index]


func _apply_binds_from_pending() -> void:
	for action in _pending_binds:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		InputMap.action_erase_events(action)
		for ev in _pending_binds[action]:
			if ev is InputEvent:
				InputMap.action_add_event(action, ev)
	_refresh_all_bind_labels()


func _set_status(text: String) -> void:
	if _status_label:
		_status_label.text = text


# ---------------------------------------------------------------------------
# Controls – rebinding
# ---------------------------------------------------------------------------

func _populate_bind_sections() -> void:
	_bind_buttons.clear()
	var move_box := section_movement.get_node_or_null("BindsMovement")
	var equip_box := section_equipment.get_node_or_null("BindsEquipment")
	var other_box := section_other.get_node_or_null("BindsOther")
	var misc_section := get_node_or_null("TabContainer/Controls/HBox/ScrollContainer/Content/SectionMisc")
	var misc_box: VBoxContainer = null
	if misc_section:
		misc_box = misc_section.get_node_or_null("BindsMisc") as VBoxContainer
	if move_box:
		_fill_section(move_box, BIND_SECTIONS["Movement"])
	if equip_box:
		_fill_section(equip_box, BIND_SECTIONS["Equipment"])
	if other_box:
		_fill_section(other_box, BIND_SECTIONS["Other"])
	if misc_box:
		_fill_section(misc_box, BIND_SECTIONS["Misc"])


func _fill_section(container: VBoxContainer, binds: Array) -> void:
	for child in container.get_children():
		child.queue_free()
	for bind in binds:
		var action: String = bind["action"]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var name_label := Label.new()
		name_label.text = bind["label"]
		name_label.custom_minimum_size = Vector2(200, 0)
		name_label.add_theme_font_size_override("font_size", 18)
		row.add_child(name_label)

		for slot in range(MAX_BINDS):
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(110, 0)
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.toggle_mode = false
			var a := action
			var s := slot
			btn.pressed.connect(func(): _start_listening(a, s))
			btn.gui_input.connect(func(ev): _on_bind_btn_gui_input(ev, a, s))
			row.add_child(btn)
			_bind_buttons["%s:%d" % [action, slot]] = btn

		container.add_child(row)


func _refresh_all_bind_labels() -> void:
	for key in _bind_buttons:
		var key_str: String = str(key)
		var parts: PackedStringArray = key_str.split(":")
		if parts.size() != 2:
			continue
		var action: String = parts[0]
		var slot: int = int(parts[1])
		var btn: Button = _bind_buttons[key]
		var events: Array = _pending_binds.get(action, [])
		if slot < events.size() and events[slot] is InputEvent:
			btn.text = _event_to_string(events[slot])
		else:
			btn.text = "—"
		if _listening_action == action and _listening_slot == slot:
			btn.text = "..."


func _event_to_string(ev: InputEvent) -> String:
	if ev is InputEventKey:
		var key_ev := ev as InputEventKey
		var code: Key = key_ev.physical_keycode if key_ev.physical_keycode != KEY_NONE else key_ev.keycode
		return OS.get_keycode_string(code)
	if ev is InputEventMouseButton:
		return "Mouse %d" % (ev as InputEventMouseButton).button_index
	return ev.as_text()


func _start_listening(action: String, slot: int) -> void:
	_listening_action = action
	_listening_slot = slot
	_refresh_all_bind_labels()
	_set_status("Press a key (Esc cancel)")


func _cancel_listening() -> void:
	_listening_action = ""
	_listening_slot = -1
	_refresh_all_bind_labels()


func _finish_rebind(event: InputEvent) -> void:
	if _listening_action.is_empty() or _listening_slot < 0:
		return
	var action := _listening_action
	var slot := _listening_slot
	var store := event.duplicate()
	if store is InputEventKey:
		(store as InputEventKey).pressed = true
	if not _pending_binds.has(action):
		_pending_binds[action] = []
	var events: Array = _pending_binds[action]
	# Pad with nulls up to slot
	while events.size() <= slot:
		events.append(null)
	events[slot] = store
	# Compact nulls out but keep order of set slots
	var cleaned: Array = []
	for e in events:
		if e != null:
			cleaned.append(e)
	while cleaned.size() > MAX_BINDS:
		cleaned.pop_back()
	_pending_binds[action] = cleaned
	_listening_action = ""
	_listening_slot = -1
	_refresh_all_bind_labels()
	_set_status("Bind set (Apply to use)")


func _on_bind_btn_gui_input(event: InputEvent, action: String, slot: int) -> void:
	# Right-click clears that slot in pending binds
	if event is InputEventMouseButton and event.pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT:
		if not _pending_binds.has(action):
			return
		var events: Array = _pending_binds[action]
		if slot < events.size():
			events.remove_at(slot)
			_pending_binds[action] = events
			_refresh_all_bind_labels()
			_set_status("Bind cleared (Apply to use)")


func _scroll_to_section(section: Control) -> void:
	if controls_scroll == null or section == null:
		return
	await get_tree().process_frame
	controls_scroll.scroll_vertical = int(section.position.y)


func _on_nav_movement_pressed() -> void:
	_scroll_to_section(section_movement)


func _on_nav_equipment_pressed() -> void:
	_scroll_to_section(section_equipment)


func _on_nav_other_pressed() -> void:
	_scroll_to_section(section_other)


func _on_nav_misc_pressed() -> void:
	var misc := get_node_or_null("TabContainer/Controls/HBox/ScrollContainer/Content/SectionMisc")
	if misc:
		_scroll_to_section(misc)


# ---------------------------------------------------------------------------
# General – mouse (pending only)
# ---------------------------------------------------------------------------

func _on_sensitivity_slider_value_changed(value: float) -> void:
	_pending["sensitivity"] = value
	_update_sensitivity_label(value)


func _on_invert_toggled(toggled_on: bool) -> void:
	_pending["invert_mouse"] = toggled_on


func _update_sensitivity_label(value: float) -> void:
	if sensitivity_value_label:
		sensitivity_value_label.text = "%.2f" % value


# ---------------------------------------------------------------------------
# Video (pending only until Apply)
# ---------------------------------------------------------------------------

func _get_resolution_button() -> OptionButton:
	var btn := get_node_or_null("%WindowResolution")
	if btn == null:
		btn = find_child("WindowResolution", true, false)
	return btn as OptionButton


func _populate_supported_resolutions() -> void:
	var btn := _get_resolution_button()
	if btn == null:
		return
	var screen := DisplayServer.window_get_current_screen()
	var monitor := DisplayServer.screen_get_size(screen)
	_supported_resolutions.clear()
	btn.clear()
	for res in RESOLUTION_CANDIDATES:
		if res.x <= monitor.x and res.y <= monitor.y:
			_supported_resolutions.append(res)
			btn.add_item("%dx%d" % [res.x, res.y])
	if _supported_resolutions.is_empty():
		_supported_resolutions.append(monitor)
		btn.add_item("%dx%d" % [monitor.x, monitor.y])
	var prefer := monitor
	var pick := _supported_resolutions.size() - 1
	for i in range(_supported_resolutions.size()):
		if _supported_resolutions[i] == prefer:
			pick = i
			break
	if resolution_index >= 0 and resolution_index < _supported_resolutions.size():
		pick = resolution_index
	btn.select(pick)
	resolution_index = pick
	_pending["resolution"] = pick
	_selected_resolution = _supported_resolutions[pick]


func _commit_window_mode(index: int) -> void:
	match index:
		0:
			get_tree().root.content_scale_size = _selected_resolution
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		1:
			get_tree().root.content_scale_size = _selected_resolution
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		2:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			_apply_window_size(_selected_resolution)
		3:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
			_apply_window_size(_selected_resolution)
		4:
			get_tree().root.content_scale_size = _selected_resolution
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


func _apply_window_size(size: Vector2i) -> void:
	_selected_resolution = size
	var mode := DisplayServer.window_get_mode()
	if mode == DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_size(size)
		var screen := DisplayServer.window_get_current_screen()
		var screen_pos := DisplayServer.screen_get_position(screen)
		var screen_size := DisplayServer.screen_get_size(screen)
		var origin := screen_pos + (screen_size - size) / 2
		DisplayServer.window_set_position(origin)


func _on_window_resolution_item_selected(index: int) -> void:
	_pending["resolution"] = index
	if index >= 0 and index < _supported_resolutions.size():
		_selected_resolution = _supported_resolutions[index]


func _on_window_mode_item_selected(index: int) -> void:
	_pending["window_mode"] = index


func _on_v_sync_toggled(toggled_on: bool) -> void:
	_pending["vsync"] = toggled_on


func _on_fps_limit_item_selected(index: int) -> void:
	_pending["fps_limit"] = index


# ---------------------------------------------------------------------------
# Audio (pending)
# ---------------------------------------------------------------------------

func _on_master_volume_slider_value_changed(value: float) -> void:
	_pending["master_volume"] = value


func _on_music_volume_slider_value_changed(value: float) -> void:
	_pending["music_volume"] = value


func _on_ui_volume_slider_value_changed(value: float) -> void:
	_pending["ui_volume"] = value


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("mouse", "sensitivity", mouse_sensitivity)
	cfg.set_value("mouse", "invert", invert_mouse)
	cfg.set_value("audio", "master", master_volume)
	cfg.set_value("audio", "music", music_volume)
	cfg.set_value("audio", "ui", ui_volume)
	cfg.set_value("video", "window_mode", window_mode_index)
	cfg.set_value("video", "resolution", resolution_index)
	cfg.set_value("video", "vsync", vsync_on)
	cfg.set_value("video", "fps_limit", fps_limit_index)
	if _pending_crosshair:
		cfg.set_value("crosshair", "code", _pending_crosshair.export_code())
		cfg.set_value("crosshair", "name", _pending_crosshair.name)
	# Binds
	for action in _pending_binds:
		var serialized: Array = []
		for ev in _pending_binds[action]:
			if ev is InputEvent:
				serialized.append(var_to_str(ev))
		cfg.set_value("binds", action, serialized)
	cfg.save(SETTINGS_PATH)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	mouse_sensitivity = float(cfg.get_value("mouse", "sensitivity", 1.0))
	invert_mouse = bool(cfg.get_value("mouse", "invert", false))
	master_volume = float(cfg.get_value("audio", "master", 1.0))
	music_volume = float(cfg.get_value("audio", "music", 1.0))
	ui_volume = float(cfg.get_value("audio", "ui", 1.0))
	window_mode_index = int(cfg.get_value("video", "window_mode", 0))
	resolution_index = int(cfg.get_value("video", "resolution", 0))
	vsync_on = bool(cfg.get_value("video", "vsync", true))
	fps_limit_index = int(cfg.get_value("video", "fps_limit", 1))
	# Binds
	if cfg.has_section("binds"):
		for action in cfg.get_section_keys("binds"):
			if not InputMap.has_action(action):
				InputMap.add_action(action)
			InputMap.action_erase_events(action)
			var serialized: Array = cfg.get_value("binds", action, [])
			for s in serialized:
				var ev = str_to_var(str(s))
				if ev is InputEvent:
					InputMap.action_add_event(action, ev)
	_apply_mouse_to_players()
	_apply_volumes()
	# Crosshair code
	var xcode := str(cfg.get_value("crosshair", "code", ""))
	if not xcode.is_empty():
		var xp := CrosshairProfile.import_code(xcode)
		if xp and CrosshairManager:
			CrosshairManager.set_profile(xp, false)
	# Video applied lightly (don't force fullscreen on every boot if user was windowed)
	if fps_limit_index >= 0 and fps_limit_index < FPS_LIMITS.size():
		Engine.max_fps = FPS_LIMITS[fps_limit_index]
	if vsync_on:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)


func _on_exit_settings_pressed() -> void:
	_cancel_listening()
	visible = false


# ---------------------------------------------------------------------------
# Crosshair editor tab
# ---------------------------------------------------------------------------

func _ensure_crosshair_tab() -> void:
	var tabs := get_node_or_null("TabContainer") as TabContainer
	if tabs == null or tabs.get_node_or_null("Crosshair") != null:
		return

	var root := MarginContainer.new()
	root.name = "Crosshair"
	root.add_theme_constant_override("margin_left", 16)
	root.add_theme_constant_override("margin_right", 16)
	root.add_theme_constant_override("margin_top", 16)
	root.add_theme_constant_override("margin_bottom", 16)
	tabs.add_child(root)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(hbox)

	# --- Left: live preview ---
	var preview_panel := PanelContainer.new()
	preview_panel.custom_minimum_size = Vector2(280, 280)
	preview_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(preview_panel)

	var preview_host := Control.new()
	preview_host.custom_minimum_size = Vector2(260, 260)
	preview_host.clip_contents = true
	preview_panel.add_child(preview_host)

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.15, 0.18, 0.22, 1.0)
	preview_host.add_child(bg)

	var view_script: Script = load("res://scripts/ui/crosshair_view.gd") as Script
	_crosshair_preview = Control.new()
	_crosshair_preview.set_script(view_script)
	_crosshair_preview.name = "CrosshairPreview"
	_crosshair_preview.preview_mode = true
	_crosshair_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_crosshair_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_host.add_child(_crosshair_preview)

	var preview_lbl := Label.new()
	preview_lbl.text = "Preview"
	preview_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	preview_lbl.set_anchors_preset(Control.PRESET_TOP_WIDE)
	preview_lbl.offset_top = 8
	preview_host.add_child(preview_lbl)

	# --- Right: controls ---
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	hbox.add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	scroll.add_child(content)

	# Presets
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 8)
	content.add_child(preset_row)
	var preset_lbl := Label.new()
	preset_lbl.text = "Preset"
	preset_lbl.custom_minimum_size = Vector2(100, 0)
	preset_row.add_child(preset_lbl)
	_crosshair_preset_option = OptionButton.new()
	_crosshair_preset_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for p in CrosshairProfile.preset_list():
		_crosshair_preset_option.add_item(str(p.name))
	_crosshair_preset_option.item_selected.connect(_on_crosshair_preset_selected)
	preset_row.add_child(_crosshair_preset_option)

	# Code import/export
	var code_row := HBoxContainer.new()
	code_row.add_theme_constant_override("separation", 8)
	content.add_child(code_row)
	_crosshair_code_edit = LineEdit.new()
	_crosshair_code_edit.placeholder_text = "Crosshair code (GCX1:...)"
	_crosshair_code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code_row.add_child(_crosshair_code_edit)
	var copy_btn := Button.new()
	copy_btn.text = "Copy"
	copy_btn.pressed.connect(_on_crosshair_copy_code)
	code_row.add_child(copy_btn)
	var import_btn := Button.new()
	import_btn.text = "Import"
	import_btn.pressed.connect(_on_crosshair_import_code)
	code_row.add_child(import_btn)

	# Element editors
	for key in CrosshairProfile.ELEMENT_KEYS:
		content.add_child(_make_crosshair_element_editor(key))

	if CrosshairManager:
		_pending_crosshair = CrosshairManager.profile.duplicate_profile()
	else:
		_pending_crosshair = CrosshairProfile.make_default()


func _make_crosshair_element_editor(key: String) -> PanelContainer:
	var panel := PanelContainer.new()
	_crosshair_element_panels[key] = panel
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)
	var enable := CheckButton.new()
	enable.name = "Enable"
	enable.text = str(CrosshairProfile.ELEMENT_LABELS.get(key, key))
	enable.toggled.connect(func(on: bool) -> void:
		_pending_crosshair.elements[key]["enabled"] = on
		_refresh_crosshair_preview()
	)
	header.add_child(enable)

	var grid := GridContainer.new()
	grid.name = "Grid"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	vbox.add_child(grid)

	var is_circle := key == CrosshairProfile.EL_INNER_CIRCLE or key == CrosshairProfile.EL_OUTER_CIRCLE
	var is_dot := key == CrosshairProfile.EL_DOT
	var is_lines := key == CrosshairProfile.EL_INNER_LINES or key == CrosshairProfile.EL_OUTER_LINES

	if is_dot:
		_add_slider_row(grid, key, "size", "Size", 0.5, 20.0, 0.5)
	if is_lines:
		_add_slider_row(grid, key, "length", "Length", 0.0, 40.0, 0.5)
		_add_slider_row(grid, key, "gap", "Gap", 0.0, 40.0, 0.5)
		_add_slider_row(grid, key, "thickness", "Thickness", 0.5, 12.0, 0.25)
	if is_circle:
		_add_slider_row(grid, key, "radius", "Radius", 1.0, 80.0, 0.5)
		_add_slider_row(grid, key, "thickness", "Thickness", 0.5, 12.0, 0.25)
	if not is_dot:
		pass
	else:
		_add_slider_row(grid, key, "thickness", "Thickness", 0.5, 12.0, 0.25)

	_add_slider_row(grid, key, "opacity", "Opacity", 0.0, 1.0, 0.05)
	_add_color_row(grid, key, "color", "Color")

	var outline_en := CheckButton.new()
	outline_en.name = "OutlineEnable"
	outline_en.text = "Outline"
	outline_en.toggled.connect(func(on: bool) -> void:
		_pending_crosshair.elements[key]["outline_enabled"] = on
		_refresh_crosshair_preview()
	)
	grid.add_child(outline_en)
	grid.add_child(Control.new())  # spacer

	_add_slider_row(grid, key, "outline_thickness", "Outline Thick", 0.0, 8.0, 0.25)
	_add_color_row(grid, key, "outline_color", "Outline Color")

	return panel


func _add_slider_row(grid: GridContainer, key: String, prop: String, label: String, min_v: float, max_v: float, step: float) -> void:
	var lbl := Label.new()
	lbl.text = label
	grid.add_child(lbl)
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(row)
	var slider := HSlider.new()
	slider.name = prop
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(func(v: float) -> void:
		if _pending_crosshair and _pending_crosshair.elements.has(key):
			_pending_crosshair.elements[key][prop] = v
			_refresh_crosshair_preview()
	)
	row.add_child(slider)
	var val := Label.new()
	val.name = prop + "_val"
	val.custom_minimum_size = Vector2(36, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val)
	slider.value_changed.connect(func(v: float) -> void:
		val.text = "%.2f" % v
	)


func _add_color_row(grid: GridContainer, key: String, prop: String, label: String) -> void:
	var lbl := Label.new()
	lbl.text = label
	grid.add_child(lbl)
	var picker := ColorPickerButton.new()
	picker.name = prop
	picker.custom_minimum_size = Vector2(80, 28)
	picker.edit_alpha = true
	picker.color_changed.connect(func(c: Color) -> void:
		if _pending_crosshair and _pending_crosshair.elements.has(key):
			_pending_crosshair.elements[key][prop] = c
			_refresh_crosshair_preview()
	)
	grid.add_child(picker)


func _sync_crosshair_ui_from_pending() -> void:
	if CrosshairManager and _pending_crosshair == null:
		_pending_crosshair = CrosshairManager.profile.duplicate_profile()
	if _pending_crosshair == null:
		_pending_crosshair = CrosshairProfile.make_default()
	if _crosshair_code_edit:
		_crosshair_code_edit.text = _pending_crosshair.export_code()
	for key in CrosshairProfile.ELEMENT_KEYS:
		var panel: PanelContainer = _crosshair_element_panels.get(key)
		if panel == null:
			continue
		var e: Dictionary = _pending_crosshair.get_element(key)
		var enable := panel.find_child("Enable", true, false) as CheckButton
		if enable:
			enable.set_pressed_no_signal(bool(e.get("enabled", false)))
		var outline_en := panel.find_child("OutlineEnable", true, false) as CheckButton
		if outline_en:
			outline_en.set_pressed_no_signal(bool(e.get("outline_enabled", true)))
		for prop in ["size", "length", "gap", "thickness", "radius", "opacity", "outline_thickness"]:
			var slider := panel.find_child(prop, true, false) as HSlider
			if slider and e.has(prop):
				slider.set_value_no_signal(float(e[prop]))
				var val := panel.find_child(prop + "_val", true, false) as Label
				if val:
					val.text = "%.2f" % float(e[prop])
		for prop in ["color", "outline_color"]:
			var picker := panel.find_child(prop, true, false) as ColorPickerButton
			if picker and e.has(prop):
				picker.color = e[prop] as Color
	_refresh_crosshair_preview()


func _refresh_crosshair_preview() -> void:
	if _crosshair_preview and _pending_crosshair:
		_crosshair_preview.set_profile(_pending_crosshair.duplicate_profile())
	if _crosshair_code_edit and _pending_crosshair:
		_crosshair_code_edit.text = _pending_crosshair.export_code()


func _on_crosshair_preset_selected(index: int) -> void:
	var presets := CrosshairProfile.preset_list()
	if index < 0 or index >= presets.size():
		return
	_pending_crosshair = (presets[index].profile as CrosshairProfile).duplicate_profile()
	_sync_crosshair_ui_from_pending()


func _on_crosshair_copy_code() -> void:
	if _pending_crosshair == null:
		return
	var code := _pending_crosshair.export_code()
	DisplayServer.clipboard_set(code)
	if _crosshair_code_edit:
		_crosshair_code_edit.text = code
	_set_status("Crosshair code copied")


func _on_crosshair_import_code() -> void:
	var code := ""
	if _crosshair_code_edit:
		code = _crosshair_code_edit.text.strip_edges()
	if code.is_empty():
		code = DisplayServer.clipboard_get().strip_edges()
	var p := CrosshairProfile.import_code(code)
	if p == null:
		_set_status("Invalid crosshair code")
		return
	_pending_crosshair = p
	_sync_crosshair_ui_from_pending()
	_set_status("Crosshair imported")


func _apply_crosshair_pending() -> void:
	if _pending_crosshair == null:
		return
	if CrosshairManager:
		CrosshairManager.set_profile(_pending_crosshair.duplicate_profile(), true)
