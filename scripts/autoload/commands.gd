extends Node

var cheats_enabled: bool = false
var noclip_enabled: bool = false

signal noclip_changed(enabled: bool)
signal cheats_changed(enabled: bool)



const BINDS_PATH := "user://keybinds.cfg"

# Default values for cvars (filled automatically on first access)
var _cvar_defaults: Dictionary = {}


func _ready() -> void:
	_load_binds()

	LimboConsole.register_command(cmd_cheats, "cheats", "Toggle cheats (required for noclip etc.)")
	LimboConsole.register_command(cmd_noclip, "noclip", "Toggle noclip / flying mode (requires cheats)")
	LimboConsole.register_command(cmd_bind, "bind", "Bind a key to an action: bind <key> <action>")
	LimboConsole.register_command(cmd_cvars, "cvars", "Change player variables: cvars <variable> <value> | cvars reset")
	LimboConsole.register_command(cmd_map, "map", "Change map: map <map_name>")
	LimboConsole.register_command(cmd_maplist, "maplist", "List all maps in the maps folder")
	LimboConsole.register_command(cmd_fov, "fov", "Change camera fov (Range 1 - 179): fov <value>")
	LimboConsole.register_command(cmd_sensitivity, "sensitivity", "Change mouse sensitivity: sensitivity <value>")
	LimboConsole.register_command(cmd_kick, "kick", "Kick a player from the session: kick <player_name>")
	LimboConsole.register_command(cmd_set_health, "set_health", "Cheats+Host: set_health <value> [player_name]")
	LimboConsole.register_command(cmd_add_health, "add_health", "Cheats+Host: add_health <value> [player_name]")
	LimboConsole.register_command(cmd_add_dmg, "add_dmg", "Cheats+Host: add_dmg <value> [player_name]")
	LimboConsole.register_command(cmd_kill, "kill", "kill = suicide; Host only: kill <player_name>")
	LimboConsole.register_command(cmd_tp, "tp", "Cheats+Host: tp <player> | tp <from> <to>")
	LimboConsole.register_command(cmd_tp, "teleport", "Cheats+Host: teleport <player> | teleport <from> <to>")
	LimboConsole.register_command(cmd_tphere, "tphere", "Cheats+Host: tphere <player_name>")
	LimboConsole.register_command(cmd_thirdperson, "thirdperson", "Toggle third-person camera (also F4)")
	LimboConsole.register_command(cmd_thirdperson, "tpview", "Alias: toggle third-person camera")
	LimboConsole.add_argument_autocomplete_source("map", 1, _map_autocomplete)
	LimboConsole.add_argument_autocomplete_source("kick", 1, _kick_autocomplete)
	LimboConsole.add_argument_autocomplete_source("set_health", 2, _player_autocomplete)
	LimboConsole.add_argument_autocomplete_source("add_health", 2, _player_autocomplete)
	LimboConsole.add_argument_autocomplete_source("add_dmg", 2, _player_autocomplete)
	LimboConsole.add_argument_autocomplete_source("kill", 1, _player_autocomplete)
	LimboConsole.add_argument_autocomplete_source("tp", 1, _player_autocomplete)
	LimboConsole.add_argument_autocomplete_source("tp", 2, _player_autocomplete)
	LimboConsole.add_argument_autocomplete_source("teleport", 1, _player_autocomplete)
	LimboConsole.add_argument_autocomplete_source("teleport", 2, _player_autocomplete)
	LimboConsole.add_argument_autocomplete_source("tphere", 1, _player_autocomplete)

# ============================================================
#  MAP / LEVEL LOADING
# ============================================================

func cmd_map(map_name: String) -> void:
	if map_name.strip_edges().is_empty():
		LimboConsole.warn("Usage: map <map_name>")
		cmd_maplist()
		return

	var clean_name := map_name.strip_edges()
	if not MapLoader.resolve_map_path(clean_name):
		LimboConsole.error("Map not found: %s" % clean_name)
		cmd_maplist()
		return

	# Leaving multiplayer before a unilateral map change (host stays in-game and loads solo)
	if NetworkManager and NetworkManager.is_online():
		if NetworkManager.is_host:
			LimboConsole.info("Host changing map — closing multiplayer session for all players")
		else:
			LimboConsole.info("Leaving multiplayer session to load map solo")
		await NetworkManager.end_session_keep_scene()
		# Export builds need extra frames for ENet + queue_free to finish
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().process_frame

	# Ensure we are on the main game scene before loading a map
	if not MapLoader.is_on_main_scene():
		LimboConsole.info("Switching to main scene, then loading: %s" % clean_name)
		MapLoader.change_to_main_and_load(clean_name)
		return

	# Deferred load avoids mid-physics free/load crashes in export
	await get_tree().process_frame
	if MapLoader.load_map(clean_name):
		LimboConsole.info("Loading map: %s" % MapLoader.current_map_name)
	else:
		LimboConsole.error("Failed to load map: %s" % clean_name)


