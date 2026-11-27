extends Node
## Peer-to-peer multiplayer (ENet). Works over Radmin VPN / LAN.
## Host creates a server; clients connect via the host's VPN IP.

const DEFAULT_PORT := 7777
const MAX_PLAYERS_DEFAULT := 8
const CONFIG_PATH := "user://player.cfg"

signal lobby_players_changed(players: Array)
signal lobby_settings_changed(settings: Dictionary)
signal connection_succeeded()
signal connection_failed(reason: String)
signal server_disconnected()
signal game_starting(map_name: String, game: String, gamemode: String)
signal player_joined_late(peer_id: int, username: String)

## Username shown in lobby / name tags. Persisted.
var username: String = ""
## peer_id -> { "name": String, "ready": bool }
var lobby_players: Dictionary = {}
## Current session config (host sets these)
var selected_game: String = "Shooter"
var selected_gamemode: String = "Deathmatch"
var selected_map: String = "test_level"
var max_players: int = MAX_PLAYERS_DEFAULT
var is_host: bool = false
var is_in_game: bool = false
var current_port: int = DEFAULT_PORT

var _peer: ENetMultiplayerPeer = null
# Player instances live in PlayerManager autoload.
## Unix time when the current match map was started (host clock). Used for late-join audio.
var _game_start_time: float = 0.0
var _is_late_join: bool = false
var _late_join_elapsed: float = 0.0

## Map movers (PathFollow3D / AnimatableBody3D) — host sim, client lerp.
const WORLD_SYNC_RATE := 0.05
const WORLD_LERP_SPEED := 12.0
var _world_sync_nodes: Array = []
var _world_sync_index: Array = []
var _world_targets: Dictionary = {}
var _world_sync_timer: float = 0.0


func _ready() -> void:
	_load_or_create_username()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _load_or_create_username() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		username = str(cfg.get_value("player", "username", ""))
	if username.strip_edges().is_empty():
		username = "Player%d" % (randi() % 9000 + 1000)
		_save_username()


func set_username(new_name: String) -> void:
	var cleaned := new_name.strip_edges()
	if cleaned.is_empty():
		return
	if cleaned.length() > 24:
		cleaned = cleaned.substr(0, 24)
	username = cleaned
	_save_username()
	if multiplayer.multiplayer_peer != null and multiplayer.get_unique_id() in lobby_players:
		lobby_players[multiplayer.get_unique_id()]["name"] = username
		if is_host:
			_broadcast_lobby()
		else:
			rpc_id(1, "_rpc_update_name", username)


func _save_username() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value("player", "username", username)
	cfg.save(CONFIG_PATH)


func get_players_list() -> Array:
	var list: Array = []
	for id in lobby_players:
		list.append({
			"id": id,
			"name": lobby_players[id].get("name", "???"),
			"ready": lobby_players[id].get("ready", false),
			"is_host": id == 1
		})
	list.sort_custom(func(a, b): return a.id < b.id)
	return list


func get_lobby_settings() -> Dictionary:
	return {
		"game": selected_game,
		"gamemode": selected_gamemode,
		"map": selected_map,
		"max_players": max_players,
		"port": current_port,
		"is_in_game": is_in_game,
	}


# ---------------------------------------------------------------------------
# Host / Join
# ---------------------------------------------------------------------------

var _hosting_lock: bool = false


func host_game(port: int = DEFAULT_PORT, max_pl: int = MAX_PLAYERS_DEFAULT) -> Error:
	if _hosting_lock:
		return ERR_BUSY
	_hosting_lock = true
	# Fully tear down any previous peer before binding the port again (export is stricter).
	close_connection()
	# Give ENet a moment to release the socket — critical in exported builds.
	await get_tree().process_frame
	await get_tree().process_frame

	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, max_pl)
	if err != OK:
		_peer = null
		_hosting_lock = false
		if LimboConsole:
			LimboConsole.error("create_server failed: %s (port %d may still be in use)" % [err, port])
		return err

	multiplayer.multiplayer_peer = _peer
	# Wait until the server peer reports connected (peer id 1)
	var tries := 0
	while _peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED and tries < 30:
		await get_tree().process_frame
		tries += 1
	if _peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		multiplayer.multiplayer_peer = null
		_peer.close()
		_peer = null
		_hosting_lock = false
		return ERR_CANT_CREATE

	is_host = true
	is_in_game = false
	if PlayerManager:
		PlayerManager.set_map_not_ready()
	current_port = port
	max_players = max_pl
	lobby_players.clear()
	lobby_players[1] = {"name": username, "ready": true, "kills": 0, "deaths": 0, "assists": 0}
	lobby_players_changed.emit(get_players_list())
	# Local-only emit first; RPC after peer is stable
	lobby_settings_changed.emit(get_lobby_settings())
	_broadcast_settings()
	_hosting_lock = false
	if LimboConsole:
		LimboConsole.info("Hosting on port %d (max %d players)" % [port, max_pl])
	return OK


