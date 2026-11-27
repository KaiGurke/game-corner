class_name CharacterAnimLibrary
extends RefCounted
## Mixamo locomotion from res://assets/animations/mixamo/ (recursive).
## Prefers "Locomotion Pack" for core movement. No death clips (ragdoll later).

const MIXAMO_DIR := "res://assets/animations/mixamo/"

## logical → preferred path stems relative to MIXAMO_DIR (no extension)
const CLIP_PREFS := {
	"idle": [
		"Locomotion Pack/idle",
		"idle",
	],
	"walk": [
		"Locomotion Pack/walking",
		"walking",
		"walk",
		"walk forward",
	],
	"run": [
		"Locomotion Pack/running",
		"running",
		"run",
		"run forward",
		"sprint forward",
	],
	"jump": [
		"Locomotion Pack/jump",
		"jump",
		"jump up",
	],
	"fall": [
		"jump loop",
		"Locomotion Pack/jump",
		"jump",
	],
	"land": [
		"jump down",
		"Locomotion Pack/jump",
	],
	"crouch": [
		"Idle Crouching",
		"idle crouching",
		"Rifle 8-Way Locomotion Pack/idle crouching",
		"crouch idle aiming",
	],
	"crouch_walk": [
		"Crouch Walking",
		"Rifle Crouch Walk",
		"walk crouching forward",
		"Rifle 8-Way Locomotion Pack/walk crouching forward",
	],
}

static var _source_anims: Dictionary = {}  # logical -> Animation
static var _loaded := false
static var _all_files: PackedStringArray = []  # relative paths under MIXAMO_DIR


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_all_files = _scan_files(MIXAMO_DIR, "")
	for logical in CLIP_PREFS.keys():
		var anim := _load_preferred(logical)
		if anim:
			_source_anims[logical] = anim


static func reload() -> void:
	_loaded = false
	_source_anims.clear()
	_all_files = []
	ensure_loaded()


static func get_clip(logical_name: String) -> Animation:
	ensure_loaded()
	return _source_anims.get(logical_name, null)


static func build_library_for(skeleton_path: NodePath) -> AnimationLibrary:
	ensure_loaded()
	var lib := AnimationLibrary.new()
	var skel_str := str(skeleton_path)
	if skel_str.is_empty():
		skel_str = "."
	for logical in CLIP_PREFS.keys():
		var src: Animation = get_clip(logical)
		if src == null:
			continue
		var remapped := _retarget_animation(src, skel_str)
		if remapped.get_track_count() == 0:
			continue
		if logical in ["idle", "walk", "run", "fall", "crouch", "crouch_walk"]:
			remapped.loop_mode = Animation.LOOP_LINEAR
		lib.add_animation(logical, remapped)
	return lib


static func sanitize_mixamo_skeleton(skeleton: Skeleton3D) -> void:
	## Instance-only rename so track paths work (do not touch disk resources).
	if skeleton == null:
		return
	for i in skeleton.get_bone_count():
		var n := skeleton.get_bone_name(i)
		var clean := _strip_mixamo_prefix(n)
		if clean != n:
			skeleton.set_bone_name(i, clean)


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------
static func _scan_files(abs_dir: String, rel_prefix: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var rel := entry if rel_prefix.is_empty() else rel_prefix.path_join(entry)
		var full := abs_dir.path_join(entry)
		if dir.current_is_dir():
			out.append_array(_scan_files(full, rel))
		else:
			var lower := entry.to_lower()
			if lower.ends_with(".fbx") or lower.ends_with(".glb") or lower.ends_with(".gltf") \
					or lower.ends_with(".tscn"):
				# Skip skin/character meshes packaged in packs
				if entry.to_lower().begins_with("character_"):
					entry = dir.get_next()
					continue
				out.append(rel)
		entry = dir.get_next()
	dir.list_dir_end()
	return out


static func _load_preferred(logical: String) -> Animation:
	var prefs: Array = CLIP_PREFS.get(logical, [])
	for stem in prefs:
		var anim := _find_and_extract(str(stem))
		if anim:
			return anim
	return null


static func _find_and_extract(stem: String) -> Animation:
	var stem_l := stem.to_lower().replace("\\", "/")
	for rel in _all_files:
		var rel_l := rel.to_lower().replace("\\", "/")
		var base := rel_l.get_basename()
		# Exact stem match on full relative path or filename
		if base == stem_l or base.ends_with("/" + stem_l) or rel_l.get_basename() == stem_l.get_file():
			return _extract_animation(MIXAMO_DIR.path_join(rel))
		# Filename-only match when stem has no folder
		if not stem_l.contains("/") and rel_l.get_file().get_basename() == stem_l:
			return _extract_animation(MIXAMO_DIR.path_join(rel))
	return null


static func _extract_animation(path: String) -> Animation:
	if not ResourceLoader.exists(path):
		return null
	var res = load(path)
	if res is Animation:
		return (res as Animation).duplicate(true)
	if res is AnimationLibrary:
		var lib := res as AnimationLibrary
		var names := lib.get_animation_list()
		if names.is_empty():
			return null
		return lib.get_animation(names[0]).duplicate(true)
	if res is PackedScene:
		var scene: Node = (res as PackedScene).instantiate()
		var ap := _find_anim_player(scene)
		var found: Animation = null
		if ap:
			for n in ap.get_animation_list():
				if str(n).to_upper() == "RESET":
					continue
				found = ap.get_animation(n)
				if found:
					found = found.duplicate(true)
					break
		scene.free()
		return found
	return null


static func _find_anim_player(root: Node) -> AnimationPlayer:
	var ap := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap:
		return ap
	for c in root.find_children("*", "AnimationPlayer", true, false):
		return c as AnimationPlayer
	return null


# ---------------------------------------------------------------------------
# Retarget
# ---------------------------------------------------------------------------
static func _retarget_animation(src: Animation, skeleton_path: String) -> Animation:
	# ROTATION ONLY — Mixamo position tracks are in a different bind/scale space
	# and were collapsing the mesh into a blob. Bind-pose bone positions stay.
	var out := Animation.new()
	out.length = maxf(src.length, 0.01)
	out.loop_mode = src.loop_mode
	out.step = src.step
	for i in src.get_track_count():
		var ttype := src.track_get_type(i)
		if ttype != Animation.TYPE_ROTATION_3D:
			continue
		var bone := _strip_mixamo_prefix(_bone_from_path(str(src.track_get_path(i))))
		if bone.is_empty():
			continue
		var bl := bone.to_lower()
		if bl in ["root", "armature"]:
			continue
		var new_path := NodePath("%s:%s" % [skeleton_path, bone])
		var track_idx := out.get_track_count()
		out.add_track(ttype)
		out.track_set_path(track_idx, new_path)
		out.track_set_interpolation_type(track_idx, src.track_get_interpolation_type(i))
		var kc := src.track_get_key_count(i)
		for k in kc:
			out.track_insert_key(
				track_idx,
				src.track_get_key_time(i, k),
				src.track_get_key_value(i, k),
				src.track_get_key_transition(i, k)
			)
	return out


static func _bone_from_path(path_str: String) -> String:
	# "Some/Path/Skeleton3D:mixamorig:Hips" → "mixamorig:Hips"
	var idx := path_str.find(":")
	if idx >= 0:
		return path_str.substr(idx + 1)
	return path_str.get_file()


static func _strip_mixamo_prefix(bone: String) -> String:
	if bone.begins_with("mixamorig:"):
		return bone.substr("mixamorig:".length())
	if bone.begins_with("mixamorig_"):
		return bone.substr("mixamorig_".length())
	return bone
