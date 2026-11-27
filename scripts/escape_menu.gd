extends CanvasLayer

const PLAYER_CFG := "user://player.cfg"
const DEFAULT_MODEL := "Male/Character_01"

@onready var player: CharacterBody3D = get_parent()

@onready var settings_menu: Control = $SettingsMenu

@onready var click_sound = $Click
@onready var quit_delay = $QuitDelay
@onready var hover_sound = $Hover

@onready var model_placeholder: ColorRect = $Control/ModelPlaceholder
@onready var change_model_btn: Button = $Control/ModelPlaceholder/ChangeModel
@onready var suicide_btn: Button = $Control/MenuBar/BoxContainer/Suicide

signal is_open
signal is_not_open

var _preview_viewport: SubViewport = null
var _preview_model: Node3D = null  # CharacterModel
var _preview_yaw: float = 0.0

var _picker: Control = null
var _model_scroll: ScrollContainer = null
var _model_grid: GridContainer = null
var _picker_status: Label = null
var _selected_model_id: String = ""
var _picker_cells: Array = []  # { "id": String, "panel": PanelContainer }


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS  # Menu keeps working even if player is paused later
	if change_model_btn:
		change_model_btn.pressed.connect(_on_change_model_pressed)
		if not change_model_btn.mouse_entered.is_connected(_on_change_model_mouse_entered):
			change_model_btn.mouse_entered.connect(_on_change_model_mouse_entered)
	if suicide_btn:
		if not suicide_btn.pressed.is_connected(_on_suicide_pressed):
			suicide_btn.pressed.connect(_on_suicide_pressed)
		if not suicide_btn.mouse_entered.is_connected(_on_suicide_mouse_entered):
			suicide_btn.mouse_entered.connect(_on_suicide_mouse_entered)
	_setup_model_preview()
	_setup_model_picker()


func _process(delta: float) -> void:
	if not visible or _preview_model == null:
		return
	# Slow turntable so the equipped model is easy to read.
	_preview_yaw += delta * 0.7
	_preview_model.rotation.y = _preview_yaw


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("escape_menu"):
		if _picker and _picker.visible:
			_hide_picker()
			get_viewport().set_input_as_handled()
			return
		if visible:
			_close_menu()
		else:
			_open_menu()
		get_viewport().set_input_as_handled()


func _open_menu() -> void:
	visible = true
	_sync_preview_viewport_size()
	_refresh_preview(_get_equipped_model_id())
	is_open.emit()  # BaseController reacts in _on_escape_menu_is_open()


func _close_menu() -> void:
	visible = false
	_hide_picker()
	$SettingsMenu._close_menu()
	is_not_open.emit()  # BaseController reacts in _on_escape_menu_is_not_open()


func _on_resume_pressed() -> void:
	click_sound.play()
	_close_menu()


func _on_settings_pressed() -> void:
	click_sound.play()
	$SettingsMenu._open_menu()


func _on_suicide_pressed() -> void:
	click_sound.play()
	_close_menu()
	# Same path as console "kill" with no name — local authority suicide.
	if player == null or not is_instance_valid(player):
		return
	if "is_dead" in player and bool(player.is_dead):
		return
	if player.has_method("take_damage"):
		var hp := int(player.HEALTH) if "HEALTH" in player else 9999
		player.take_damage(maxi(hp, 9999), -1, "suicide")
	elif Commands:
		Commands.cmd_kill("")


func _on_suicide_mouse_entered() -> void:
	hover_sound.play()


func _on_main_menu_pressed() -> void:
	click_sound.play()
	_close_menu()
	# Multiplayer: host ends the session for everyone; clients just leave.
	if NetworkManager and NetworkManager.is_online():
		NetworkManager.leave_to_main_menu()
		return
	# Singleplayer: unload map and return to menu.
	if MapLoader:
		MapLoader.return_to_main_menu()
	else:
		get_tree().change_scene_to_file("res://assets/menus/main_menu.tscn")


func _on_quit_pressed() -> void:
	click_sound.play()
	quit_delay.start()


func _on_quit_delay_timeout():
	get_tree().quit()


func _on_resume_mouse_entered():
	hover_sound.play()


func _on_settings_mouse_entered():
	hover_sound.play()


func _on_main_menu_mouse_entered():
	hover_sound.play()


func _on_quit_mouse_entered():
	hover_sound.play()


func _on_change_model_mouse_entered() -> void:
	hover_sound.play()