func join_game(address: String, port: int = DEFAULT_PORT) -> Error:
	close_connection()
	await get_tree().process_frame
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address.strip_edges(), port)
	if err != OK:
		_peer = null
		return err
	multiplayer.multiplayer_peer = _peer
	is_host = false
	is_in_game = false
	if PlayerManager:
		PlayerManager.set_map_not_ready()
	current_port = port
	lobby_players.clear()
	if LimboConsole:
		LimboConsole.info("Connecting to %s:%d ..." % [address, port])
	return OK


func close_connection() -> void:
	# Stop gameplay systems first so _process / RPCs cannot touch freed nodes
	is_in_game = false
	if PlayerManager:
		PlayerManager.set_map_not_ready()
	_is_late_join = false
	_late_join_elapsed = 0.0
	_game_start_time = 0.0
	_world_sync_nodes.clear()
	_world_sync_index.clear()
	_world_targets.clear()

	# Drop the peer before freeing networked nodes (avoids export crashes mid-RPC)
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	if _peer != null:
		# Extra close in case peer object is still holding the socket
		if _peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
			_peer.close()
		_peer = null

	is_host = false
	if PlayerManager: PlayerManager.despawn_all_players()
	lobby_players.clear()
	lobby_players_changed.emit([])


func is_online() -> bool:
	return multiplayer.multiplayer_peer != null \
		and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


## Host-only: disconnect a peer by lobby display name.
func kick_player_by_name(player_name: String) -> Error:
	if not is_host or not is_online():
		return ERR_UNAUTHORIZED
	var target := player_name.strip_edges().to_lower()
	if target.is_empty():
		return ERR_INVALID_PARAMETER
	var peer_id := -1
	for id in lobby_players:
		var n := str(lobby_players[id].get("name", "")).strip_edges().to_lower()
		if n == target:
			peer_id = int(id)
			break
	if peer_id < 0:
		return ERR_DOES_NOT_EXIST
	if peer_id == 1 or peer_id == multiplayer.get_unique_id():
		return ERR_UNAUTHORIZED
	# Notify everyone, then drop the peer
	if ChatManager:
		ChatManager.post_system("%s was kicked" % player_name.strip_edges())
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.disconnect_peer(peer_id, true)
	return OK


## Round-trip time in ms for a peer (0 for local/host self). -1 if unknown.
func get_peer_ping_ms(peer_id: int) -> int:
	if not is_online():
		return -1
	if peer_id == multiplayer.get_unique_id():
		return 0
	var mp := multiplayer.multiplayer_peer
	if mp is ENetMultiplayerPeer:
		var enet := mp as ENetMultiplayerPeer
		var peer: ENetPacketPeer = enet.get_peer(peer_id)
		if peer == null:
			return -1
		# RTT is in milliseconds
		return int(peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))
	return -1


func get_scoreboard_rows() -> Array:
	var rows: Array = []
	for id in lobby_players:
		var entry: Dictionary = lobby_players[id]
		rows.append({
			"id": int(id),
			"name": entry.get("name", "?"),
			"is_host": int(id) == 1,
			"ping": get_peer_ping_ms(int(id)),
			"kills": int(entry.get("kills", 0)),
			"deaths": int(entry.get("deaths", 0)),
			"assists": int(entry.get("assists", 0)),
		})
	rows.sort_custom(func(a, b): return int(a.id) < int(b.id))
	return rows


