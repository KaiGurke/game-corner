extends Control
## Client-side lobby: read-only view of host settings + player list.

@onready var game_value: Label = $LeftPanel/GameValue
@onready var gamemode_value: Label = $LeftPanel/GamemodeValue
@onready var map_value: Label = $LeftPanel/MapValue
@onready var max_players_value: Label = $LeftPanel/MaxPlayersValue
@onready var status_label: Label = $LeftPanel/StatusLabel
@onready var leave_button: Button = $LeftPanel/LeaveButton
@onready var player_list: ItemList = $RightPanel/PlayerList
@onready var click_sound: AudioStreamPlayer = $Click
@onready var hover_sound: AudioStreamPlayer = $Hover


func _ready() -> void:
	visible = false
	NetworkManager.lobby_players_changed.connect(_on_lobby_changed)
	NetworkManager.lobby_settings_changed.connect(_on_settings_changed)
	NetworkManager.game_starting.connect(_on_game_starting)
	NetworkManager.server_disconnected.connect(_on_disconnected)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("escape_menu"):
		_on_leave_pressed()
		get_viewport().set_input_as_handled()


func open_menu() -> void:
	visible = true
	_refresh_all()
	status_label.text = "Connected — waiting for host to start"


func close_menu() -> void:
	visible = false


func _refresh_all() -> void:
	_refresh_settings()
	_refresh_player_list()


func _refresh_settings() -> void:
	var s := NetworkManager.get_lobby_settings()
	game_value.text = str(s.get("game", "—"))
	gamemode_value.text = str(s.get("gamemode", "—"))
	map_value.text = str(s.get("map", "—"))
	max_players_value.text = str(s.get("max_players", "—"))


func _refresh_player_list() -> void:
	player_list.clear()
	for p in NetworkManager.get_players_list():
		var tag := " (Host)" if p.get("is_host", false) else ""
		player_list.add_item("%s%s" % [p.get("name", "?"), tag])


func _on_lobby_changed(_players: Array) -> void:
	if visible:
		_refresh_player_list()


func _on_settings_changed(_settings: Dictionary) -> void:
	if visible:
		_refresh_settings()


func _on_game_starting(map_name: String, _game: String, _gm: String) -> void:
	status_label.text = "Game starting — loading %s..." % map_name


func _on_disconnected() -> void:
	if not visible:
		return
	status_label.text = "Disconnected from host"
	close_menu()
	var main := get_parent()
	if main and main.has_method("_show_main_buttons"):
		main._show_main_buttons()


func _on_leave_pressed() -> void:
	click_sound.play()
	NetworkManager.close_connection()
	close_menu()
	var main := get_parent()
	if main and main.has_method("_show_main_buttons"):
		main._show_main_buttons()


func _on_any_hover() -> void:
	hover_sound.play()
