class_name CharacterModel
extends Node3D
## Visual character body. Models: res://assets/characters/models/
## Mixamo clips: res://assets/animations/mixamo/

signal model_changed(model_id: String)

@export var default_model_id: String = "Male/Character_01"
@export var model_yaw_offset: float = PI
## Extra multiplier after fitting to target_height.
@export var model_scale: float = 1.0
## Standing height in metres (matches player STAND_HEIGHT).
@export var target_height: float = 2.0
## If false, model shows rest pose only (debug).
@export var enable_animations: bool = true

const MODELS_DIR := "res://assets/characters/models/"
const TEXTURES_DIR := "res://assets/characters/textures/"

var model_id: String = ""
var _instance: Node3D = null
var _anim_player: AnimationPlayer = null
var _skeleton: Skeleton3D = null
var _current_anim: String = ""
var _ragdoll_active: bool = false
## World-space rigid-body ragdoll (PhysicalBone3D cannot handle _instance height-fit scale).
var _ragdoll_root: Node3D = null
var _ragdoll_bodies: Dictionary = {} # bone_name -> RigidBody3D
var _ragdoll_joints: Array = []
var _height_fit_scale: float = 1.0

## Bones included in the ragdoll (Mixamo names after prefix strip).
const RAGDOLL_BONES := [
	"Hips", "Spine", "Spine1", "Spine2", "Neck", "Head",
	"LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand",
	"RightShoulder", "RightArm", "RightForeArm", "RightHand",
	"LeftUpLeg", "LeftLeg", "LeftFoot",
	"RightUpLeg", "RightLeg", "RightFoot",
]


func _ready() -> void:
	if model_id.is_empty():
		set_model(default_model_id)


func set_model(id: String) -> void:
	var clean := id.strip_edges()
	if clean.is_empty():
		clean = default_model_id
	if clean == model_id and _instance != null and is_instance_valid(_instance):
		return
	_clear_instance()
	model_id = clean
	_instance = _load_model_scene(clean)
	if _instance:
		_instance.name = "Instance"
		add_child(_instance)
		_instance.rotation = Vector3(0.0, model_yaw_offset, 0.0)
		_instance.scale = Vector3.ONE
		_instance.position = Vector3.ZERO
		_cache_nodes(_instance)
		_fit_instance_to_height(target_height)
		_try_assign_textures(_instance, clean)
		if enable_animations:
			_attach_mixamo_animations()
	else:
		_instance = _make_placeholder()
		_instance.name = "Placeholder"
		add_child(_instance)
	_current_anim = ""
	model_changed.emit(model_id)


func get_animation_player() -> AnimationPlayer:
	return _anim_player


func get_skeleton() -> Skeleton3D:
	return _skeleton


func get_current_animation() -> String:
	return _current_anim


func play_animation(anim_name: String, custom_blend: float = 0.2, custom_speed: float = 1.0) -> void:
	if not enable_animations or _anim_player == null or anim_name.is_empty():
		return
	var resolved := _resolve_anim_name(anim_name)
	if resolved.is_empty():
		return
	if _current_anim == resolved and _anim_player.is_playing():
		_anim_player.speed_scale = custom_speed
		return
	_anim_player.speed_scale = custom_speed
	_anim_player.play(resolved, custom_blend)
	_current_anim = resolved


func has_animation(anim_name: String) -> bool:
	return not _resolve_anim_name(anim_name).is_empty()


func list_animation_names() -> PackedStringArray:
	if _anim_player == null:
		return PackedStringArray()
	return _anim_player.get_animation_list()


func _resolve_anim_name(logical: String) -> String:
	if _anim_player == null:
		return ""
	var names := _anim_player.get_animation_list()
	if logical in names:
		return logical
	var key := logical.to_lower()
	for n in names:
		if str(n).to_lower() == key or str(n).to_lower().ends_with("/" + key):
			return str(n)
	return ""


static func list_available_models() -> PackedStringArray:
	var out: PackedStringArray = []
	_scan_models(MODELS_DIR, "", out)
	out.sort()
	return out