func get_scoreboard_title() -> String:
	var game := selected_game if not selected_game.is_empty() else "Game"
	var gm := selected_gamemode if not selected_gamemode.is_empty() else "Gamemode"
	var map := selected_map if not selected_map.is_empty() else "Map"
	if MapLoader and not MapLoader.current_map_name.is_empty():
		map = MapLoader.current_map_name
	return "%s | %s | %s" % [game, gm, map]


## Host-authoritative combat stats (call from gameplay when ready).
func add_player_stat(peer_id: int, stat: String, amount: int = 1) -> void:
	if not is_host:
		return
	if not lobby_players.has(peer_id):
		return
	if stat not in ["kills", "deaths", "assists"]:
		return
	lobby_players[peer_id][stat] = int(lobby_players[peer_id].get(stat, 0)) + amount
	_broadcast_lobby()


func get_spawn_transform_for(peer_id: int) -> Transform3D:
	return PlayerManager.get_spawn_transform_for(peer_id) if PlayerManager else Transform3D.IDENTITY


# ---------------------------------------------------------------------------
# Dev / cheat helpers (host + cheats — enforced by Commands)
# ---------------------------------------------------------------------------



func dev_set_health(peer_id: int, value: int) -> void:
	if is_online() and peer_id != multiplayer.get_unique_id():
		rpc_id(peer_id, "_rpc_dev_set_health", value)
		return
	var p := PlayerManager.get_player_node(peer_id)
	if p and p.has_method("dev_set_health"):
		p.dev_set_health(value)
	elif p and "HEALTH" in p:
		p.HEALTH = value
		if p.has_method("_update_health_hud"):
			p._update_health_hud()
		if p.has_method("_sync_health"):
			p._sync_health()


func dev_add_health(peer_id: int, amount: int) -> void:
	if is_online() and peer_id != multiplayer.get_unique_id():
		rpc_id(peer_id, "_rpc_dev_add_health", amount)
		return
	var p := PlayerManager.get_player_node(peer_id)
	if p and p.has_method("heal"):
		p.heal(amount)


func dev_add_damage(peer_id: int, amount: int) -> void:
	if is_online() and peer_id != multiplayer.get_unique_id():
		rpc_id(peer_id, "_rpc_dev_add_damage", amount)
		return
	var p := PlayerManager.get_player_node(peer_id)
	if p and p.has_method("take_damage"):
		p.take_damage(amount, -1, "dev")


func dev_kill(peer_id: int) -> void:
	if is_online() and peer_id != multiplayer.get_unique_id():
		rpc_id(peer_id, "_rpc_dev_kill")
		return
	var p := PlayerManager.get_player_node(peer_id)
	if p and p.has_method("take_damage"):
		var hp := int(p.HEALTH) if "HEALTH" in p else 100
		p.take_damage(maxi(hp, 9999), -1, "dev")


func dev_teleport_to_player(moving_id: int, target_id: int) -> bool:
	var target_node := PlayerManager.get_player_node(target_id)
	if target_node == null or not (target_node is Node3D):
		return false
	var target_pos: Vector3 = (target_node as Node3D).global_position + Vector3(0, 0.1, 0)
	if is_online() and moving_id != multiplayer.get_unique_id():
		rpc_id(moving_id, "_rpc_dev_teleport", target_pos)
		return true
	var mover := PlayerManager.get_player_node(moving_id)
	if mover and mover is Node3D:
		(mover as Node3D).global_position = target_pos
		if "velocity" in mover:
			mover.velocity = Vector3.ZERO
		return true
	return false


@rpc("any_peer", "reliable")
func _rpc_dev_set_health(value: int) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	dev_set_health(multiplayer.get_unique_id(), value)


@rpc("any_peer", "reliable")
func _rpc_dev_add_health(amount: int) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	dev_add_health(multiplayer.get_unique_id(), amount)


@rpc("any_peer", "reliable")
func _rpc_dev_add_damage(amount: int) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	dev_add_damage(multiplayer.get_unique_id(), amount)


@rpc("any_peer", "reliable")
func _rpc_dev_kill() -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	dev_kill(multiplayer.get_unique_id())


@rpc("any_peer", "reliable")
func _rpc_dev_teleport(pos: Vector3) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	var p := PlayerManager.get_player_node(multiplayer.get_unique_id())
	if p and p is Node3D:
		(p as Node3D).global_position = pos
		if "velocity" in p:
			p.velocity = Vector3.ZERO


