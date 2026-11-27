@tool
class_name WorldspawnArea
extends Area3D
## Configurable player spawn volume (Hammer-style spawn area).
## Place as a brush entity in TrenchBroom (classname game_spawn_area) or drop
## this node in Godot and size it with child CollisionShape3D.
##
## Spawn modes:
##   0 / CENTER — middle of the volume, then dropped onto ground
##   1 / RANDOM — random XZ inside the volume, then dropped onto ground
##
## The player always ends slightly above the ground (ground_gap).

enum SpawnMode { CENTER = 0, RANDOM = 1 }

@export var spawn_mode: SpawnMode = SpawnMode.RANDOM
## Gap above the floor so the capsule is not embedded in brushes.
@export var ground_gap: float = 0.05
## How far up to start the ground ray (relative to area top).
@export var ray_height: float = 8.0
## How far down to search for ground.
@export var ray_depth: float = 64.0
## Optional override bounds in local space. If empty, derived from children.
@export var bounds_override: AABB = AABB()
## Instantiate the player when this area enters the tree.
@export var spawn_on_ready: bool = true
## Player scene to instance. Defaults to the base controller.
@export var player_scene: PackedScene = preload("res://controllers/base_controller.tscn")
## Parent for the spawned player. Empty = current scene root.
@export var player_parent_path: NodePath = NodePath("")
## If true, skip spawning when a node in the "player" group already exists.
@export var only_if_no_player: bool = true
## Yaw in degrees the player should face (0 = -Z / area forward).
@export_range(-180.0, 180.0, 0.1, "or_greater", "or_less") var facing_degrees: float = 0.0
## If true, ignore facing_degrees and pick a random yaw.
@export var randomize_facing: bool = false

## Filled by FuncGodot on map build.
@export var func_godot_properties: Dictionary = {}

var _spawned_player: Node = null

var _bounds_local: AABB = AABB()
var _bounds_ready: bool = false


func _ready() -> void:
	# Volume only — do not detect or block the player
	monitoring = false
	monitorable = false
	collision_layer = 0
	collision_mask = 0
	_apply_properties_from_dict(func_godot_properties)
	_rebuild_bounds()
	add_to_group("spawn_area")
	add_to_group("worldspawn_area")
	if spawn_on_ready:
		# Defer so map collision exists for the ground ray
		call_deferred("spawn_player")


## Called by FuncGodot during map build.
func _func_godot_apply_properties(properties: Dictionary) -> void:
	func_godot_properties = properties
	_apply_properties_from_dict(properties)


## Called by FuncGodot after the entity tree (mesh / collision) is finished.
func _func_godot_build_complete() -> void:
	_rebuild_bounds()
	# Hide decorative mesh if present — this is a volume, not world geo
	for child in get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).visible = false
	if spawn_on_ready:
		call_deferred("spawn_player")


func _apply_properties_from_dict(properties: Dictionary) -> void:
	if properties.is_empty():
		return
	if properties.has("spawn_mode"):
		var mode_val = properties["spawn_mode"]
		if mode_val is String:
			spawn_mode = int(mode_val) as SpawnMode
		elif mode_val is int or mode_val is float:
			spawn_mode = int(mode_val) as SpawnMode
	if properties.has("ground_gap"):
		var gap_val = properties["ground_gap"]
		if gap_val is String:
			ground_gap = float(gap_val)
		elif gap_val is float or gap_val is int:
			ground_gap = float(gap_val)
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


func _rebuild_bounds() -> void:
	var merged := AABB()
	var has_any := false

	# Prefer live CollisionShape3D / MeshInstance3D children (editor + runtime)
	for child in get_children():
		var child_aabb := AABB()
		var found := false

		if child is CollisionShape3D:
			child_aabb = _aabb_from_collision_shape(child as CollisionShape3D)
			found = child_aabb.size.length() > 0.0001
		elif child is MeshInstance3D and (child as MeshInstance3D).mesh:
			child_aabb = (child as MeshInstance3D).mesh.get_aabb()
			found = true

		if found:
			var local_aabb := _transform_aabb(child.transform, child_aabb)
			if not has_any:
				merged = local_aabb
				has_any = true
			else:
				merged = merged.merge(local_aabb)

	if has_any:
		_bounds_local = merged
		_bounds_ready = true
		return

	# Optional manual override when no shapes are present
	if bounds_override.size.length() > 0.001:
		_bounds_local = bounds_override
		_bounds_ready = true
		return

	# Fallback unit box
	_bounds_local = AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, 2.0, 1.0))
	_bounds_ready = true