static func _scan_models(path: String, prefix: String, out: PackedStringArray) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var rel := entry if prefix.is_empty() else prefix.path_join(entry)
		var full := path.path_join(entry)
		if dir.current_is_dir():
			if entry.to_lower() != "textures":
				_scan_models(full, rel, out)
		else:
			var lower := entry.to_lower()
			if lower.ends_with(".fbx") or lower.ends_with(".glb") or lower.ends_with(".gltf") \
					or lower.ends_with(".tscn") or lower.ends_with(".scn"):
				if not entry.begins_with("Characters_PSX"):
					out.append(rel.get_basename())
		entry = dir.get_next()
	dir.list_dir_end()


func _load_model_scene(id: String) -> Node3D:
	var base := id
	var candidates: Array[String] = [
		MODELS_DIR.path_join(base + ".tscn"),
		MODELS_DIR.path_join(base + ".scn"),
		MODELS_DIR.path_join(base + ".glb"),
		MODELS_DIR.path_join(base + ".gltf"),
		MODELS_DIR.path_join(base + ".fbx"),
		MODELS_DIR.path_join(base).path_join("model.tscn"),
	]
	if not base.contains("/"):
		for cat in ["Male", "Female", "Killers"]:
			candidates.append(MODELS_DIR.path_join(cat).path_join(base + ".fbx"))
			candidates.append(MODELS_DIR.path_join(cat).path_join(base + ".tscn"))
	for path in candidates:
		if ResourceLoader.exists(path):
			var res = load(path)
			if res is PackedScene:
				var n = (res as PackedScene).instantiate()
				if n is Node3D:
					return n as Node3D
				if n:
					n.queue_free()
	return null


func _cache_nodes(root: Node) -> void:
	_anim_player = null
	_skeleton = null
	_skeleton = root.find_child("Skeleton3D", true, false) as Skeleton3D
	if _skeleton:
		# Rename bones + matching Skin bind names (otherwise mesh collapses)
		CharacterAnimLibrary.sanitize_mixamo_skeleton(_skeleton)
		_update_skins_for_renamed_bones(root)
		_skeleton.reset_bone_poses()
	# Prefer a fresh AnimationPlayer under the skeleton (don't reuse broken FBX one)
	var existing := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if existing:
		existing.stop()
		existing.active = false
	_anim_player = AnimationPlayer.new()
	_anim_player.name = "AnimPlayerMixamo"
	if _skeleton:
		_skeleton.add_child(_anim_player)
	else:
		root.add_child(_anim_player)
	_anim_player.active = true
	_anim_player.root_node = NodePath("..")


func _update_skins_for_renamed_bones(root: Node) -> void:
	## Skin bind names must match Skeleton bone names or the mesh deforms into a blob.
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi == null or mi.skin == null:
			continue
		var skin: Skin = mi.skin.duplicate() as Skin
		var changed := false
		for b in skin.get_bind_count():
			var bn: String = str(skin.get_bind_name(b))
			var clean: String = CharacterAnimLibrary._strip_mixamo_prefix(bn)
			if clean != bn:
				skin.set_bind_name(b, clean)
				changed = true
		if changed:
			mi.skin = skin


func _fit_instance_to_height(height_m: float) -> void:
	if _instance == null or height_m <= 0.01:
		return
	# Rest pose so AABB is standing height, not mid-animation
	if _skeleton:
		_skeleton.reset_bone_poses()
	_instance.scale = Vector3.ONE
	var aabb := _compute_aabb(_instance)
	if aabb.size.y < 0.05:
		_height_fit_scale = model_scale
		_instance.scale = Vector3.ONE * model_scale
		return
	# Match visual height to STAND_HEIGHT / target_height (metres).
	var s := (height_m / aabb.size.y) * model_scale
	s = clampf(s, 0.01, 100.0)
	_height_fit_scale = s
	_instance.scale = Vector3(s, s, s)
	# Plant feet on ModelRoot origin (y = 0)
	aabb = _compute_aabb(_instance)
	_instance.position.y = -aabb.position.y
	# Keep yaw; zero XZ so the capsule is centered
	_instance.position.x = 0.0
	_instance.position.z = 0.0
	_instance.rotation = Vector3(0.0, model_yaw_offset, 0.0)