## Victim reports death; host updates scoreboard.
func report_player_death(victim_id: int, attacker_id: int = -1, reason: String = "") -> void:
	if is_host:
		_apply_death_stats(victim_id, attacker_id, reason)
	else:
		rpc_id(1, "_rpc_report_death", victim_id, attacker_id, reason)


@rpc("any_peer", "reliable")
func _rpc_report_death(victim_id: int, attacker_id: int = -1, reason: String = "") -> void:
	if not is_host:
		return
	_apply_death_stats(victim_id, attacker_id, reason)


func _apply_death_stats(victim_id: int, attacker_id: int, reason: String) -> void:
	if lobby_players.has(victim_id):
		lobby_players[victim_id]["deaths"] = int(lobby_players[victim_id].get("deaths", 0)) + 1
	if attacker_id > 0 and attacker_id != victim_id and lobby_players.has(attacker_id):
		lobby_players[attacker_id]["kills"] = int(lobby_players[attacker_id].get("kills", 0)) + 1
	_broadcast_lobby()
	var vname := str(lobby_players.get(victim_id, {}).get("name", "Player"))
	var aname := ""
	if attacker_id > 0 and lobby_players.has(attacker_id):
		aname = str(lobby_players[attacker_id].get("name", "Player"))
	# Host broadcasts kill feed to every peer (including self)
	rpc("_rpc_kill_feed", vname, aname, reason)


@rpc("authority", "reliable", "call_local")
func _rpc_kill_feed(victim: String, attacker: String, reason: String) -> void:
	if KillFeed == null:
		return
	if reason == "fall":
		KillFeed.add_fall(victim)
	elif not attacker.is_empty():
		KillFeed.add_kill(attacker, victim)
	else:
		KillFeed.add_death(victim)


func report_player_respawn(peer_id: int) -> void:
	if not is_online():
		return
	rpc("_rpc_player_respawned", peer_id)


@rpc("any_peer", "reliable")
func _rpc_player_respawned(peer_id: int) -> void:
	var p = PlayerManager.get_player_node(peer_id) if PlayerManager else null
	if is_instance_valid(p) and p.has_method("apply_network_health"):
		var max_hp := 100
		if "MAX_HEALTH" in p:
			max_hp = int(p.MAX_HEALTH)
		p.apply_network_health(max_hp, false)


## Called from escape menu "Main Menu".
## Host: kicks everyone back to menu and closes the session.
## Client: leaves the session and returns to menu alone.
func leave_to_main_menu() -> void:
	if is_online() and is_host:
		# Clients only — no call_local (host stays until we return them to menu)
		rpc("_rpc_session_ended")
		await get_tree().create_timer(0.15).timeout
	close_connection()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if MapLoader:
		MapLoader.return_to_main_menu()
	else:
		get_tree().change_scene_to_file("res://assets/menus/main_menu.tscn")


## End multiplayer but keep the current scene (for host `map` command).
## Clients are sent back to the main menu; caller stays put.
func end_session_keep_scene() -> void:
	if not is_online():
		close_connection()
		return
	if is_host:
		# Best-effort notify; ignore failures if peer is already dying
		rpc("_rpc_session_ended")
		await get_tree().create_timer(0.2).timeout
	close_connection()
	# Allow queue_freed players / map-side net state to settle (export needs this)
	await get_tree().process_frame
	await get_tree().process_frame


@rpc("authority", "reliable")
func _rpc_session_ended() -> void:
	# Clients only (authority RPC, no call_local)
	close_connection()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if MapLoader:
		MapLoader.return_to_main_menu()
	else:
		get_tree().change_scene_to_file("res://assets/menus/main_menu.tscn")


# ---------------------------------------------------------------------------
# Lobby settings (host → clients)
# ---------------------------------------------------------------------------

func update_lobby_settings(game: String, gamemode: String, map_name: String, max_pl: int = -1) -> void:
	if not is_host:
		return
	selected_game = game
	selected_gamemode = gamemode
	selected_map = map_name
	if max_pl > 0:
		max_players = max_pl
	_broadcast_settings()


