class_name MapManager
extends Node
## Autoloaded as MapLoader. Loads maps from res://game/maps/ and places the player at a spawn.

const MAPS_DIR := "res://game/maps/"
const MAP_EXTENSIONS := [".res", ".tscn", ".scn"]

## Common spawn node / entity names used by TrenchBroom / func_godot / custom maps.
const SPAWN_NAMES := [
	"info_player_start",
	"info_player_deathmatch",
	"PlayerSpawn",
	"player_spawn",
	"SpawnPoint",
	"spawn",
]

const MAIN_SCENE_PATH := "res://game/main.tscn"

var current_map: Node = null
var current_map_name: String = ""
var pending_map: String = ""
var _loading_screen: CanvasLayer = null

const LOADING_SCREEN_SCENE := preload("res://assets/menus/loading_screen.tscn")


func _ready() -> void:
	pass


func _process(_delta: float) -> void:
	if pending_map.is_empty():
		return
	if not is_on_main_scene():
		return
	var map_to_load := pending_map
	pending_map = ""
	if load_map(map_to_load):
		if LimboConsole:
			LimboConsole.info("Loading map: %s" % current_map_name)
	else:
		if LimboConsole:
			LimboConsole.error("Failed to load map: %s" % map_to_load)


func is_on_main_scene() -> bool:
	var scene := get_tree().current_scene if get_tree() else null
	if scene == null:
		return false
	if scene.scene_file_path == MAIN_SCENE_PATH:
		return true
	# Fallback: root node named Main (game/main.tscn)
	if scene.name == "Main":
		return true
	return false


func change_to_main_and_load(map_name: String) -> void:
	pending_map = map_name.strip_edges()
	# Cover the scene swap immediately so the empty Main scene never flashes grey
	_ensure_bridge_loading_screen()
	if _loading_screen and _loading_screen.has_method("show_loading"):
		_loading_screen.show_loading(pending_map)
		if _loading_screen.has_method("set_progress"):
			_loading_screen.set_progress(0.15)
	var err := get_tree().change_scene_to_file(MAIN_SCENE_PATH)
	if err != OK:
		pending_map = ""
		_hide_loading_screen()
		push_error("MapLoader: failed to change to main scene (error %s)" % err)
		if LimboConsole:
			LimboConsole.error("Failed to switch to main scene")


## Returns map names (without extension) found under MAPS_DIR.
func get_map_list() -> PackedStringArray:
	var maps: PackedStringArray = []
	var dir := DirAccess.open(MAPS_DIR)
	if dir == null:
		push_warning("MapLoader: cannot open maps folder: %s" % MAPS_DIR)
		return maps

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var lower := file_name.to_lower()
			# Skip editor leftovers / temps
			if lower.ends_with(".tmp") or lower.ends_with(".depren") or lower.ends_with(".uid"):
				file_name = dir.get_next()
				continue
			for ext in MAP_EXTENSIONS:
				if lower.ends_with(ext):
					var base := file_name.substr(0, file_name.length() - ext.length())
					if base not in maps:
						maps.append(base)
					break
		file_name = dir.get_next()
	dir.list_dir_end()
	maps.sort()
	return maps


## Resolves a map name to a full resource path, or "" if not found.
func resolve_map_path(map_name: String) -> String:
	var clean := map_name.strip_edges()
	if clean.is_empty():
		return ""

	# Allow passing path-ish names without extension
	var base := clean.get_file()
	if base.contains("."):
		base = base.get_basename()

	for ext in MAP_EXTENSIONS:
		var path = MAPS_DIR + base + ext
		if ResourceLoader.exists(path):
			return path
	return ""


func unload_map(hide_loading: bool = true) -> void:
	if current_map and is_instance_valid(current_map):
		var old := current_map
		current_map = null
		if old.get_parent():
			old.get_parent().remove_child(old)
		old.queue_free()
	current_map = null
	current_map_name = ""
	# Do not clear pending_map here — change_to_main_and_load relies on it
	if hide_loading:
		_hide_loading_screen()


