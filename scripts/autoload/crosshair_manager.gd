extends Node
## Global crosshair profile. Settings + in-game CrosshairView instances subscribe.

signal profile_changed(profile: CrosshairProfile)

const SETTINGS_PATH := "user://settings.cfg"

var profile: CrosshairProfile = CrosshairProfile.make_default()


func _ready() -> void:
	load_from_disk()


func set_profile(p: CrosshairProfile, save: bool = false) -> void:
	if p == null:
		return
	profile = p
	profile_changed.emit(profile)
	_push_to_views()
	if save:
		save_to_disk()


func _push_to_views() -> void:
	for n in get_tree().get_nodes_in_group("crosshair_views"):
		if n.has_method("set_profile"):
			n.call("set_profile", profile)
		elif "profile" in n:
			n.profile = profile
			if n.has_method("queue_redraw"):
				n.queue_redraw()


func save_to_disk() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # merge
	cfg.set_value("crosshair", "code", profile.export_code())
	cfg.set_value("crosshair", "name", profile.name)
	cfg.save(SETTINGS_PATH)


func load_from_disk() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		profile = CrosshairProfile.make_default()
		return
	var code := str(cfg.get_value("crosshair", "code", ""))
	if not code.is_empty():
		var p := CrosshairProfile.import_code(code)
		if p:
			profile = p
			return
	profile = CrosshairProfile.make_default()