func _broadcast_settings() -> void:
	if not is_host:
		return
	var s := get_lobby_settings()
	rpc("_rpc_sync_settings", s)
	lobby_settings_changed.emit(s)


@rpc("authority", "reliable", "call_local")
func _rpc_sync_settings(settings: Dictionary) -> void:
	selected_game = str(settings.get("game", selected_game))
	selected_gamemode = str(settings.get("gamemode", selected_gamemode))
	selected_map = str(settings.get("map", selected_map))
	max_players = int(settings.get("max_players", max_players))
	current_port = int(settings.get("port", current_port))
	lobby_settings_changed.emit(get_lobby_settings())


# ---------------------------------------------------------------------------
# Lobby RPCs
# ---------------------------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	if not is_host:
		return
	if LimboConsole:
		LimboConsole.info("Peer connected: %d" % id)
	# Push current settings immediately so late/new clients see the lobby state
	rpc_id(id, "_rpc_sync_settings", get_lobby_settings())


func _on_peer_disconnected(id: int) -> void:
	var left_name := "Player"
	if lobby_players.has(id):
		left_name = str(lobby_players[id].get("name", "Player"))
		lobby_players.erase(id)
		lobby_players_changed.emit(get_players_list())
	if is_host:
		_broadcast_lobby()
	if is_in_game:
		if PlayerManager:
			PlayerManager.despawn_player(id)
	if is_host and ChatManager:
		ChatManager.post_system("%s left" % left_name)
	if LimboConsole:
		LimboConsole.info("Peer disconnected: %d" % id)


func _on_connected_to_server() -> void:
	rpc_id(1, "_rpc_register", username)
	connection_succeeded.emit()
	if LimboConsole:
		LimboConsole.info("Connected to server as %s" % username)


func _on_connection_failed() -> void:
	close_connection()
	connection_failed.emit("Connection failed")
	if LimboConsole:
		LimboConsole.error("Connection failed")


func _on_server_disconnected() -> void:
	var was_in_game := is_in_game
	close_connection()
	server_disconnected.emit()
	if LimboConsole:
		LimboConsole.warn("Server disconnected")
	# If we were in a match, drop back to the main menu
	if was_in_game:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if MapLoader:
			MapLoader.return_to_main_menu()
		else:
			get_tree().change_scene_to_file("res://assets/menus/main_menu.tscn")


@rpc("any_peer", "reliable")
func _rpc_register(player_name: String) -> void:
	if not is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	var cleaned := player_name.strip_edges()
	if cleaned.is_empty():
		cleaned = "Player%d" % sender
	lobby_players[sender] = {"name": cleaned, "ready": false, "kills": 0, "deaths": 0, "assists": 0}
	_broadcast_lobby()
	rpc_id(sender, "_rpc_sync_settings", get_lobby_settings())
	if is_host and ChatManager:
		ChatManager.post_system("%s joined" % cleaned)
	if is_in_game:
		# Send host-relative elapsed so client clocks don't need to match
		var elapsed := Time.get_unix_time_from_system() - _game_start_time
		rpc_id(sender, "_rpc_late_join", selected_map, selected_game, selected_gamemode, maxf(0.0, elapsed))
		# Cheats flag must match for the whole session
		if Commands:
			rpc_id(sender, "_rpc_sync_cheats", Commands.cheats_enabled)
		player_joined_late.emit(sender, cleaned)


@rpc("any_peer", "reliable")
func _rpc_update_name(player_name: String) -> void:
	if not is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	if lobby_players.has(sender):
		lobby_players[sender]["name"] = player_name.strip_edges()
		_broadcast_lobby()


func _broadcast_lobby() -> void:
	if not is_host:
		return
	var payload: Dictionary = {}
	for id in lobby_players:
		payload[id] = lobby_players[id]
	rpc("_rpc_sync_lobby", payload)
	lobby_players_changed.emit(get_players_list())


@rpc("authority", "reliable", "call_local")
func _rpc_sync_lobby(payload: Dictionary) -> void:
	lobby_players = payload
	lobby_players_changed.emit(get_players_list())
	# Mid-game join: spawn anyone we don't have yet once the map is ready
	if is_in_game and PlayerManager and PlayerManager.is_map_ready():
		for id in lobby_players:
			PlayerManager.spawn_player_local(int(id))
		if PlayerManager:
			PlayerManager.call_deferred("force_local_snapshot_broadcast")