## Steam Audio: "apply: invalid IPLint32: params->irSize = 0" is Phonon context
## validation complaining about an empty convolution IR on some apply calls (cold
## start / mixer). Convolution is left unchanged. Turning off context_validation
## stops the push_warning spam (same as Valve's "Enable Validation" toggle).
func _silence_steam_audio_ir_validation(map_root: Node) -> void:
	if map_root == null:
		return
	var runtime := _find_node_of_class(map_root, "ResonanceRuntime")
	if runtime == null:
		return
	if "context_validation" in runtime:
		runtime.set("context_validation", false)


func _find_node_of_class(node: Node, class_name_str: String) -> Node:
	if node == null:
		return null
	if node.is_class(class_name_str):
		return node
	for c in node.get_children():
		var found := _find_node_of_class(c, class_name_str)
		if found:
			return found
	return null


## Unload the current map and switch to the main menu scene.
func return_to_main_menu() -> void:
	unload_map()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var err := get_tree().change_scene_to_file("res://assets/menus/main_menu.tscn")
	if err != OK:
		push_error("MapLoader: failed to change to main menu (error %s)" % err)


## Load a map by name (file base name in game/maps/). Returns true on success.
func load_map(map_name: String) -> bool:
	var path := resolve_map_path(map_name)
	if path.is_empty():
		push_warning("MapLoader: map not found: %s" % map_name)
		return false

	# Prefer LoadingScreen under Main; fall back to root bridge overlay
	_bind_loading_screen()
	if _loading_screen:
		_loading_screen.show_loading(map_name.strip_edges())
		if _loading_screen.has_method("set_progress"):
			_loading_screen.set_progress(0.25)

	# Unload previous map first so we never stack maps (keep loading UI visible)
	unload_map(false)

	var packed = load(path)
	if packed == null:
		push_warning("MapLoader: failed to load resource: %s" % path)
		_hide_loading_screen()
		return false

	if _loading_screen and _loading_screen.has_method("set_progress"):
		_loading_screen.set_progress(0.55)

	var instance: Node = null
	if packed is PackedScene:
		instance = packed.instantiate()
	elif packed is Node:
		# Some exporters save a Node resource directly
		instance = packed.duplicate()
	else:
		push_warning("MapLoader: unsupported map resource type at %s" % path)
		_hide_loading_screen()
		return false

	if instance == null:
		push_warning("MapLoader: instantiate failed for %s" % path)
		_hide_loading_screen()
		return false

	current_map = instance
	current_map_name = path.get_file().get_basename()
	add_child(instance)
	# Deferred so ResonanceRuntime._ready has applied its config first.
	call_deferred("_silence_steam_audio_ir_validation", instance)

	if _loading_screen and _loading_screen.has_method("set_progress"):
		_loading_screen.set_progress(0.85)

	# Place player after the map is in the tree. Keep loading screen visible until
	# the local player is fully instantiated (avoids grey frame flash).
	if multiplayer.multiplayer_peer == null or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		call_deferred("_place_player_at_spawn")
	else:
		call_deferred("_notify_network_map_ready")
	return true


func _notify_network_map_ready() -> void:
	if NetworkManager and NetworkManager.has_method("notify_map_ready"):
		# Small delay so spawn points exist
		await get_tree().create_timer(0.25).timeout
		if _loading_screen and _loading_screen.has_method("set_progress"):
			_loading_screen.set_progress(0.92)
		NetworkManager.notify_map_ready()
		# Wait until this peer's local player node exists
		await _wait_for_local_player()
	await _finish_loading()


func _wait_for_local_player(timeout_sec: float = 3.0) -> void:
	var elapsed := 0.0
	while elapsed < timeout_sec:
		if _has_local_player():
			return
		await get_tree().process_frame
		elapsed += get_tree().process_delta_time if get_tree() else 0.016


func _has_local_player() -> bool:
	# Prefer NetworkManager roster when multiplayer is active
	if NetworkManager and NetworkManager.is_online():
		var uid := multiplayer.get_unique_id()
		var spawned = NetworkManager.get("_spawned_players")
		if spawned is Dictionary and spawned.has(uid) and is_instance_valid(spawned[uid]):
			return true
	# Solo / group fallback
	for n in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(n):
			continue
		if n.get("is_local_player") == true:
			return true
		if multiplayer.multiplayer_peer == null:
			return true
	return false