# ============================================================
#  MODEL PREVIEW (replaces white box content)
# ============================================================
func _setup_model_preview() -> void:
	if model_placeholder == null:
		return
	var ph_label := model_placeholder.get_node_or_null("PlaceholderLabel") as Label
	if ph_label:
		ph_label.visible = false

	var svc := SubViewportContainer.new()
	svc.name = "ModelPreview"
	svc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	svc.stretch = true
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	model_placeholder.add_child(svc)
	# Keep ChangeModel button above the viewport.
	if change_model_btn:
		model_placeholder.move_child(change_model_btn, model_placeholder.get_child_count() - 1)

	_preview_viewport = SubViewport.new()
	_preview_viewport.transparent_bg = true
	_preview_viewport.own_world_3d = true
	_preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var ph_size := model_placeholder.size
	if ph_size.x < 2.0 or ph_size.y < 2.0:
		ph_size = Vector2(426, 632)
	_preview_viewport.size = Vector2i(int(ph_size.x), int(ph_size.y))
	svc.add_child(_preview_viewport)

	var root := Node3D.new()
	root.name = "PreviewRoot"
	_preview_viewport.add_child(root)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35, 40, 0)
	light.light_energy = 1.1
	root.add_child(light)

	var fill := OmniLight3D.new()
	fill.position = Vector3(-1.2, 1.4, 1.5)
	fill.light_energy = 0.55
	root.add_child(fill)

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.05, 2.35)
	root.add_child(cam)
	# Must be in the tree before look_at / look_at_from_position.
	cam.look_at_from_position(cam.position, Vector3(0.0, 0.95, 0.0), Vector3.UP)

	# CharacterModel script for the same load path as the player.
	var cm_script: Script = load("res://scripts/character/character_model.gd") as Script
	_preview_model = Node3D.new()
	_preview_model.set_script(cm_script)
	_preview_model.name = "PreviewCharacter"
	if "target_height" in _preview_model:
		_preview_model.set("target_height", 2.0)
	if "enable_animations" in _preview_model:
		_preview_model.set("enable_animations", true)
	if "model_yaw_offset" in _preview_model:
		_preview_model.set("model_yaw_offset", 0.0)
	root.add_child(_preview_model)


func _refresh_preview(model_id: String) -> void:
	if _preview_model == null or model_id.strip_edges().is_empty():
		return
	if _preview_model.has_method("set_model"):
		_preview_model.call("set_model", model_id)
	if _preview_model.has_method("play_animation"):
		_preview_model.call("play_animation", "idle")
	_preview_yaw = 0.0



func _sync_preview_viewport_size() -> void:
	if _preview_viewport == null or model_placeholder == null:
		return
	var ph_size := model_placeholder.size
	if ph_size.x >= 2.0 and ph_size.y >= 2.0:
		_preview_viewport.size = Vector2i(int(ph_size.x), int(ph_size.y))


# ============================================================
#  MODEL PICKER (GMod-style 3D grid)
# ============================================================
func _setup_model_picker() -> void:
	_picker = Control.new()
	_picker.name = "ModelPicker"
	_picker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_picker.visible = false
	_picker.mouse_filter = Control.MOUSE_FILTER_STOP
	$Control.add_child(_picker)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.65)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_picker.add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(560, 680)
	panel.position = Vector2(-280, -340)
	_picker.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "SELECT MODEL"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_picker_status = Label.new()
	_picker_status.text = "Choose a model, then Apply."
	_picker_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_picker_status)

	_model_scroll = ScrollContainer.new()
	_model_scroll.custom_minimum_size = Vector2(520, 520)
	_model_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_model_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_model_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	vbox.add_child(_model_scroll)

	_model_grid = GridContainer.new()
	_model_grid.columns = 3
	_model_grid.add_theme_constant_override("h_separation", 10)
	_model_grid.add_theme_constant_override("v_separation", 10)
	_model_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_scroll.add_child(_model_grid)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 16)
	vbox.add_child(buttons)

	var cancel_btn := Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(140, 40)
	cancel_btn.pressed.connect(_on_picker_cancel)
	buttons.add_child(cancel_btn)

	var apply_btn := Button.new()
	apply_btn.text = "APPLY MODEL"
	apply_btn.custom_minimum_size = Vector2(180, 40)
	apply_btn.pressed.connect(_on_picker_apply)
	buttons.add_child(apply_btn)


func _on_change_model_pressed() -> void:
	click_sound.play()
	_show_picker()


func _model_display_name(model_id: String) -> String:
	## "Male/Character_01" / "res://.../Character_01.fbx" → "Character_01"
	var s := model_id.replace("\\", "/").strip_edges()
	var base := s.get_file()
	if base.is_empty():
		base = s
	return base.get_basename()