# ---------------------------------------------------------------------------
# Start game / map load
# ---------------------------------------------------------------------------

func start_game() -> void:
	if not is_host:
		return
	if selected_map.strip_edges().is_empty():
		if LimboConsole:
			LimboConsole.error("No map selected")
		return
	is_in_game = true
	if PlayerManager:
		PlayerManager.set_map_not_ready()
	_game_start_time = Time.get_unix_time_from_system()
	_is_late_join = false
	_broadcast_settings()
	rpc("_rpc_start_game", selected_map, selected_game, selected_gamemode, _game_start_time)


@rpc("authority", "reliable", "call_local")
func _rpc_start_game(map_name: String, game: String, gamemode: String, start_time: float = 0.0) -> void:
	selected_map = map_name
	selected_game = game
	selected_gamemode = gamemode
	is_in_game = true
	if PlayerManager:
		PlayerManager.set_map_not_ready()
	_is_late_join = false
	_game_start_time = start_time if start_time > 0.0 else Time.get_unix_time_from_system()
	# Clear dict first; nodes may already be freed by scene change
	if PlayerManager:
		PlayerManager.despawn_all_players()
	_world_sync_index.clear()
	_world_targets.clear()
	game_starting.emit(map_name, game, gamemode)
	MapLoader.change_to_main_and_load(map_name)


@rpc("authority", "reliable")
func _rpc_late_join(map_name: String, game: String, gamemode: String, elapsed_sec: float = 0.0) -> void:
	selected_map = map_name
	selected_game = game
	selected_gamemode = gamemode
	is_in_game = true
	if PlayerManager:
		PlayerManager.set_map_not_ready()
	_is_late_join = true
	# Reconstruct start time from host-relative elapsed (avoids clock skew)
	_game_start_time = Time.get_unix_time_from_system() - maxf(0.0, elapsed_sec)
	_late_join_elapsed = maxf(0.0, elapsed_sec)
	game_starting.emit(map_name, game, gamemode)
	MapLoader.change_to_main_and_load(map_name)


# ---------------------------------------------------------------------------
# Map ready → spawn players locally on EVERY peer (fixes client no-move)
# ---------------------------------------------------------------------------

## Called by MapLoader once the map is in the tree on this peer.
func notify_map_ready() -> void:
	if not is_online() or not is_in_game:
		return
	if LimboConsole:
		LimboConsole.info("Map ready — spawning players (peer %d)" % multiplayer.get_unique_id())
	if _is_late_join:
		_silence_finished_autostart_audio(_late_join_elapsed)
		_is_late_join = false
	if PlayerManager:
		PlayerManager.notify_map_ready()
	call_deferred("_setup_world_sync")
	if not is_host:
		call_deferred("_request_world_snapshot")



## Stop non-looping autostart sounds that have already finished for late joiners.
func _silence_finished_autostart_audio(elapsed_sec: float) -> void:
	if elapsed_sec <= 0.05:
		return
	var roots: Array = []
	if MapLoader and MapLoader.current_map:
		roots.append(MapLoader.current_map)
	var scene := get_tree().current_scene
	if scene:
		roots.append(scene)
	var seen: Dictionary = {}
	for root in roots:
		if root == null:
			continue
		_silence_audio_recursive(root, elapsed_sec, seen)


