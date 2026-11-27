extends Control
## Host lobby: game / gamemode / map / max players + player list + Start.
## Hosting begins as soon as this menu opens (main menu "HOST GAME").

@onready var game_option: OptionButton = $LeftPanel/GameOption
@onready var gamemode_option: OptionButton = $LeftPanel/GamemodeOption
@onready var map_option: OptionButton = $LeftPanel/MapOption
@onready var max_players_spin: SpinBox = $LeftPanel/MaxPlayersSpin
@onready var port_spin: SpinBox = $LeftPanel/PortSpin
@onready var status_label: Label = $LeftPanel/StatusLabel
@onready var start_button: Button = $LeftPanel/StartButton
@onready var back_button: Button = $LeftPanel/BackButton
@onready var player_list: ItemList = $RightPanel/PlayerList
@onready var click_sound: AudioStreamPlayer = $Click
@onready var hover_sound: AudioStreamPlayer = $Hover

var _hosting := false
var _starting_host := false
var _kick_button: Button = null


func _ready() -> void:
	visible = false
	_populate_games()
	_populate_maps()
	max_players_spin.min_value = 2
	max_players_spin.max_value = 16
	max_players_spin.value = 8
	port_spin.min_value = 1024
	port_spin.max_value = 65535
	port_spin.value = NetworkManager.DEFAULT_PORT
	NetworkManager.lobby_players_changed.connect(_on_lobby_changed)
	_ensure_kick_button()
	if player_list:
		player_list.item_selected.connect(_on_player_list_item_selected)
		player_list.item_activated.connect(_on_player_list_item_activated)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("escape_menu"):
		_on_back_pressed()
		get_viewport().set_input_as_handled()


func open_menu() -> void:
	visible = true
	_populate_games()
	_populate_maps()
	_refresh_player_list()
	start_button.disabled = true
	# Main menu "HOST GAME" should already be hosting — start the server now.
	if _hosting and NetworkManager.is_host:
		status_label.text = "Hosting on port %d — share your Radmin IP" % int(port_spin.value)
		start_button.disabled = false
		_apply_selection_to_network()
		return
	await _start_hosting()


func close_menu() -> void:
	visible = false


func _start_hosting() -> void:
	if _starting_host:
		return
	_starting_host = true
	start_button.disabled = true
	status_label.text = "Starting host..."
	var port := int(port_spin.value)
	var max_pl := int(max_players_spin.value)
	var err: Error = await NetworkManager.host_game(port, max_pl)
	_starting_host = false
	if err != OK:
		status_label.text = "Failed to host (error %s) — press Back and try again" % err
		_hosting = false
		start_button.disabled = true
		return
	_hosting = true
	_apply_selection_to_network()
	status_label.text = "Hosting on port %d — share your Radmin IP" % port
	start_button.disabled = false
	_refresh_player_list()


func _populate_games() -> void:
	game_option.clear()
	for g in GameManager.get_games():
		game_option.add_item(str(g))
	if game_option.item_count > 0:
		game_option.select(0)
		_on_game_selected(0)


func _populate_maps() -> void:
	map_option.clear()
	var maps := MapLoader.get_map_list()
	for m in maps:
		map_option.add_item(m)
	if map_option.item_count > 0:
		map_option.select(0)


func _on_game_selected(idx: int) -> void:
	var game_name := game_option.get_item_text(idx)
	gamemode_option.clear()
	for gm in GameManager.get_gamemodes(game_name):
		gamemode_option.add_item(str(gm))
	if gamemode_option.item_count > 0:
		gamemode_option.select(0)
	_push_settings_if_hosting()


func _apply_selection_to_network() -> void:
	var game_name := ""
	var gamemode := ""
	var map_name := ""
	if game_option.selected >= 0:
		game_name = game_option.get_item_text(game_option.selected)
	if gamemode_option.selected >= 0:
		gamemode = gamemode_option.get_item_text(gamemode_option.selected)
	if map_option.selected >= 0:
		map_name = map_option.get_item_text(map_option.selected)
	NetworkManager.update_lobby_settings(game_name, gamemode, map_name, int(max_players_spin.value))


func _push_settings_if_hosting() -> void:
	if _hosting and NetworkManager.is_host:
		_apply_selection_to_network()


func _on_start_pressed() -> void:
	click_sound.play()
	if not NetworkManager.is_host:
		status_label.text = "Host failed to start — go Back and try again"
		return
	_apply_selection_to_network()
	if NetworkManager.selected_map.is_empty():
		status_label.text = "Select a map"
		return
	status_label.text = "Starting..."
	NetworkManager.start_game()


func _on_back_pressed() -> void:
	click_sound.play()
	if _hosting or NetworkManager.is_online():
		NetworkManager.close_connection()
		_hosting = false
	close_menu()
	var main := get_parent()
	if main and main.has_method("_show_main_buttons"):
		main._show_main_buttons()