func _finish_loading() -> void:
	if _loading_screen and is_instance_valid(_loading_screen) and _loading_screen.has_method("set_progress"):
		_loading_screen.set_progress(1.0)
	# A couple frames so the player camera / HUD can appear under the overlay
	await get_tree().process_frame
	await get_tree().process_frame
	_hide_loading_screen()


## Use Main/LoadingScreen when available; otherwise a temporary root overlay.
func _bind_loading_screen() -> void:
	var scene := get_tree().current_scene if get_tree() else null
	if scene:
		var in_main = scene.get_node_or_null("LoadingScreen")
		if in_main and is_instance_valid(in_main):
			_loading_screen = in_main
			return
	_ensure_bridge_loading_screen()


## Overlay parented to /root so it survives change_scene (covers grey Main flash).
func _ensure_bridge_loading_screen() -> void:
	if _loading_screen and is_instance_valid(_loading_screen):
		# If we already point at Main's screen after a prior load, keep using a root bridge for transitions
		if _loading_screen.get_parent() == get_tree().root:
			return
	# Create / reuse a dedicated bridge instance on the viewport root
	var existing := get_tree().root.get_node_or_null("LoadingScreenBridge")
	if existing and is_instance_valid(existing):
		_loading_screen = existing
		return
	_loading_screen = LOADING_SCREEN_SCENE.instantiate()
	_loading_screen.name = "LoadingScreenBridge"
	get_tree().root.add_child(_loading_screen)


func _hide_loading_screen() -> void:
	# Hide both Main's screen and any root bridge so nothing is left up
	var scene := get_tree().current_scene if get_tree() else null
	if scene:
		var in_main = scene.get_node_or_null("LoadingScreen")
		if in_main and is_instance_valid(in_main):
			if in_main.has_method("hide_loading"):
				in_main.hide_loading()
			else:
				in_main.visible = false
	var bridge := get_tree().root.get_node_or_null("LoadingScreenBridge") if get_tree() else null
	if bridge and is_instance_valid(bridge):
		if bridge.has_method("hide_loading"):
			bridge.hide_loading()
		else:
			bridge.visible = false
	elif _loading_screen and is_instance_valid(_loading_screen):
		if _loading_screen.has_method("hide_loading"):
			_loading_screen.hide_loading()
		else:
			_loading_screen.visible = false


const PLAYER_SCENE := preload("res://controllers/base_controller.tscn")


func _place_player_at_spawn() -> void:
	if current_map == null or not is_instance_valid(current_map):
		await _finish_loading()
		return

	var spawn_xform := _find_spawn_transform(current_map)
	var player := _find_player()
	# After leaving multiplayer, network-spawned players are gone — create a solo one.
	if player == null:
		var scene_root := get_tree().current_scene
		if scene_root == null:
			scene_root = get_tree().root
		player = PLAYER_SCENE.instantiate()
		player.name = "Player"
		scene_root.add_child(player)
		if player.has_method("set_local_player"):
			player.set_local_player(true)

	# Avoid residual velocity / physics impulse that launches the player.
	# Spawn helpers already apply ground_gap — do not add extra height here.
	if player is CharacterBody3D:
		var body := player as CharacterBody3D
		body.velocity = Vector3.ZERO
		body.global_transform = spawn_xform
		if body.has_method("reset_physics_interpolation"):
			body.reset_physics_interpolation()
		# Reset floor tracking if present (BaseController)
		if body.get("active_state") != null:
			body.set("active_state", 0)
		if body.get("_was_on_floor") != null:
			body.set("_was_on_floor", true)
		if body.get("_step_timer") != null:
			body.set("_step_timer", 0.0)
		if body.has_node("Head/Camera3D"):
			(body.get_node("Head/Camera3D") as Camera3D).current = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif player is Node3D:
		var n3 := player as Node3D
		n3.global_transform = spawn_xform
		if n3.has_method("reset_physics_interpolation"):
			n3.reset_physics_interpolation()

	# Player is in the tree — safe to drop the loading overlay
	await _finish_loading()