func _silence_audio_recursive(node: Node, elapsed_sec: float, seen: Dictionary) -> void:
	if seen.has(node):
		return
	seen[node] = true
	# Standard Godot players
	if node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D:
		var player := node
		var stream: AudioStream = player.stream if "stream" in player else null
		if stream != null:
			var length := stream.get_length()
			var looping := false
			if stream is AudioStreamWAV:
				looping = (stream as AudioStreamWAV).loop_mode != AudioStreamWAV.LOOP_DISABLED
			elif stream is AudioStreamOggVorbis:
				looping = (stream as AudioStreamOggVorbis).loop
			elif stream is AudioStreamMP3:
				looping = (stream as AudioStreamMP3).loop
			# Autostart one-shots that would already be done: stop and prevent restart
			if not looping and length > 0.0 and elapsed_sec >= length:
				if player.has_method("stop"):
					player.stop()
				if "autoplay" in player:
					player.autoplay = false
				if "playing" in player and player.playing:
					player.playing = false
			elif not looping and length > 0.0 and elapsed_sec > 0.0 and player.has_method("seek"):
				# Still within clip: seek to current offset instead of restarting from 0
				if player.playing or ("autoplay" in player and player.autoplay):
					player.play(elapsed_sec)
	# ResonancePlayer (custom) — treat like a stream player if it exposes stream/play
	elif node.get_class() == "ResonancePlayer" or (node.has_method("play") and "stream" in node):
		var stream2 = node.get("stream") if node.get("stream") != null else null
		if stream2 is AudioStream:
			var length2: float = (stream2 as AudioStream).get_length()
			var looping2 := false
			if stream2 is AudioStreamOggVorbis:
				looping2 = (stream2 as AudioStreamOggVorbis).loop
			elif stream2 is AudioStreamWAV:
				looping2 = (stream2 as AudioStreamWAV).loop_mode != AudioStreamWAV.LOOP_DISABLED
			if not looping2 and length2 > 0.0 and elapsed_sec >= length2:
				if node.has_method("stop"):
					node.stop()
				if "autoplay" in node:
					node.autoplay = false
	for child in node.get_children():
		_silence_audio_recursive(child, elapsed_sec, seen)


## Player pose / anim / model / health / steps live on PlayerManager.
## Call PlayerManager.broadcast_* directly — no thin forwards here.


func rpc_sync_cheats(enabled: bool) -> void:
	if not is_host:
		return
	rpc("_rpc_sync_cheats", enabled)


@rpc("authority", "reliable")
func _rpc_sync_cheats(enabled: bool) -> void:
	# Clients only — host already applied locally in cmd_cheats
	if Commands and Commands.has_method("apply_cheats_from_host"):
		Commands.apply_cheats_from_host(enabled)
	elif Commands:
		Commands.cheats_enabled = enabled
		Commands.cheats_changed.emit(enabled)



func _setup_world_sync() -> void:
	_world_sync_nodes.clear()
	_world_sync_index.clear()
	_world_targets.clear()
	# Prefer the loaded map only so index order matches across peers
	var search_root: Node = MapLoader.current_map if MapLoader and MapLoader.current_map else get_tree().current_scene
	if search_root == null:
		search_root = get_tree().root

	var found: Array = []
	found.append_array(_find_nodes_of_type(search_root, "PathFollow3D"))
	found.append_array(_find_nodes_of_type(search_root, "AnimatableBody3D"))
	# Stable order by node path — critical so index N is the same object on every peer
	found.sort_custom(func(a, b): return str(a.get_path()) < str(b.get_path()))

	var seen: Dictionary = {}
	for node in found:
		if seen.has(node):
			continue
		seen[node] = true
		node.set_multiplayer_authority(1)
		node.set_meta("mp_host_only", true)
		_world_sync_nodes.append(node)
		_world_sync_index.append(node)

	if LimboConsole:
		LimboConsole.info("World sync: %d moving nodes indexed" % _world_sync_index.size())



func _request_world_snapshot() -> void:
	if is_host or not is_online():
		return
	rpc_id(1, "_rpc_request_world_snapshot")


@rpc("any_peer", "reliable")
func _rpc_request_world_snapshot() -> void:
	if not is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	_send_world_snapshot_to(sender)


func _send_world_snapshot_to(peer_id: int) -> void:
	if not is_host or _world_sync_index.is_empty():
		return
	for i in range(_world_sync_index.size()):
		var node = _world_sync_index[i]
		if not is_instance_valid(node) or not (node is Node3D):
			continue
		var n3 := node as Node3D
		if node is PathFollow3D:
			var pf := node as PathFollow3D
			rpc_id(peer_id, "_rpc_sync_mover_reliable", i, true, pf.progress, pf.progress_ratio, n3.global_position, n3.global_rotation)
		else:
			rpc_id(peer_id, "_rpc_sync_mover_reliable", i, false, 0.0, -1.0, n3.global_position, n3.global_rotation)