func cmd_maplist() -> void:
	var maps: PackedStringArray = MapLoader.get_map_list()
	if maps.is_empty():
		LimboConsole.info("No maps found in res://game/maps/")
		return
	LimboConsole.info("Maps (%d):" % maps.size())
	for m in maps:
		var marker := " *" if m == MapLoader.current_map_name else ""
		LimboConsole.info("  %s%s" % [m, marker])


func cmd_kick(player_name: String) -> void:
	if player_name.strip_edges().is_empty():
		LimboConsole.warn("Usage: kick <player_name>")
		return
	if NetworkManager == null or not NetworkManager.is_online():
		LimboConsole.error("Not in a multiplayer session.")
		return
	if not NetworkManager.is_host:
		LimboConsole.warn("Only the host can kick players.")
		return
	var err: Error = NetworkManager.kick_player_by_name(player_name)
	if err == OK:
		LimboConsole.info("Kicked '%s'." % player_name.strip_edges())
	elif err == ERR_DOES_NOT_EXIST:
		LimboConsole.error("No player named '%s'." % player_name.strip_edges())
	elif err == ERR_UNAUTHORIZED:
		LimboConsole.error("Cannot kick the host.")
	else:
		LimboConsole.error("Kick failed (error %s)." % err)


func _kick_autocomplete() -> Array:
	var result: Array = []
	if NetworkManager == null:
		return result
	for p in NetworkManager.get_players_list():
		var n: String = str(p.get("name", ""))
		if not n.is_empty() and not bool(p.get("is_host", false)):
			result.append(n)
	return result


func _player_autocomplete() -> Array:
	var result: Array = []
	if NetworkManager == null:
		return result
	for p in NetworkManager.get_players_list():
		var n: String = str(p.get("name", ""))
		if not n.is_empty():
			result.append(n)
	return result


func _require_host_cheats() -> bool:
	if not cheats_enabled:
		LimboConsole.warn("Cheats are disabled. Enable with: cheats")
		return false
	if NetworkManager and NetworkManager.is_online() and not NetworkManager.is_host:
		LimboConsole.warn("Only the host can use this command.")
		return false
	return true


func _resolve_target_peer(player_name: String) -> int:
	# Empty name → self
	if player_name.strip_edges().is_empty():
		if multiplayer.multiplayer_peer:
			return multiplayer.get_unique_id()
		return 1
	if NetworkManager == null:
		return -1
	var target := player_name.strip_edges().to_lower()
	for p in NetworkManager.get_players_list():
		if str(p.get("name", "")).strip_edges().to_lower() == target:
			return int(p.get("id", -1))
	return -1


func cmd_set_health(value: float, player_name: String = "") -> void:
	if not _require_host_cheats():
		return
	var peer := _resolve_target_peer(player_name)
	if peer < 0:
		LimboConsole.error("Player not found: %s" % player_name)
		return
	NetworkManager.dev_set_health(peer, int(value))
	LimboConsole.info("Set health of peer %d to %d" % [peer, int(value)])


func cmd_add_health(value: float, player_name: String = "") -> void:
	if not _require_host_cheats():
		return
	var peer := _resolve_target_peer(player_name)
	if peer < 0:
		LimboConsole.error("Player not found: %s" % player_name)
		return
	NetworkManager.dev_add_health(peer, int(value))
	LimboConsole.info("Added %d health to peer %d" % [int(value), peer])


func cmd_add_dmg(value: float, player_name: String = "") -> void:
	if not _require_host_cheats():
		return
	var peer := _resolve_target_peer(player_name)
	if peer < 0:
		LimboConsole.error("Player not found: %s" % player_name)
		return
	NetworkManager.dev_add_damage(peer, int(value))
	LimboConsole.info("Damaged peer %d for %d" % [peer, int(value)])