func _compute_aabb(root: Node3D) -> AABB:
	var result := AABB()
	var first := true
	# Prefer global transforms when in-tree; otherwise walk local xforms so
	# model-picker cells can fit height without get_global_transform errors.
	var use_global := root.is_inside_tree()
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.visible:
			continue
		var local_aabb := mi.get_aabb()
		for i in 8:
			var endpoint := local_aabb.get_endpoint(i)
			var corner_local: Vector3
			if use_global and mi.is_inside_tree():
				corner_local = root.to_local(mi.to_global(endpoint))
			else:
				corner_local = _mesh_point_in_root_space(mi, root, endpoint)
			if first:
				result = AABB(corner_local, Vector3.ZERO)
				first = false
			else:
				result = result.expand(corner_local)
	return result


func _mesh_point_in_root_space(mi: Node3D, root: Node3D, local_point: Vector3) -> Vector3:
	## Walk local transforms from mesh up to root (works off-tree).
	var xf := Transform3D.IDENTITY
	var n: Node = mi
	while n is Node3D and n != root:
		xf = (n as Node3D).transform * xf
		n = n.get_parent()
		if n == null:
			break
	return xf * local_point


func _attach_mixamo_animations() -> void:
	if _anim_player == null:
		return
	var skel_path := NodePath(".")
	if _skeleton and _anim_player.get_parent() != _skeleton:
		skel_path = _anim_player.get_parent().get_path_to(_skeleton)
	var lib: AnimationLibrary = CharacterAnimLibrary.build_library_for(skel_path)
	if lib == null or lib.get_animation_list().is_empty():
		push_warning("CharacterModel: no Mixamo clips in %s" % CharacterAnimLibrary.MIXAMO_DIR)
		return
	if _anim_player.has_animation_library(""):
		_anim_player.remove_animation_library("")
	_anim_player.add_animation_library("", lib)
	_anim_player.active = true
	if lib.has_animation("idle"):
		_anim_player.play("idle")
		_current_anim = "idle"


func _try_assign_textures(root: Node, id: String) -> void:
	var base := id.get_file()
	var tex_candidates: Array[String] = [
		TEXTURES_DIR.path_join(base + ".png"),
		TEXTURES_DIR.path_join(base + ".jpg"),
		MODELS_DIR.path_join("textures").path_join(base + ".png"),
	]
	var tex: Texture2D = null
	for p in tex_candidates:
		if ResourceLoader.exists(p):
			tex = load(p) as Texture2D
			if tex:
				break
	if tex == null:
		return
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi == null:
			continue
		# Only override if mesh has no usable material already
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = tex
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		mi.material_override = mat


func _clear_instance() -> void:
	if _ragdoll_active:
		stop_ragdoll()
	_destroy_ragdoll_bodies()
	for c in get_children():
		c.queue_free()
	_instance = null
	_anim_player = null
	_skeleton = null
	_current_anim = ""
	_ragdoll_active = false
	_height_fit_scale = 1.0


# ============================================================
#  RAGDOLL
# ============================================================
func is_ragdolling() -> bool:
	return _ragdoll_active


func get_ragdoll_pivot_global() -> Vector3:
	## Prefer hips rigid body / bone world position for death cam.
	if _ragdoll_active and _ragdoll_bodies.has("Hips"):
		var rb: RigidBody3D = _ragdoll_bodies["Hips"]
		if is_instance_valid(rb):
			return rb.global_position
	if _skeleton == null:
		return global_position + Vector3.UP * 0.9
	var idx := _skeleton.find_bone("Hips")
	if idx < 0:
		idx = _skeleton.find_bone("Spine")
	if idx < 0:
		return global_position + Vector3.UP * 0.9
	return _skeleton.global_transform * _skeleton.get_bone_global_pose(idx).origin


func start_ragdoll(impulse: Vector3 = Vector3.ZERO) -> void:
	if _skeleton == null or _ragdoll_active:
		return
	if _anim_player:
		_anim_player.stop()
		_anim_player.active = false
	# World-space RigidBody3D ragdoll under CharacterModel (scale 1).
	# PhysicalBone3D cannot match mesh size when _instance is height-scaled.
	_build_world_ragdoll()
	if _ragdoll_bodies.is_empty():
		if _anim_player and enable_animations:
			_anim_player.active = true
		return
	_ragdoll_active = true
	set_physics_process(true)
	if impulse.length_squared() > 0.0001:
		call_deferred("_apply_ragdoll_impulse", impulse)


