extends Control

@onready var click_sound = $Click
@onready var hover_sound = $Hover
@onready var quit_delay = $QuitDelay
@onready var main_buttons = $MainButtons
@onready var quit_box = $HBoxContainer
@onready var username_input: LineEdit = $UsernameBox/UsernameInput
@onready var host_menu = $HostMenu
@onready var join_menu = $JoinMenu


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if username_input:
		username_input.text = NetworkManager.username
		username_input.text_submitted.connect(_on_username_submitted)
		username_input.focus_exited.connect(_on_username_focus_exited)


func _on_username_submitted(new_text: String) -> void:
	NetworkManager.set_username(new_text)
	username_input.text = NetworkManager.username


func _on_username_focus_exited() -> void:
	NetworkManager.set_username(username_input.text)
	username_input.text = NetworkManager.username


func _hide_main_buttons() -> void:
	main_buttons.visible = false
	quit_box.visible = false


func _show_main_buttons() -> void:
	main_buttons.visible = true
	quit_box.visible = true


func _on_host_game_pressed():
	click_sound.play()
	_hide_main_buttons()
	host_menu.open_menu()


func _on_join_game_pressed():
	click_sound.play()
	_hide_main_buttons()
	join_menu.open_menu()


func _on_settings_pressed():
	click_sound.play()
	$SettingsMenu._open_menu()


func _on_quit_to_desktop_pressed():
	click_sound.play()
	quit_delay.start()


func _on_quit_delay_timeout():
	get_tree().quit()


func _on_host_game_mouse_entered():
	hover_sound.play()


func _on_join_game_mouse_entered():
	hover_sound.play()


func _on_settings_mouse_entered():
	hover_sound.play()


func _on_quit_to_desktop_mouse_entered():
	hover_sound.play()