func cmd_kill(player_name: String = "") -> void:
	# No cheats gate. Plain "kill" = suicide for anyone.
	# "kill <player_name>" is host-only (kill another player).
	var target_name := player_name.strip_edges()
	if target_name.is_empty():
		var self_id := multiplayer.get_unique_id() if multiplayer.multiplayer_peer else 1
		if NetworkManager:
			NetworkManager.dev_kill(self_id)
		else:
			var p = PlayerManager.get_player_node(self_id) if PlayerManager else null
			if p and p.has_method("take_damage"):
				var hp := int(p.HEALTH) if "HEALTH" in p else 9999
				p.take_damage(maxi(hp, 9999), -1, "suicide")
		LimboConsole.info("Suicided.")
		return
	if NetworkManager == null or not NetworkManager.is_online():
		LimboConsole.error("Not in a multiplayer session.")
		return
	if not NetworkManager.is_host:
		LimboConsole.warn("Only the host can kill other players. Use 'kill' with no name to suicide.")
		return
	var peer := _resolve_target_peer(target_name)
	if peer < 0:
		LimboConsole.error("Player not found: %s" % target_name)
		return
	NetworkManager.dev_kill(peer)
	LimboConsole.info("Killed '%s' (peer %d)" % [target_name, peer])


func cmd_tp(player_a: String = "", player_b: String = "") -> void:
	if not _require_host_cheats():
		return
	var a := player_a.strip_edges()
	var b := player_b.strip_edges()
	if a.is_empty():
		LimboConsole.warn("Usage: tp <player> | tp <from_player> <to_player>")
		return
	if b.is_empty():
		# Teleport self → player_a
		var target := _resolve_target_peer(a)
		if target < 0:
			LimboConsole.error("Player not found: %s" % a)
			return
		var self_id := multiplayer.get_unique_id() if multiplayer.multiplayer_peer else 1
		if not NetworkManager.dev_teleport_to_player(self_id, target):
			LimboConsole.error("Teleport failed")
			return
		LimboConsole.info("Teleported you to %s" % a)
	else:
		var from_id := _resolve_target_peer(a)
		var to_id := _resolve_target_peer(b)
		if from_id < 0:
			LimboConsole.error("Player not found: %s" % a)
			return
		if to_id < 0:
			LimboConsole.error("Player not found: %s" % b)
			return
		if not NetworkManager.dev_teleport_to_player(from_id, to_id):
			LimboConsole.error("Teleport failed")
			return
		LimboConsole.info("Teleported %s to %s" % [a, b])


func cmd_tphere(player_name: String = "") -> void:
	if not _require_host_cheats():
		return
	if player_name.strip_edges().is_empty():
		LimboConsole.warn("Usage: tphere <player_name>")
		return
	var target := _resolve_target_peer(player_name)
	if target < 0:
		LimboConsole.error("Player not found: %s" % player_name)
		return
	var self_id := multiplayer.get_unique_id() if multiplayer.multiplayer_peer else 1
	if not NetworkManager.dev_teleport_to_player(target, self_id):
		LimboConsole.error("Teleport failed")
		return
	LimboConsole.info("Teleported %s to you" % player_name.strip_edges())


func cmd_thirdperson() -> void:
	var player := _get_local_player()
	if player == null:
		LimboConsole.error("No local player.")
		return
	if player.has_method("toggle_third_person"):
		player.toggle_third_person()
		var on: bool = bool(player.get("third_person"))
		LimboConsole.info("Third person: %s" % ("ON" if on else "OFF"))
	else:
		LimboConsole.error("Player does not support third person.")


func _get_local_player() -> Node:
	for n in get_tree().get_nodes_in_group("player"):
		if n.get("is_local_player") == true:
			return n
	# Offline solo fallback
	for n in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(n):
			return n
	return null


func _map_autocomplete() -> Array:
	var result: Array = []
	for m in MapLoader.get_map_list():
		result.append(m)
	return result

# ============================================================
#  CHEATS
# ============================================================
func cmd_cheats() -> void:
	# Multiplayer: only the host may toggle cheats (synced to all peers)
	if NetworkManager and NetworkManager.is_online() and not NetworkManager.is_host:
		LimboConsole.warn("Only the host can toggle cheats in multiplayer.")
		return

	_set_cheats(not cheats_enabled)

	if NetworkManager and NetworkManager.is_online() and NetworkManager.is_host:
		NetworkManager.rpc_sync_cheats(cheats_enabled)