## Apply a kick after ragdoll is already active (network death_visual after health RPC).
func apply_ragdoll_impulse(impulse: Vector3) -> void:
	if not _ragdoll_active or impulse.length_squared() < 0.0001:
		return
	_apply_ragdoll_impulse(impulse)


func stop_ragdoll() -> void:
	_ragdoll_active = false
	set_physics_process(false)
	_destroy_ragdoll_bodies()
	if _skeleton:
		_skeleton.clear_bones_global_pose_override()
		_skeleton.reset_bone_poses()
	if _anim_player and enable_animations:
		_anim_player.active = true
		if _anim_player.has_animation("idle"):
			_anim_player.play("idle")
			_current_anim = "idle"


func _physics_process(_delta: float) -> void:
	if not _ragdoll_active or _skeleton == null:
		return
	# Drive skeleton from world rigid bodies so skinned mesh matches STAND_HEIGHT size.
	var skel_inv: Transform3D = _skeleton.global_transform.affine_inverse()
	for bone_name in _ragdoll_bodies.keys():
		var rb: RigidBody3D = _ragdoll_bodies[bone_name]
		if not is_instance_valid(rb):
			continue
		var bone_idx: int = _skeleton.find_bone(str(bone_name))
		if bone_idx < 0:
			continue
		var local: Transform3D = skel_inv * rb.global_transform
		local.basis = local.basis.orthonormalized()
		_skeleton.set_bone_global_pose_override(bone_idx, local, 1.0, true)


func _build_world_ragdoll() -> void:
	_destroy_ragdoll_bodies()
	if _skeleton == null:
		return

	_ragdoll_root = Node3D.new()
	_ragdoll_root.name = "WorldRagdoll"
	add_child(_ragdoll_root)

	# bone_name -> world transform of bone at death pose (metres, includes height-fit scale)
	var world_xforms: Dictionary = {}
	for bone_name in RAGDOLL_BONES:
		var bone_idx: int = _skeleton.find_bone(bone_name)
		if bone_idx < 0:
			continue
		var wp: Transform3D = _skeleton.global_transform * _skeleton.get_bone_global_pose(bone_idx)
		wp.basis = wp.basis.orthonormalized()
		world_xforms[bone_name] = wp

	for bone_name in RAGDOLL_BONES:
		if not world_xforms.has(bone_name):
			continue
		var bone_idx: int = _skeleton.find_bone(bone_name)
		var wp: Transform3D = world_xforms[bone_name]
		# World-space bone length from this bone to preferred child.
		var length: float = _world_bone_length(bone_idx, world_xforms)
		var radius: float = _ragdoll_radius_for(bone_name, length)
		var is_torso: bool = bone_name in ["Hips", "Spine", "Spine1", "Spine2"]

		var rb := RigidBody3D.new()
		rb.name = "RB_%s" % bone_name
		rb.mass = _ragdoll_mass_for(bone_name)
		# Godot 4.x: friction/bounce live on PhysicsMaterial, not RigidBody3D.
		var mat := PhysicsMaterial.new()
		mat.friction = 1.0
		mat.bounce = 0.0
		mat.absorbent = true
		rb.physics_material_override = mat
		rb.linear_damp = 1.0
		rb.angular_damp = 2.2
		rb.can_sleep = true
		rb.continuous_cd = true
		# Torso vs limbs on separate layers so arms hit the chest (stops mesh sink-in).
		if is_torso:
			rb.collision_layer = 4
			rb.collision_mask = 1 | 2
		else:
			rb.collision_layer = 2
			rb.collision_mask = 1 | 4 | 2

		# Axis from bone toward child in world space, expressed in body local frame.
		var axis_world: Vector3 = _world_bone_axis(bone_idx, world_xforms)
		if axis_world.length_squared() < 1e-8:
			axis_world = wp.basis.y
		var axis_local: Vector3 = wp.basis.inverse() * axis_world.normalized()
		if axis_local.length_squared() < 1e-8:
			axis_local = Vector3.UP
		else:
			axis_local = axis_local.normalized()
		var align := _basis_y_aligned_to(axis_local)

		var col := CollisionShape3D.new()
		col.name = "Shape"
		if is_torso:
			# Wide chest/pelvis hull so limbs stop against the body instead of sinking in.
			var box := BoxShape3D.new()
			var torso_w: float = radius * 2.6
			var torso_d: float = radius * 1.8
			box.size = Vector3(torso_w, maxf(length * 0.95, radius * 2.0), torso_d)
			col.shape = box
			col.transform = Transform3D(align, axis_local * (length * 0.5))
			rb.add_child(col)
		else:
			var capsule := CapsuleShape3D.new()
			capsule.radius = radius
			# Cover almost the full bone segment so limbs contact torso/other limbs early.
			capsule.height = maxf(length * 0.95, radius * 2.05)
			col.shape = capsule
			col.transform = Transform3D(align, axis_local * (length * 0.5))
			rb.add_child(col)
		_ragdoll_root.add_child(rb)
		rb.global_transform = wp
		_ragdoll_bodies[bone_name] = rb

	# Joints between parent/child ragdoll bones (world-space, scale-free).
	for bone_name in _ragdoll_bodies.keys():
		var bone_idx: int = _skeleton.find_bone(str(bone_name))
		if bone_idx < 0:
			continue
		var parent_idx: int = _skeleton.get_bone_parent(bone_idx)
		var parent_name: String = ""
		while parent_idx >= 0:
			var pname: String = _skeleton.get_bone_name(parent_idx)
			if _ragdoll_bodies.has(pname):
				parent_name = pname
				break
			parent_idx = _skeleton.get_bone_parent(parent_idx)
		if parent_name.is_empty():
			continue
		var child_rb: RigidBody3D = _ragdoll_bodies[bone_name]
		var parent_rb: RigidBody3D = _ragdoll_bodies[parent_name]
		# Jointed pairs must not collide — overlapping end-caps would shove the chain apart.
		child_rb.add_collision_exception_with(parent_rb)
		parent_rb.add_collision_exception_with(child_rb)

		var joint := Generic6DOFJoint3D.new()
		joint.name = "Joint_%s_%s" % [parent_name, bone_name]
		_ragdoll_root.add_child(joint)
		# Anchor at child bone origin (shared joint location).
		joint.global_transform = child_rb.global_transform
		joint.node_a = joint.get_path_to(parent_rb)
		joint.node_b = joint.get_path_to(child_rb)
		# Lock linear axes so limbs keep length (GMod/HL2 solid skeleton).
		for axis in ["x", "y", "z"]:
			joint.set("linear_limit_%s/enabled" % axis, true)
			joint.set("linear_limit_%s/upper_distance" % axis, 0.0)
			joint.set("linear_limit_%s/lower_distance" % axis, 0.0)
		_limit_angular_joint(joint, str(bone_name))
		_ragdoll_joints.append(joint)


