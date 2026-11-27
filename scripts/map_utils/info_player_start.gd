@tool
class_name InfoPlayerStart
extends Marker3D
## Point spawn marker (Quake / Source style).
## Use in TrenchBroom as classname info_player_start, or place in Godot directly.
## Spawns the player on ready if none exists yet.

@export var ground_gap: float = 0.05
@export var snap_to_ground: bool = true
@export var ray_height: float = 8.0
@export var ray_depth: float = 64.0

## Yaw in degrees the player should face (0 = marker forward / -Z).
@export_range(-180.0, 180.0, 0.1, "or_greater", "or_less") var facing_degrees: float = 0.0
## If true, ignore facing_degrees and pick a random yaw.
@export var randomize_facing: bool = false
## When false, use this marker's own global Y rotation instead of facing_degrees.
@export var use_facing_degrees: bool = true

@export var spawn_on_ready: bool = true
@export var player_scene: PackedScene = preload("res://controllers/base_controller.tscn")
@export var player_parent_path: NodePath = NodePath("")
@export var only_if_no_player: bool = true

@export var func_godot_properties: Dictionary = {}

var _spawned_player: Node = null


func _ready() -> void:
	_apply_properties_from_dict(func_godot_properties)
	add_to_group("spawn")
	add_to_group("info_player_start")
	if spawn_on_ready:
		call_deferred("spawn_player")


func _func_godot_apply_properties(properties: Dictionary) -> void:
	func_godot_properties = properties
	_apply_properties_from_dict(properties)


func _func_godot_build_complete() -> void:
	if spawn_on_ready:
		call_deferred("spawn_player")


func _apply_properties_from_dict(properties: Dictionary) -> void:
	if properties.is_empty():
		return
	if properties.has("ground_gap"):
		var gap_val = properties["ground_gap"]
		ground_gap = float(gap_val) if gap_val is String else float(gap_val)
	if properties.has("snap_to_ground"):
		var snap_val = properties["snap_to_ground"]
		if snap_val is String:
			snap_to_ground = snap_val != "0" and snap_val.to_lower() != "false"
		elif snap_val is bool:
			snap_to_ground = snap_val
		elif snap_val is int:
			snap_to_ground = snap_val != 0
	if properties.has("facing_degrees"):
		var face_val = properties["facing_degrees"]
		facing_degrees = float(face_val) if face_val is String else float(face_val)
	if properties.has("randomize_facing"):
		var rnd = properties["randomize_facing"]
		if rnd is String:
			randomize_facing = rnd != "0" and rnd.to_lower() != "false"
		elif rnd is bool:
			randomize_facing = rnd
		elif rnd is int:
			randomize_facing = rnd != 0


func get_spawn_yaw() -> float:
	if randomize_facing:
		return randf_range(-PI, PI)
	if use_facing_degrees:
		return deg_to_rad(facing_degrees)
	return global_rotation.y


func get_spawn_transform() -> Transform3D:
	var origin := global_position
	if not snap_to_ground:
		return Transform3D(Basis.IDENTITY, origin + Vector3.UP * ground_gap)

	var space := get_world_3d().direct_space_state if get_world_3d() else null
	if space == null:
		return Transform3D(Basis.IDENTITY, origin + Vector3.UP * ground_gap)

	var query := PhysicsRayQueryParameters3D.create(
		origin + Vector3.UP * ray_height,
		origin + Vector3.DOWN * ray_depth
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := space.intersect_ray(query)
	if hit:
		origin = hit.position + Vector3.UP * ground_gap
	else:
		origin.y += ground_gap
	return Transform3D(Basis.IDENTITY, origin)


func spawn_player() -> Node:
	# Multiplayer: NetworkManager owns spawning — skip map auto-spawn
	if multiplayer.multiplayer_peer != null and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return null
	if only_if_no_player:
		var existing := get_tree().get_first_node_in_group("player")
		if existing:
			_place_node(existing)
			return existing

	if player_scene == null:
		push_warning("InfoPlayerStart: player_scene is not set")
		return null

	if _spawned_player and is_instance_valid(_spawned_player):
		_place_node(_spawned_player)
		return _spawned_player

	var player := player_scene.instantiate()
	var parent := _resolve_player_parent()
	parent.add_child(player)
	_spawned_player = player
	_place_node(player)
	return player


func _resolve_player_parent() -> Node:
	if not player_parent_path.is_empty():
		var n := get_node_or_null(player_parent_path)
		if n:
			return n
	var scene := get_tree().current_scene
	if scene:
		return scene
	return get_tree().root


func _place_node(node: Node) -> void:
	var xform := get_spawn_transform()
	var yaw := get_spawn_yaw()
	# Position only on the body — keep body yaw at 0 so BaseController
	# wish_dir (head.local basis) stays aligned with the camera.
	if node is CharacterBody3D:
		var body := node as CharacterBody3D
		body.velocity = Vector3.ZERO
		body.global_position = xform.origin
		body.rotation = Vector3.ZERO
		if body.has_method("reset_physics_interpolation"):
			body.reset_physics_interpolation()
		if body.get("active_state") != null:
			body.set("active_state", 0)
		if body.get("_was_on_floor") != null:
			body.set("_was_on_floor", true)
		_apply_facing(body, yaw)
	elif node is Node3D:
		var n3 := node as Node3D
		n3.global_position = xform.origin
		n3.rotation = Vector3.ZERO
		if n3.has_method("reset_physics_interpolation"):
			n3.reset_physics_interpolation()
		_apply_facing(n3, yaw)


func _apply_facing(node: Node, yaw: float) -> void:
	var head := node.get_node_or_null("Head")
	if head is Node3D:
		var h := head as Node3D
		h.rotation = Vector3(0.0, yaw, 0.0)
		var cam := h.get_node_or_null("Camera3D")
		if cam is Node3D:
			(cam as Node3D).rotation.x = 0.0
			(cam as Node3D).rotation.z = 0.0
	elif node is Node3D:
		# No Head child — fall back to node yaw
		(node as Node3D).rotation.y = yaw
