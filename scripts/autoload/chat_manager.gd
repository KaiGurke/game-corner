extends Node
## Chat for host/lobby menus and in-game only — never on the bare main menu.
## Appearance: edit res://assets/ui/chat/chat_ui.tscn or ChatUI export vars.

const CHAT_UI_SCENE := preload("res://assets/ui/chat/chat_ui.tscn")
const MAX_HISTORY := 100

signal chat_opened
signal chat_closed
signal message_logged(sender: String, text: String, is_system: bool)

var _ui: CanvasLayer = null
var _history: Array = []
var _visible_allowed: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ui = CHAT_UI_SCENE.instantiate()
	add_child(_ui)
	_ui.message_submitted.connect(_on_ui_message_submitted)
	_ui.input_opened.connect(func(): chat_opened.emit())
	_ui.input_closed.connect(_on_ui_input_closed)
	_ui.visible = false
	call_deferred("_refresh_visibility")


func _process(_delta: float) -> void:
	var should := _should_show_chat()
	if should != _visible_allowed:
		_set_allowed(should)


func _should_show_chat() -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return false
	var path := str(scene.scene_file_path)

	# Main menu: only while Host or Lobby sub-menu is open
	if path.ends_with("main_menu.tscn") or scene.name == "MainMenu":
		var host := scene.get_node_or_null("HostMenu")
		if host and host.visible:
			return true
		var lobby := scene.get_node_or_null("LobbyMenu")
		if lobby and lobby.visible:
			return true
		return false

	# In a match (multiplayer flag or a loaded map)
	if NetworkManager and NetworkManager.is_in_game:
		return true
	if MapLoader and MapLoader.current_map != null and is_instance_valid(MapLoader.current_map):
		return true
	return false


func _set_allowed(allowed: bool) -> void:
	_visible_allowed = allowed
	if _ui == null:
		return
	if not allowed:
		if is_input_active():
			close_chat(false)
		_ui.visible = false
	else:
		_ui.visible = true


func _refresh_visibility() -> void:
	_set_allowed(_should_show_chat())


func _unhandled_input(event: InputEvent) -> void:
	if not _visible_allowed:
		return
	if event.is_action_pressed("chat"):
		if LimboConsole and LimboConsole.is_open():
			return
		if is_input_active():
			return
		open_chat()
		get_viewport().set_input_as_handled()
		return
	if is_input_active() and event.is_action_pressed("escape_menu"):
		close_chat()
		get_viewport().set_input_as_handled()


func is_input_active() -> bool:
	return _ui != null and _ui.has_method("is_input_active") and _ui.is_input_active()


func open_chat() -> void:
	if not _visible_allowed:
		return
	if _ui:
		_ui.visible = true
		# Always call open_input — it force-resets focus/editable even if state was stuck.
		_ui.open_input()


func close_chat(restore_mouse: bool = true) -> void:
	if _ui:
		_ui.close_input(restore_mouse)


func post_system(text: String) -> void:
	if NetworkManager and NetworkManager.is_online() and NetworkManager.is_host:
		rpc("_rpc_system_message", text)
	else:
		_add_message("SYSTEM", text, true)


@rpc("authority", "reliable", "call_local")
func _rpc_system_message(text: String) -> void:
	_add_message("SYSTEM", text, true)


func _on_ui_message_submitted(text: String) -> void:
	send_chat(text)


func _on_ui_input_closed() -> void:
	chat_closed.emit()


func send_chat(text: String) -> void:
	var cleaned := text.strip_edges()
	if cleaned.is_empty():
		return
	# Allow longer messages so quoted image URLs fit.
	if cleaned.length() > 500:
		cleaned = cleaned.substr(0, 500)
	var name := _local_display_name()
	if NetworkManager and NetworkManager.is_online():
		rpc("_rpc_chat_message", name, cleaned)
	else:
		_add_message(name, cleaned, false)


@rpc("any_peer", "reliable", "call_local")
func _rpc_chat_message(sender: String, text: String) -> void:
	var safe_sender := str(sender).strip_edges()
	if safe_sender.is_empty():
		safe_sender = "???"
	if safe_sender.length() > 24:
		safe_sender = safe_sender.substr(0, 24)
	var safe_text := str(text).strip_edges()
	if safe_text.is_empty():
		return
	if safe_text.length() > 500:
		safe_text = safe_text.substr(0, 500)
	_add_message(safe_sender, safe_text, false)


func get_history() -> Array:
	## Copy of recent messages for UI rebuild (open chat / late display).
	return _history.duplicate(true)


func _add_message(sender: String, text: String, is_system: bool) -> void:
	_history.append({"sender": sender, "text": text, "system": is_system})
	while _history.size() > MAX_HISTORY:
		_history.pop_front()
	if _ui and _ui.has_method("append_message"):
		_ui.append_message(sender, text, is_system)
	message_logged.emit(sender, text, is_system)


func _local_display_name() -> String:
	if NetworkManager and not NetworkManager.username.is_empty():
		return NetworkManager.username
	return "Player"


func blocks_gameplay() -> bool:
	if is_input_active():
		return true
	if LimboConsole and LimboConsole.is_open():
		return true
	return false