func _limit_angular_joint(joint: Generic6DOFJoint3D, bone_name: String) -> void:
	var swing: float = deg_to_rad(40.0)
	var twist: float = deg_to_rad(25.0)
	if bone_name in ["LeftArm", "RightArm", "LeftUpLeg", "RightUpLeg", "LeftShoulder", "RightShoulder"]:
		swing = deg_to_rad(70.0)
		twist = deg_to_rad(45.0)
	elif bone_name in ["LeftForeArm", "RightForeArm", "LeftLeg", "RightLeg"]:
		swing = deg_to_rad(90.0)
		twist = deg_to_rad(15.0)
	elif bone_name in ["Spine", "Spine1", "Spine2"]:
		swing = deg_to_rad(18.0)
		twist = deg_to_rad(12.0)
	elif bone_name == "Neck":
		swing = deg_to_rad(25.0)
		twist = deg_to_rad(20.0)
	elif bone_name == "Head":
		swing = deg_to_rad(30.0)
		twist = deg_to_rad(35.0)
	# Godot 4 Generic6DOFJoint3D angular limits are in radians.
	for axis in ["x", "y", "z"]:
		var span: float = swing if axis != "y" else twist
		joint.set("angular_limit_%s/enabled" % axis, true)
		joint.set("angular_limit_%s/upper_angle" % axis, span)
		joint.set("angular_limit_%s/lower_angle" % axis, -span)