func _set_cheats(enabled: bool) -> void:
	cheats_enabled = enabled
	cheats_changed.emit(cheats_enabled)
	if cheats_enabled:
		LimboConsole.info("cheats ON")
	else:
		if noclip_enabled:
			noclip_enabled = false
			noclip_changed.emit(false)
		LimboConsole.info("cheats OFF")


## Applied on clients when host toggles cheats
func apply_cheats_from_host(enabled: bool) -> void:
	_set_cheats(enabled)


func cmd_noclip() -> void:
	if not cheats_enabled:
		LimboConsole.warn("Cheats are disabled. Type 'cheats' first.")
		return

	noclip_enabled = not noclip_enabled
	noclip_changed.emit(noclip_enabled)

	if noclip_enabled:
		LimboConsole.info("noclip ON")
	else:
		LimboConsole.info("noclip OFF")


# ============================================================
#  CVARS
# ============================================================
func cmd_cvars(variable: String = "", value: String = "") -> void:
	var player := _get_player()
	if player == null:
		LimboConsole.error("No player found.")
		return

	# Store defaults the first time we touch the player
	if _cvar_defaults.is_empty():
		_store_defaults(player)

	# cvars reset
	if variable.to_lower() == "reset":
		for key in _cvar_defaults:
			player.set(key, _cvar_defaults[key])
		if player.has_method("apply_height_cvars"):
			player.apply_height_cvars()
		LimboConsole.info("All cvars reset to default.")
		return

	# cvars (list all)
	if variable.is_empty():
		LimboConsole.info("--- Player CVars ---")
		for key in _cvar_defaults:
			LimboConsole.info("%s = %s" % [key, str(player.get(key))])
		return

	# cvars <variable>  (show current value)
	if value.is_empty():
		if not _cvar_defaults.has(variable):
			LimboConsole.error("Unknown cvar: %s" % variable)
			return
		LimboConsole.info("%s = %s" % [variable, str(player.get(variable))])
		return

	# cvars <variable> <value>
	if not _cvar_defaults.has(variable):
		LimboConsole.error("Unknown cvar: %s" % variable)
		return

	var current = player.get(variable)
	var new_value = _parse_value(value, current)

	if new_value == null:
		LimboConsole.error("Could not parse value '%s' for %s" % [value, variable])
		return

	player.set(variable, new_value)
	# Height-related cvars should also refit the visible model + capsule
	if variable in ["STAND_HEIGHT", "CROUCH_HEIGHT", "STAND_EYE_HEIGHT", "CROUCH_EYE_HEIGHT", "CROUCH_MODEL_DROP"]:
		if player.has_method("apply_height_cvars"):
			player.apply_height_cvars()
	LimboConsole.info("%s set to %s" % [variable, str(new_value)])

func _get_player() -> CharacterBody3D:
	# Try common ways to find the player
	var tree := get_tree()
	if tree == null:
		return null

	# 1. Group "player"
	var players := tree.get_nodes_in_group("player")
	if not players.is_empty() and players[0] is CharacterBody3D:
		return players[0]

	# 2. First CharacterBody3D that has the script
	for node in tree.get_nodes_in_group(""):  # fallback search
		pass

	# 3. Search the whole tree
	return _find_player(tree.root)


func _find_player(node: Node) -> CharacterBody3D:
	if node is CharacterBody3D and node.get_script() != null:
		# Prefer nodes that look like the controller
		if node.has_method("_state_noclip") or node.get("MAX_SPEED") != null:
			return node

	for child in node.get_children():
		var result := _find_player(child)
		if result:
			return result
	return null


func _store_defaults(player: CharacterBody3D) -> void:
	# Only store exported numeric / bool properties that make sense as cvars
	var property_list := player.get_property_list()
	for prop in property_list:
		var name: String = prop.name
		# Skip built-ins and private vars
		if name.begins_with("_") or name in ["script", "owner", "scene_file_path"]:
			continue
		# Only take common movement-related types
		var value = player.get(name)
		if typeof(value) in [TYPE_FLOAT, TYPE_INT, TYPE_BOOL]:
			_cvar_defaults[name] = value