func _on_lobby_changed(_players: Array) -> void:
	_refresh_player_list()


func _ensure_kick_button() -> void:
	# Same ItemList as lobby; kick acts on the selected row (Godot ItemList cannot embed buttons).
	if _kick_button and is_instance_valid(_kick_button):
		return
	var right := get_node_or_null("RightPanel") as VBoxContainer
	if right == null:
		return
	# Prefer scene node if present.
	_kick_button = right.get_node_or_null("KickButton") as Button
	if _kick_button == null:
		_kick_button = Button.new()
		_kick_button.name = "KickButton"
		right.add_child(_kick_button)
	_kick_button.text = "KICK SELECTED"
	_kick_button.disabled = true
	var title_font := load("res://assets/fonts/Remingtoned Type.ttf")
	if title_font:
		_kick_button.add_theme_font_override("font", title_font)
	_kick_button.add_theme_font_size_override("font_size", 22)
	_kick_button.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	_kick_button.add_theme_color_override("font_hover_color", Color(1, 0.45, 0.45, 1))
	_kick_button.add_theme_color_override("font_disabled_color", Color(0.55, 0.55, 0.55, 1))
	var btn_style = load("res://assets/styles/grey_bottom_line.tres")
	if btn_style:
		_kick_button.add_theme_stylebox_override("normal", btn_style)
		_kick_button.add_theme_stylebox_override("hover", btn_style)
		_kick_button.add_theme_stylebox_override("pressed", btn_style)
		_kick_button.add_theme_stylebox_override("disabled", btn_style)
	if not _kick_button.pressed.is_connected(_on_kick_selected_pressed):
		_kick_button.pressed.connect(_on_kick_selected_pressed)
	if not _kick_button.mouse_entered.is_connected(_on_any_hover):
		_kick_button.mouse_entered.connect(_on_any_hover)


func _refresh_player_list() -> void:
	if player_list == null:
		return
	_ensure_kick_button()
	player_list.clear()
	for p in NetworkManager.get_players_list():
		var is_host_player := bool(p.get("is_host", false))
		var pname := str(p.get("name", "?"))
		var label := "%s%s" % [pname, " (Host)" if is_host_player else ""]
		var idx := player_list.add_item(label)
		# Metadata: { "name": str, "is_host": bool }
		player_list.set_item_metadata(idx, {"name": pname, "is_host": is_host_player})
	_update_kick_button_state()


func _on_player_list_item_selected(_index: int) -> void:
	_update_kick_button_state()


func _on_player_list_item_activated(index: int) -> void:
	# Double-click / activate row → kick if allowed (list stays lobby-identical).
	_kick_index(index)


func _update_kick_button_state() -> void:
	if _kick_button == null or player_list == null:
		return
	var selected := player_list.get_selected_items()
	if selected.is_empty():
		_kick_button.disabled = true
		return
	var meta = player_list.get_item_metadata(selected[0])
	if typeof(meta) != TYPE_DICTIONARY:
		_kick_button.disabled = true
		return
	_kick_button.disabled = bool(meta.get("is_host", true)) or not NetworkManager.is_host


func _on_kick_selected_pressed() -> void:
	if player_list == null:
		return
	var selected := player_list.get_selected_items()
	if selected.is_empty():
		return
	_kick_index(selected[0])


func _kick_index(index: int) -> void:
	if click_sound:
		click_sound.play()
	if not NetworkManager.is_host:
		return
	if index < 0 or index >= player_list.item_count:
		return
	var meta = player_list.get_item_metadata(index)
	if typeof(meta) != TYPE_DICTIONARY:
		return
	if bool(meta.get("is_host", false)):
		status_label.text = "Cannot kick the host"
		return
	var player_name := str(meta.get("name", ""))
	if player_name.is_empty():
		return
	var err: Error = NetworkManager.kick_player_by_name(player_name)
	if err == OK:
		status_label.text = "Kicked %s" % player_name
	elif err == ERR_DOES_NOT_EXIST:
		status_label.text = "Player not found: %s" % player_name
	elif err == ERR_UNAUTHORIZED:
		status_label.text = "Cannot kick the host"
	else:
		status_label.text = "Kick failed"


func _on_game_option_item_selected(index: int) -> void:
	_on_game_selected(index)


func _on_gamemode_option_item_selected(_index: int) -> void:
	_push_settings_if_hosting()


func _on_map_option_item_selected(_index: int) -> void:
	_push_settings_if_hosting()


func _on_max_players_changed(_value: float) -> void:
	_push_settings_if_hosting()


func _on_port_changed(_value: float) -> void:
	# Port only applies on next host session; show a hint if already hosting
	if _hosting:
		status_label.text = "Port changes apply next time you host (Back, then Host Game again)"


func _on_any_hover() -> void:
	hover_sound.play()