func _aabb_from_collision_shape(cs: CollisionShape3D) -> AABB:
	if cs.shape == null:
		return AABB()
	if cs.shape is BoxShape3D:
		var box := cs.shape as BoxShape3D
		return AABB(-box.size * 0.5, box.size)
	if cs.shape is SphereShape3D:
		var sphere := cs.shape as SphereShape3D
		var r := sphere.radius
		return AABB(Vector3(-r, -r, -r), Vector3(r, r, r) * 2.0)
	if cs.shape is CapsuleShape3D:
		var cap := cs.shape as CapsuleShape3D
		var r := cap.radius
		var h := cap.height
		return AABB(Vector3(-r, -h * 0.5, -r), Vector3(r * 2.0, h, r * 2.0))
	if cs.shape is CylinderShape3D:
		var cyl := cs.shape as CylinderShape3D
		var r2 := cyl.radius
		var h2 := cyl.height
		return AABB(Vector3(-r2, -h2 * 0.5, -r2), Vector3(r2 * 2.0, h2, r2 * 2.0))
	if cs.shape is ConvexPolygonShape3D:
		var convex := cs.shape as ConvexPolygonShape3D
		if convex.points.is_empty():
			return AABB()
		var aabb := AABB(convex.points[0], Vector3.ZERO)
		for p in convex.points:
			aabb = aabb.expand(p)
		return aabb
	# Last resort
	if cs.shape.has_method("get_debug_mesh"):
		var dm: Mesh = cs.shape.get_debug_mesh()
		if dm:
			return dm.get_aabb()
	return AABB()


func _transform_aabb(xf: Transform3D, aabb: AABB) -> AABB:
	var points: Array[Vector3] = [
		aabb.position,
		aabb.position + Vector3(aabb.size.x, 0, 0),
		aabb.position + Vector3(0, aabb.size.y, 0),
		aabb.position + Vector3(0, 0, aabb.size.z),
		aabb.position + Vector3(aabb.size.x, aabb.size.y, 0),
		aabb.position + Vector3(aabb.size.x, 0, aabb.size.z),
		aabb.position + Vector3(0, aabb.size.y, aabb.size.z),
		aabb.position + aabb.size,
	]
	var out := AABB(xf * points[0], Vector3.ZERO)
	for i in range(1, points.size()):
		out = out.expand(xf * points[i])
	return out


func get_spawn_yaw() -> float:
	if randomize_facing:
		return randf_range(-PI, PI)
	return deg_to_rad(facing_degrees)


## Global transform suitable for placing a CharacterBody3D player (position only; yaw via Head).
func get_spawn_transform() -> Transform3D:
	if not _bounds_ready:
		_rebuild_bounds()

	var local_point := _pick_local_point()
	var global_point := to_global(local_point)
	global_point = _snap_to_ground(global_point)
	return Transform3D(Basis.IDENTITY, global_point)


func _pick_local_point() -> Vector3:
	if not _bounds_ready:
		_rebuild_bounds()
	var b := _bounds_local
	# Guard against inverted / zero-size AABBs
	var min_x := minf(b.position.x, b.position.x + b.size.x)
	var max_x := maxf(b.position.x, b.position.x + b.size.x)
	var min_z := minf(b.position.z, b.position.z + b.size.z)
	var max_z := maxf(b.position.z, b.position.z + b.size.z)
	var mid_y := b.position.y + b.size.y * 0.5

	if spawn_mode == SpawnMode.RANDOM:
		return Vector3(
			randf_range(min_x, max_x),
			mid_y,
			randf_range(min_z, max_z)
		)
	# CENTER
	return Vector3((min_x + max_x) * 0.5, mid_y, (min_z + max_z) * 0.5)


func _snap_to_ground(global_point: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state if get_world_3d() else null
	if space == null:
		global_point.y += ground_gap
		return global_point

	var from := global_point + Vector3.UP * ray_height
	var to := global_point + Vector3.DOWN * ray_depth
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	# Exclude this area so the ground ray is not blocked by the volume itself
	var exclude: Array[RID] = [get_rid()]
	for child in get_children():
		if child is CollisionObject3D:
			exclude.append((child as CollisionObject3D).get_rid())
	query.exclude = exclude

	var hit := space.intersect_ray(query)
	if hit:
		var pos: Vector3 = hit.position
		pos.y += ground_gap
		return pos

	# No floor found — keep XY, lift by gap from original
	global_point.y += ground_gap
	return global_point


## Instantiate the player at this area's spawn transform.
## Returns the player node, or null if skipped / failed.
func spawn_player() -> Node:
	# Multiplayer: NetworkManager owns spawning — skip map auto-spawn
	if multiplayer.multiplayer_peer != null and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return null
	_rebuild_bounds()
	if only_if_no_player:
		var existing := get_tree().get_first_node_in_group("player")
		if existing:
			# Still place the existing player here
			_place_node(existing)
			return existing

	if player_scene == null:
		push_warning("WorldspawnArea: player_scene is not set")
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


## Editor / debug: local AABB used for spawn.
func get_local_bounds() -> AABB:
	if not _bounds_ready:
		_rebuild_bounds()
	return _bounds_local