func _parse_value(text: String, current_value) -> Variant:
	match typeof(current_value):
		TYPE_BOOL:
			text = text.to_lower()
			if text in ["1", "true", "on", "yes"]:
				return true
			if text in ["0", "false", "off", "no"]:
				return false
			return null
		TYPE_INT:
			if text.is_valid_int():
				return text.to_int()
			return null
		TYPE_FLOAT:
			if text.is_valid_float():
				return text.to_float()
			return null
	return null

func cmd_fov(value: float): # changes the fov of the current player (fov range 1-179)
	var player := _get_player()
	if player == null:
		LimboConsole.error("No player found.")
		return
	player.FOV = value
	player._update_fov()


# ============================================================
#  BIND
# ============================================================
func cmd_sensitivity(value: float): # changes the mouse sensitivity
	var player := _get_player()
	if player == null:
		LimboConsole.error("No player found.")
		return
		
	player.SENSITIVITY = value

func cmd_bind(key: String, action: String) -> void:
	key = key.strip_edges().to_lower()
	action = action.strip_edges()

	if action.is_empty():
		LimboConsole.error("Usage: bind <key> <action>")
		return

	if action == "limbo_console_toggle":
		LimboConsole.error("Cannot rebind the console toggle key.")
		return

	if not InputMap.has_action(action):
		LimboConsole.error("Action '%s' does not exist." % action)
		return

	var keycode := _string_to_keycode(key)
	if keycode == KEY_NONE:
		LimboConsole.error("Unknown key: '%s'" % key)
		return

	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			InputMap.action_erase_event(action, event)

	var new_event := InputEventKey.new()
	new_event.physical_keycode = keycode
	InputMap.action_add_event(action, new_event)

	_save_binds()
	LimboConsole.info("Bound '%s' → %s" % [key.to_upper(), action])


func _string_to_keycode(key: String) -> Key:
	key = key.to_lower()

	if key.length() == 1:
		var ch := key.unicode_at(0)
		if ch >= 97 and ch <= 122:
			return (KEY_A + (ch - 97)) as Key
		if ch >= 48 and ch <= 57:
			return (KEY_0 + (ch - 48)) as Key

	match key:
		"space": return KEY_SPACE
		"enter", "return": return KEY_ENTER
		"escape", "esc": return KEY_ESCAPE
		"tab": return KEY_TAB
		"backspace": return KEY_BACKSPACE
		"shift": return KEY_SHIFT
		"ctrl", "control": return KEY_CTRL
		"alt": return KEY_ALT
		"up": return KEY_UP
		"down": return KEY_DOWN
		"left": return KEY_LEFT
		"right": return KEY_RIGHT
		"insert": return KEY_INSERT
		"delete", "del": return KEY_DELETE
		"home": return KEY_HOME
		"end": return KEY_END
		"pageup", "pgup": return KEY_PAGEUP
		"pagedown", "pgdn": return KEY_PAGEDOWN
		"f1": return KEY_F1
		"f2": return KEY_F2
		"f3": return KEY_F3
		"f4": return KEY_F4
		"f5": return KEY_F5
		"f6": return KEY_F6
		"f7": return KEY_F7
		"f8": return KEY_F8
		"f9": return KEY_F9
		"f10": return KEY_F10
		"f11": return KEY_F11
		"f12": return KEY_F12
		"minus", "-": return KEY_MINUS
		"equal", "=": return KEY_EQUAL
		"comma", ",": return KEY_COMMA
		"period", ".": return KEY_PERIOD
		"slash", "/": return KEY_SLASH
		"quoteleft", "`", "tilde": return KEY_QUOTELEFT

	return KEY_NONE


func _save_binds() -> void:
	var config := ConfigFile.new()
	for action in InputMap.get_actions():
		if str(action).begins_with("ui_") or action == "limbo_console_toggle":
			continue
		var keys: Array = []
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				keys.append(event.physical_keycode)
		if not keys.is_empty():
			config.set_value("binds", str(action), keys)
	config.save(BINDS_PATH)


func _load_binds() -> void:
	var config := ConfigFile.new()
	if config.load(BINDS_PATH) != OK:
		return
	if not config.has_section("binds"):
		return

	for action in config.get_section_keys("binds"):
		if action == "limbo_console_toggle":
			continue
		if not InputMap.has_action(action):
			continue

		var keys: Array = config.get_value("binds", action, [])
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				InputMap.action_erase_event(action, event)
		for keycode in keys:
			var event := InputEventKey.new()
			event.physical_keycode = keycode
			InputMap.action_add_event(action, event)