func _world_bone_axis(bone_idx: int, world_xforms: Dictionary) -> Vector3:
	var children: PackedInt32Array = _skeleton.get_bone_children(bone_idx)
	var self_name: String = _skeleton.get_bone_name(bone_idx)
	if not world_xforms.has(self_name):
		return Vector3.UP
	var origin: Vector3 = world_xforms[self_name].origin
	for c in children:
		var cname: String = _skeleton.get_bone_name(c)
		if world_xforms.has(cname):
			return world_xforms[cname].origin - origin
	if children.size() > 0:
		var c0: int = children[0]
		var c0_wp: Transform3D = _skeleton.global_transform * _skeleton.get_bone_global_pose(c0)
		return c0_wp.origin - origin
	return world_xforms[self_name].basis.y * 0.12


func _world_bone_length(bone_idx: int, world_xforms: Dictionary) -> float:
	var axis: Vector3 = _world_bone_axis(bone_idx, world_xforms)
	var length: float = axis.length()
	if length < 0.03:
		length = 0.03
	return length


func _destroy_ragdoll_bodies() -> void:
	if _ragdoll_root and is_instance_valid(_ragdoll_root):
		_ragdoll_root.queue_free()
	_ragdoll_root = null
	_ragdoll_bodies.clear()
	_ragdoll_joints.clear()


func _apply_ragdoll_impulse(impulse: Vector3) -> void:
	if not _ragdoll_active:
		return
	for bone_name in _ragdoll_bodies.keys():
		var rb: RigidBody3D = _ragdoll_bodies[bone_name]
		if not is_instance_valid(rb):
			continue
		var strength: float = 0.12
		if bone_name == "Hips":
			strength = 1.0
		elif bone_name in ["Spine", "Spine1"]:
			strength = 0.5
		elif bone_name == "Spine2":
			strength = 0.3
		elif bone_name in ["Head", "Neck"]:
			strength = 0.1
		elif str(bone_name).ends_with("UpLeg") or str(bone_name).ends_with("Arm"):
			strength = 0.18
		rb.apply_central_impulse(impulse * strength)


func refit_height(height_m: float = -1.0) -> void:
	## Re-fit mesh to standing height (used when STAND_HEIGHT cvar changes).
	if height_m > 0.01:
		target_height = height_m
	if _ragdoll_active:
		stop_ragdoll()
	_fit_instance_to_height(target_height)


func _basis_y_aligned_to(direction: Vector3) -> Basis:
	var y := direction.normalized()
	if y.length_squared() < 1e-8:
		return Basis.IDENTITY
	var x := y.cross(Vector3.FORWARD)
	if x.length_squared() < 1e-6:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


func _ragdoll_radius_for(bone_name: String, length: float) -> float:
	# World-metre radii — thick enough that mesh cannot sink through the hull.
	match bone_name:
		"Hips":
			return maxf(length * 0.55, 0.08)
		"Spine", "Spine1", "Spine2":
			return maxf(length * 0.5, 0.07)
		"Head":
			return maxf(length * 0.6, 0.08)
		"Neck":
			return maxf(length * 0.3, 0.03)
		"LeftUpLeg", "RightUpLeg", "LeftLeg", "RightLeg":
			return maxf(length * 0.18, 0.04)
		"LeftArm", "RightArm", "LeftForeArm", "RightForeArm":
			return maxf(length * 0.16, 0.03)
		"LeftShoulder", "RightShoulder":
			return maxf(length * 0.18, 0.03)
		"LeftHand", "RightHand", "LeftFoot", "RightFoot":
			return maxf(length * 0.22, 0.025)
		_:
			return maxf(length * 0.15, 0.03)


func _ragdoll_mass_for(bone_name: String) -> float:
	match bone_name:
		"Hips":
			return 8.0
		"Spine", "Spine1", "Spine2":
			return 4.0
		"Head":
			return 3.0
		"Neck":
			return 1.5
		"LeftUpLeg", "RightUpLeg":
			return 4.0
		"LeftLeg", "RightLeg":
			return 2.5
		"LeftFoot", "RightFoot":
			return 1.0
		"LeftArm", "RightArm":
			return 2.0
		"LeftForeArm", "RightForeArm":
			return 1.4
		"LeftHand", "RightHand":
			return 0.6
		"LeftShoulder", "RightShoulder":
			return 1.5
		_:
			return 1.2


func _make_placeholder() -> Node3D:
	var root := Node3D.new()
	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.28
	capsule.height = 1.6
	mesh.mesh = capsule
	mesh.position.y = 0.9
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.55, 0.85)
	mesh.material_override = mat
	root.add_child(mesh)
	return root
