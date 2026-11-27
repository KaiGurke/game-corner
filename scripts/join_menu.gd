extends Control
## Join menu: enter host Radmin IP + port, then switch to lobby view.

@onready var ip_input: LineEdit = $Panel/IPInput
@onready var port_spin: SpinBox = $Panel/PortSpin
@onready var status_label: Label = $Panel/StatusLabel
@onready var join_button: Button = $Panel/JoinButton
@onready var back_button: Button = $Panel/BackButton
@onready var click_sound: AudioStreamPlayer = $Click
@onready var hover_sound: AudioStreamPlayer = $Hover


func _ready() -> void:
	visible = false
	port_spin.min_value = 1024
	port_spin.max_value = 65535
	port_spin.value = NetworkManager.DEFAULT_PORT
	ip_input.placeholder_text = "Host Radmin IP (e.g. 26.x.x.x)"
	NetworkManager.connection_succeeded.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_failed)
	NetworkManager.server_disconnected.connect(_on_disconnected)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("escape_menu"):
		_on_back_pressed()
		get_viewport().set_input_as_handled()


func open_menu() -> void:
	visible = true
	status_label.text = "Enter the host's Radmin VPN IP and port"
	join_button.disabled = false


func close_menu() -> void:
	visible = false


func _on_join_pressed() -> void:
	click_sound.play()
	var ip := ip_input.text.strip_edges()
	if ip.is_empty():
		status_label.text = "Enter an IP address"
		return
	var port := int(port_spin.value)
	status_label.text = "Connecting to %s:%d ..." % [ip, port]
	join_button.disabled = true
	var err: Error = await NetworkManager.join_game(ip, port)
	if err != OK:
		status_label.text = "Failed to start client (error %s)" % err
		join_button.disabled = false


func _on_connected() -> void:
	status_label.text = "Connected!"
	join_button.disabled = true
	# Switch to client lobby view
	close_menu()
	var main := get_parent()
	if main and main.has_node("LobbyMenu"):
		main.get_node("LobbyMenu").open_menu()


func _on_failed(reason: String) -> void:
	status_label.text = reason
	join_button.disabled = false


func _on_disconnected() -> void:
	status_label.text = "Disconnected from host"
	join_button.disabled = false


func _on_back_pressed() -> void:
	click_sound.play()
	NetworkManager.close_connection()
	close_menu()
	var main := get_parent()
	if main and main.has_method("_show_main_buttons"):
		main._show_main_buttons()


func _on_any_hover() -> void:
	hover_sound.play()
