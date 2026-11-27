extends Node
## Owns in-game player instances and their multiplayer sync (pose / anim / model / death).
## NetworkManager keeps lobby + connection; this handles the world players.

const PLAYER_SCENE := preload("res://controllers/base_controller.tscn")

## peer_id -> CharacterBody3D
var _spawned_players: Dictionary = {}
var _map_ready: bool = false
var _pending_spawn_ids: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_map_ready() -> bool:
	return _map_ready


func get_spawned_players() -> Dictionary:
	return _spawned_players


func get_player_node(peer_id: int) -> Node:
	if _spawned_players.has(peer_id) and is_instance_valid(_spawned_players[peer_id]):
		return _spawned_players[peer_id]
	return null


func get_spawn_transform_for(peer_id: int) -> Transform3D:
	return _pick_spawn_transform_for(peer_id)


func clear_session_state() -> void:
	_map_ready = false
	_pending_spawn_ids.clear()
	despawn_all_players()


func set_map_not_ready() -> void:
	_map_ready = false
	_pending_spawn_ids.clear()


func notify_map_ready() -> void:
	_map_ready = true
	# Spawn everyone already known in the lobby + deferred pending.
	if NetworkManager:
		for id in NetworkManager.lobby_players.keys():
			spawn_player_local(int(id))
	for id in _pending_spawn_ids:
		spawn_player_local(int(id))
	_pending_spawn_ids.clear()
	call_deferred("force_local_snapshot_broadcast")


func spawn_player_local(peer_id: int) -> void:
	if _spawned_players.has(peer_id) and is_instance_valid(_spawned_players[peer_id]):
		return
	if not _map_ready:
		if peer_id not in _pending_spawn_ids:
			_pending_spawn_ids.append(peer_id)
		return

	_remove_map_auto_players()

	var spawn_xform := _pick_spawn_transform_for(peer_id)
	var player: CharacterBody3D = PLAYER_SCENE.instantiate()
	player.name = "Player_%d" % peer_id

	var my_id := multiplayer.get_unique_id() if multiplayer.multiplayer_peer else 1
	var is_local := peer_id == my_id
	# MUST set before add_child so _ready does not treat remote puppets as local.
	if "is_local_player" in player:
		player.set("is_local_player", is_local)

	var root := get_tree().current_scene
	if root == null:
		root = get_tree().root
	var players_root := root.get_node_or_null("Players")
	if players_root == null:
		players_root = Node3D.new()
		players_root.name = "Players"
		root.add_child(players_root, true)
	players_root.add_child(player, true)

	player.set_multiplayer_authority(peer_id)

	player.global_position = spawn_xform.origin
	player.rotation = Vector3.ZERO
	var yaw := spawn_xform.basis.get_euler().y
	if player.has_node("Head"):
		player.get_node("Head").rotation.y = yaw

	if player.has_method("set_local_player"):
		player.set_local_player(is_local)

	if player.has_node("Head/Camera3D"):
		(player.get_node("Head/Camera3D") as Camera3D).current = is_local

	_spawned_players[peer_id] = player

	if is_local:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		if LimboConsole:
			LimboConsole.info("Local player spawned (authority=%d)" % peer_id)
		# Push appearance + anim so remotes don't stay on default T-pose / wrong model.
		call_deferred("_broadcast_local_snapshot")


func despawn_player(peer_id: int) -> void:
	if not _spawned_players.has(peer_id):
		return
	var p = _spawned_players[peer_id]
	_spawned_players.erase(peer_id)
	if is_instance_valid(p):
		if p.get_parent():
			p.get_parent().remove_child(p)
		p.queue_free()


func despawn_all_players() -> void:
	var ids := _spawned_players.keys()
	for id in ids:
		despawn_player(id)
	_spawned_players.clear()


func force_local_snapshot_broadcast() -> void:
	_broadcast_local_snapshot()
	force_local_pose_broadcast()


func force_local_pose_broadcast() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	var my_id := multiplayer.get_unique_id()
	if not _spawned_players.has(my_id):
		return
	var p = _spawned_players[my_id]
	if is_instance_valid(p) and p.has_method("_send_network_pose"):
		p._send_network_pose()


func _broadcast_local_snapshot() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	var my_id := multiplayer.get_unique_id()
	if not _spawned_players.has(my_id):
		return
	var p = _spawned_players[my_id]
	if not is_instance_valid(p):
		return
	# Model
	var model_id := "Male/Character_01"
	if "character_model_id" in p:
		model_id = str(p.get("character_model_id"))
	broadcast_player_model(my_id, model_id)
	# Anim state (prefer public helper so private fields are not required)
	var state_id := 0
	if p.has_method("get_anim_state_id"):
		state_id = int(p.get_anim_state_id())
	broadcast_player_anim(my_id, state_id, 1.0)
	# Health / alive
	var hp := 100
	var dead := false
	if "HEALTH" in p:
		hp = int(p.HEALTH)
	if "is_dead" in p:
		dead = bool(p.is_dead)
	broadcast_player_health(my_id, hp, dead)
	force_local_pose_broadcast()


# ---------------------------------------------------------------------------
# Broadcasts + RPCs
# ---------------------------------------------------------------------------
func broadcast_player_pose(peer_id: int, pos: Vector3, head_yaw: float, cam_pitch: float, crouch: float = 0.0) -> void:
	if not _can_broadcast():
		return
	rpc("_rpc_player_pose", peer_id, pos, head_yaw, cam_pitch, crouch)


