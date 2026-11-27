extends RefCounted
class_name ChatEmojiRegistry
## Scans res://assets/textures/emojis for custom emojis.
## Filename stem → :stem:  (emoji_1.png → :emoji_1:)

const EMOJI_DIR := "res://assets/textures/emojis"

## name -> { "path": String, "texture": Texture2D }
var _emojis: Dictionary = {}
var _scanned: bool = false


func ensure_scanned() -> void:
	if _scanned:
		return
	_scanned = true
	_emojis.clear()
	_scan_dir(EMOJI_DIR)


func _scan_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if dir.current_is_dir():
			if fname != "." and fname != "..":
				_scan_dir(path.path_join(fname))
		else:
			var lower := fname.to_lower()
			if lower.ends_with(".png") or lower.ends_with(".webp") or lower.ends_with(".jpg") \
					or lower.ends_with(".jpeg") or lower.ends_with(".svg"):
				var stem := fname.get_basename()
				var full := path.path_join(fname)
				if not _emojis.has(stem):
					var tex: Texture2D = load(full) as Texture2D
					if tex:
						_emojis[stem] = {"path": full, "texture": tex}
		fname = dir.get_next()
	dir.list_dir_end()


func has_emoji(name: String) -> bool:
	ensure_scanned()
	return _emojis.has(name)


func get_path(name: String) -> String:
	ensure_scanned()
	if _emojis.has(name):
		return str(_emojis[name].get("path", ""))
	return ""


func get_texture(name: String) -> Texture2D:
	ensure_scanned()
	if _emojis.has(name):
		return _emojis[name].get("texture") as Texture2D
	return null


func all_names() -> PackedStringArray:
	ensure_scanned()
	var names := PackedStringArray()
	for k in _emojis.keys():
		names.append(str(k))
	names.sort()
	return names


func all_entries() -> Array:
	## [{ "name": String, "path": String, "texture": Texture2D }, ...] sorted by name
	ensure_scanned()
	var out: Array = []
	var names := all_names()
	for n in names:
		out.append({
			"name": n,
			"path": get_path(n),
			"texture": get_texture(n),
		})
	return out
