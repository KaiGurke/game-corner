extends CanvasLayer
## Simple, easy-to-edit loading screen.
## Edit the scene res://assets/menus/loading_screen.tscn to change look
## (colors, title, progress bar, layout). This script only drives show/hide/status.

@onready var _root: Control = $Root
@onready var _title: Label = $Root/Center/Panel/VBox/Title
@onready var _status: Label = $Root/Center/Panel/VBox/Status
@onready var _bar: ProgressBar = $Root/Center/Panel/VBox/ProgressBar

var _visible_wanted: bool = false


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	if _root:
		_root.visible = true
	set_progress(0.0)
	set_status("Loading...")


func show_loading(map_name: String = "") -> void:
	_visible_wanted = true
	visible = true
	if map_name.is_empty():
		set_title("Loading")
		set_status("Please wait...")
	else:
		set_title("Loading map")
		set_status(map_name)
	set_progress(0.1)


func hide_loading() -> void:
	_visible_wanted = false
	set_progress(1.0)
	# Small delay so the bar can reach 100% before hide (optional feel)
	await get_tree().create_timer(0.15).timeout
	if not _visible_wanted:
		visible = false
		set_progress(0.0)


func set_title(text: String) -> void:
	if _title:
		_title.text = text


func set_status(text: String) -> void:
	if _status:
		_status.text = text


func set_progress(value: float) -> void:
	if _bar:
		_bar.value = clampf(value, 0.0, 1.0) * 100.0