@rpc("authority", "reliable")
func _rpc_sync_mover_reliable(index: int, is_path_follow: bool, progress: float, ratio: float, pos: Vector3, rot: Vector3) -> void:
	# Same as unreliable apply, but guaranteed for late join
	_apply_mover_state(index, is_path_follow, progress, ratio, pos, rot, true)


func _apply_mover_state(index: int, is_path_follow: bool, progress: float, ratio: float, pos: Vector3, rot: Vector3, snap: bool = false) -> void:
	if is_host:
		return
	if index < 0 or index >= _world_sync_index.size():
		return
	_world_targets[index] = {
		"pos": pos,
		"rot": rot,
		"progress": progress,
		"ratio": ratio,
		"is_pf": is_path_follow,
	}
	if not snap:
		return
	# Immediate snap so late joiners aren't wrong for a second of lerping
	var node = _world_sync_index[index]
	if not is_instance_valid(node) or not (node is Node3D):
		return
	if is_path_follow and node is PathFollow3D:
		(node as PathFollow3D).progress = progress
	else:
		var n3 := node as Node3D
		n3.global_position = pos
		n3.global_rotation = rot


func _process(delta: float) -> void:
	if not is_in_game or not is_online() or _world_sync_index.is_empty():
		return

	if is_host:
		_world_sync_timer += delta
		if _world_sync_timer < WORLD_SYNC_RATE:
			return
		_world_sync_timer = 0.0
		for i in range(_world_sync_index.size()):
			var node = _world_sync_index[i]
			if not is_instance_valid(node) or not (node is Node3D):
				continue
			var n3 := node as Node3D
			if node is PathFollow3D:
				var pf := node as PathFollow3D
				rpc("_rpc_sync_mover", i, true, pf.progress, pf.progress_ratio, n3.global_position, n3.global_rotation)
			else:
				rpc("_rpc_sync_mover", i, false, 0.0, -1.0, n3.global_position, n3.global_rotation)
		return

	# Clients: smoothly lerp toward last networked targets (removes jitter)
	var t := clampf(delta * WORLD_LERP_SPEED, 0.0, 1.0)
	for i in _world_targets:
		var target: Dictionary = _world_targets[i]
		if i < 0 or i >= _world_sync_index.size():
			continue
		var node = _world_sync_index[i]
		if not is_instance_valid(node) or not (node is Node3D):
			continue
		# PathFollow owns its transform from progress — only lerp progress.
		# When the path loops (ratio 1→0), snap instead of lerping across the whole path.
		if target.get("is_pf", false) and node is PathFollow3D:
			var pf := node as PathFollow3D
			var goal := float(target["progress"])
			var cur := pf.progress
			var goal_ratio := float(target.get("ratio", -1.0))
			var cur_ratio := pf.progress_ratio
			var wrapped := false
			if goal_ratio >= 0.0:
				# Ratio went from near 1 back toward 0
				wrapped = cur_ratio > 0.7 and goal_ratio < 0.3
			else:
				wrapped = (cur - goal) > maxf(1.0, cur * 0.5)
			if wrapped:
				pf.progress = goal
			else:
				pf.progress = lerpf(cur, goal, t)
			continue
		var n3 := node as Node3D
		n3.global_position = n3.global_position.lerp(target["pos"], t)
		n3.global_rotation = Vector3(
			lerp_angle(n3.global_rotation.x, target["rot"].x, t),
			lerp_angle(n3.global_rotation.y, target["rot"].y, t),
			lerp_angle(n3.global_rotation.z, target["rot"].z, t)
		)


@rpc("authority", "unreliable_ordered")
func _rpc_sync_mover(index: int, is_path_follow: bool, progress: float, ratio: float, pos: Vector3, rot: Vector3) -> void:
	_apply_mover_state(index, is_path_follow, progress, ratio, pos, rot, false)


func _find_nodes_of_type(root: Node, type_name: String) -> Array:
	var result: Array = []
	if root == null:
		return result
	_find_nodes_of_type_recursive(root, type_name, result)
	return result


func _find_nodes_of_type_recursive(node: Node, type_name: String, out: Array) -> void:
	if node.get_class() == type_name:
		out.append(node)
	for child in node.get_children():
		_find_nodes_of_type_recursive(child, type_name, out)