@rpc("any_peer", "unreliable_ordered")
func _rpc_player_pose(peer_id: int, pos: Vector3, head_yaw: float, cam_pitch: float, crouch: float = 0.0) -> void:
	if not _rpc_sender_ok(peer_id):
		return
	var player = get_player_node(peer_id)
	if player and player.has_method("apply_network_pose"):
		player.apply_network_pose(pos, head_yaw, cam_pitch, crouch)


func broadcast_player_model(peer_id: int, model_id: String) -> void:
	if not _can_broadcast():
		return
	rpc("_rpc_player_model", peer_id, model_id)


@rpc("any_peer", "reliable")
func _rpc_player_model(peer_id: int, model_id: String) -> void:
	if not _rpc_sender_ok(peer_id):
		return
	var player = get_player_node(peer_id)
	if player and player.has_method("apply_network_model"):
		player.apply_network_model(model_id)


func broadcast_player_anim(peer_id: int, state_id: int, speed_scale: float = 1.0) -> void:
	if not _can_broadcast():
		return
	rpc("_rpc_player_anim", peer_id, state_id, speed_scale)


@rpc("any_peer", "reliable")
func _rpc_player_anim(peer_id: int, state_id: int, speed_scale: float = 1.0) -> void:
	if not _rpc_sender_ok(peer_id):
		return
	# Authority already plays locally
	if peer_id == multiplayer.get_unique_id():
		return
	var player = get_player_node(peer_id)
	if player and player.has_method("apply_network_anim"):
		player.apply_network_anim(state_id, speed_scale)


func broadcast_player_health(peer_id: int, hp: int, dead: bool) -> void:
	if not _can_broadcast():
		return
	rpc("_rpc_player_health", peer_id, hp, dead)


@rpc("any_peer", "reliable")
func _rpc_player_health(peer_id: int, hp: int, dead: bool) -> void:
	if not _rpc_sender_ok(peer_id):
		return
	var player = get_player_node(peer_id)
	if player and player.has_method("apply_network_health"):
		player.apply_network_health(hp, dead)


## Reliable death visual with impulse so remotes start the same ragdoll kick.
func broadcast_player_death_visual(peer_id: int, impulse: Vector3) -> void:
	if not _can_broadcast():
		return
	rpc("_rpc_player_death_visual", peer_id, impulse)


@rpc("any_peer", "reliable")
func _rpc_player_death_visual(peer_id: int, impulse: Vector3) -> void:
	if not _rpc_sender_ok(peer_id):
		return
	if peer_id == multiplayer.get_unique_id():
		return
	var player = get_player_node(peer_id)
	if player == null:
		return
	if "is_dead" in player:
		player.is_dead = true
	if "HEALTH" in player:
		player.HEALTH = 0
	# Always drive ragdoll from death visual (carries the impulse). Health RPC
	# must not start a zero-impulse ragdoll first or the kick is dropped.
	if player.has_method("_start_ragdoll_visual"):
		player._start_ragdoll_visual(impulse)
	elif player.has_method("apply_network_health"):
		player.apply_network_health(0, true)
		if player.has_method("_start_ragdoll_visual"):
			player._start_ragdoll_visual(impulse)


func broadcast_step_sound(peer_id: int, kind: String, intensity: float = 0.0) -> void:
	if not _can_broadcast():
		return
	rpc("_rpc_step_sound", peer_id, kind, intensity)


func broadcast_footstep(peer_id: int) -> void:
	broadcast_step_sound(peer_id, "walk", 0.35)


@rpc("any_peer", "unreliable")
func _rpc_step_sound(peer_id: int, kind: String, intensity: float = 0.0) -> void:
	if not _rpc_sender_ok(peer_id):
		return
	if peer_id == multiplayer.get_unique_id():
		return
	var player = get_player_node(peer_id)
	if player == null:
		return
	if player.has_method("play_network_step_sound"):
		player.play_network_step_sound(kind, intensity)
	elif player.has_method("play_network_footstep"):
		player.play_network_footstep()


func _can_broadcast() -> bool:
	if NetworkManager == null:
		return false
	if not NetworkManager.is_online() or not NetworkManager.is_in_game:
		return false
	return multiplayer.multiplayer_peer != null


func _rpc_sender_ok(peer_id: int) -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	var sender := multiplayer.get_remote_sender_id()
	# sender 0 = local call
	return sender == peer_id or sender == 0


func _remove_map_auto_players() -> void:
	var existing := get_tree().get_nodes_in_group("player")
	for n in existing:
		if n in _spawned_players.values():
			continue
		if is_instance_valid(n):
			n.queue_free()


func _pick_spawn_transform_for(peer_id: int) -> Transform3D:
	var starts: Array = []
	starts.append_array(get_tree().get_nodes_in_group("info_player_start"))
	if starts.is_empty():
		starts.append_array(get_tree().get_nodes_in_group("spawn"))
	if starts.is_empty():
		starts.append_array(get_tree().get_nodes_in_group("worldspawn_area"))
	if starts.is_empty():
		return Transform3D(Basis(), Vector3(0, 2, 0))
	# Deterministic pick across peers
	starts.sort_custom(func(a, b): return str(a.get_path()) < str(b.get_path()))
	var idx := int(peer_id) % starts.size()
	var s = starts[idx]
	if s is Node3D:
		if s.has_method("get_spawn_transform"):
			return s.get_spawn_transform()
		return (s as Node3D).global_transform
	return Transform3D(Basis(), Vector3(0, 2, 0))