func _find_spawn_transform(root: Node) -> Transform3D:
	# 1) WorldspawnArea / game_spawn_area volumes (prefer these)
	var areas := get_tree().get_nodes_in_group("worldspawn_area")
	if areas.is_empty():
		areas = get_tree().get_nodes_in_group("spawn_area")
	for area in areas:
		if root.is_ancestor_of(area) or area == root or root.is_ancestor_of(area):
			if area.has_method("get_spawn_transform"):
				return area.get_spawn_transform()
			if area is Node3D:
				return (area as Node3D).global_transform
	# Also search under the map root in case groups are not ready
	var area_node := _find_node_by_class_or_name(root, "WorldspawnArea", "game_spawn_area")
	if area_node and area_node.has_method("get_spawn_transform"):
		return area_node.get_spawn_transform()

	# 2) info_player_start point entities
	var starts := get_tree().get_nodes_in_group("info_player_start")
	for start in starts:
		if start.has_method("get_spawn_transform"):
			return start.get_spawn_transform()
		if start is Node3D:
			var t: Transform3D = (start as Node3D).global_transform
			t.origin.y += 0.05
			return t

	# 3) Named spawn entities / markers
	for spawn_name in SPAWN_NAMES:
		var node := _find_node_by_name_recursive(root, spawn_name)
		if node and node.has_method("get_spawn_transform"):
			return node.get_spawn_transform()
		if node is Node3D:
			var t2: Transform3D = (node as Node3D).global_transform
			t2.origin.y += 0.05
			return t2

	# 4) Any node with "spawn" in the name
	var markers := _find_nodes_with_name_containing(root, "spawn")
	for n in markers:
		if n.has_method("get_spawn_transform"):
			return n.get_spawn_transform()
		if n is Node3D:
			var t3: Transform3D = (n as Node3D).global_transform
			t3.origin.y += 0.05
			return t3

	# Fallback: origin of the map, slight lift
	if root is Node3D:
		var t4: Transform3D = (root as Node3D).global_transform
		t4.origin.y += 0.05
		return t4
	return Transform3D.IDENTITY


func _find_node_by_class_or_name(node: Node, class_nm: String, name_fragment: String) -> Node:
	if node.get_class() == class_nm or class_nm in str(node.get_script()):
		return node
	if name_fragment.to_lower() in node.name.to_lower():
		return node
	# class_name WorldspawnArea
	if node.has_method("get_spawn_transform") and ("spawn" in node.name.to_lower() or "Worldspawn" in str(node.get_script())):
		return node
	for child in node.get_children():
		var found := _find_node_by_class_or_name(child, class_nm, name_fragment)
		if found:
			return found
	return null


func _find_player() -> Node:
	# Prefer explicit group if maps / controllers use it
	var from_group := get_tree().get_first_node_in_group("player")
	if from_group:
		return from_group

	# Walk the scene tree for a known controller
	return _find_player_recursive(get_tree().root)


func _find_player_recursive(node: Node) -> Node:
	if node is CharacterBody3D:
		var script: Script = node.get_script()
		if script:
			var path := str(script.resource_path).to_lower()
			if "controller" in path or "player" in path:
				return node
		# Any CharacterBody3D outside the map geometry is likely the player
		if current_map and not current_map.is_ancestor_of(node) and node != current_map:
			return node

	for child in node.get_children():
		var found := _find_player_recursive(child)
		if found:
			return found
	return null


func _find_node_by_name_recursive(node: Node, target_name: String) -> Node:
	if node.name.to_lower() == target_name.to_lower():
		return node
	for child in node.get_children():
		var found := _find_node_by_name_recursive(child, target_name)
		if found:
			return found
	return null


func _find_nodes_with_name_containing(node: Node, fragment: String) -> Array[Node]:
	var result: Array[Node] = []
	_collect_name_contains(node, fragment.to_lower(), result)
	return result


func _collect_name_contains(node: Node, fragment: String, out: Array[Node]) -> void:
	if fragment in node.name.to_lower():
		out.append(node)
	for child in node.get_children():
		_collect_name_contains(child, fragment, out)