func _make_model_cell(model_id: String) -> PanelContainer:
	## One GMod-style tile: live 3D SubViewport + name label.
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(160, 200)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.set_meta("model_id", model_id)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.16, 0.95)
	style.border_color = Color(0.35, 0.35, 0.45, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var svc := SubViewportContainer.new()
	svc.custom_minimum_size = Vector2(148, 148)
	svc.stretch = true
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(svc)

	var sv := SubViewport.new()
	sv.size = Vector2i(148, 148)
	sv.transparent_bg = true
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	svc.add_child(sv)

	var root := Node3D.new()
	sv.add_child(root)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35, 40, 0)
	light.light_energy = 1.15
	root.add_child(light)

	var fill := OmniLight3D.new()
	fill.position = Vector3(-1.0, 1.2, 1.4)
	fill.light_energy = 0.5
	root.add_child(fill)

	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.0, 2.2)
	root.add_child(cam)
	cam.look_at_from_position(cam.position, Vector3(0.0, 0.9, 0.0), Vector3.UP)

	var cm_script: Script = load("res://scripts/character/character_model.gd") as Script
	var model := Node3D.new()
	model.set_script(cm_script)
	if "target_height" in model:
		model.set("target_height", 2.0)
	if "enable_animations" in model:
		model.set("enable_animations", false)
	if "model_yaw_offset" in model:
		model.set("model_yaw_offset", 0.0)
	root.add_child(model)
	# set_model needs the node inside the tree (global transforms for height fit).
	# Load after the cell is parented — see _show_picker.
	panel.set_meta("preview_model", model)

	var name_lbl := Label.new()
	name_lbl.text = _model_display_name(model_id)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	vbox.add_child(name_lbl)

	# Invisible button on top to catch clicks / double-clicks.
	var btn := Button.new()
	btn.flat = true
	btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.focus_mode = Control.FOCUS_NONE
	panel.add_child(btn)
	btn.pressed.connect(_on_picker_cell_pressed.bind(model_id))
	btn.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.double_click \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_on_picker_cell_pressed(model_id)
			_on_picker_apply()
	)

	return panel


func _set_cell_selected(panel: PanelContainer, selected: bool) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.16, 0.95)
	style.border_color = Color(0.45, 0.75, 1.0, 1.0) if selected else Color(0.35, 0.35, 0.45, 1.0)
	style.set_border_width_all(3 if selected else 2)
	style.set_corner_radius_all(6)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)


func _clear_picker_grid() -> void:
	_picker_cells.clear()
	if _model_grid == null:
		return
	for c in _model_grid.get_children():
		c.queue_free()


func _show_picker() -> void:
	if _picker == null or _model_grid == null:
		return
	_clear_picker_grid()
	var models: PackedStringArray = CharacterModel.list_available_models()
	if models.is_empty():
		models = PackedStringArray([DEFAULT_MODEL])
	var equipped := _get_equipped_model_id()
	_selected_model_id = equipped if not equipped.is_empty() else str(models[0])

	for id in models:
		var mid := str(id)
		var cell := _make_model_cell(mid)
		_model_grid.add_child(cell)
		_picker_cells.append({"id": mid, "panel": cell})
		if mid == _selected_model_id:
			_set_cell_selected(cell, true)
		# Load 3D model only after the cell is in the tree (avoids get_global_transform spam).
		var preview: Node3D = cell.get_meta("preview_model", null)
		if preview and preview.has_method("set_model"):
			preview.call_deferred("set_model", mid)

	_picker_status.text = "Selected: %s" % _model_display_name(_selected_model_id)
	_refresh_preview(_selected_model_id)
	_picker.visible = true


func _hide_picker() -> void:
	if _picker:
		_picker.visible = false
	_clear_picker_grid()
	# Restore equipped preview if apply was cancelled.
	if visible:
		_refresh_preview(_get_equipped_model_id())


func _on_picker_cell_pressed(model_id: String) -> void:
	_selected_model_id = model_id
	for cell in _picker_cells:
		if typeof(cell) != TYPE_DICTIONARY:
			continue
		var panel: PanelContainer = cell.get("panel")
		if is_instance_valid(panel):
			_set_cell_selected(panel, str(cell.get("id", "")) == model_id)
	_picker_status.text = "Selected: %s" % _model_display_name(model_id)
	_refresh_preview(model_id)


func _on_picker_cancel() -> void:
	click_sound.play()
	_hide_picker()


func _on_picker_apply() -> void:
	click_sound.play()
	if _selected_model_id.strip_edges().is_empty():
		_picker_status.text = "Select a model first."
		return
	_apply_model(_selected_model_id)
	_hide_picker()


func _apply_model(model_id: String) -> void:
	# Live player body (and multiplayer broadcast via set_character_model).
	if player and player.has_method("set_character_model"):
		player.call("set_character_model", model_id)
	elif player and "character_model_id" in player:
		player.set("character_model_id", model_id)
	_save_model_id(model_id)
	_refresh_preview(model_id)
	_picker_status.text = "Applied: %s" % _model_display_name(model_id)


func _get_equipped_model_id() -> String:
	if player and "character_model_id" in player:
		var id: String = str(player.get("character_model_id"))
		if not id.strip_edges().is_empty():
			return id
	return load_saved_model_id()


static func load_saved_model_id() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(PLAYER_CFG) == OK:
		var id := str(cfg.get_value("player", "model_id", DEFAULT_MODEL))
		if not id.strip_edges().is_empty():
			return id
	return DEFAULT_MODEL


func _save_model_id(model_id: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PLAYER_CFG)  # keep username / other keys
	cfg.set_value("player", "model_id", model_id)
	cfg.save(PLAYER_CFG)
