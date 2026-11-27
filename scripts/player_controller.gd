class_name HalfLifeController
extends CharacterBody3D

# --- Movement ---
@export var walk_speed: float = 5.5
@export var sprint_speed: float = 8.5
@export var crouch_speed: float = 3.0
@export var acceleration: float = 12.0
@export var air_acceleration: float = 4.0
@export var friction: float = 8.0
@export var jump_velocity: float = 4.8

# --- Mouse ---
@export var mouse_sensitivity: float = 0.0022
@export var pitch_limit: float = 89.0

# --- Crouch ---
@export var standing_height: float = 1.8
@export var crouch_height: float = 1.15
@export var crouch_transition_speed: float = 10.0

# --- Footsteps ---
@export var footstep_sounds: Array[AudioStream] = []
@export var land_sounds: Array[AudioStream] = []
@export var footstep_volume_db: float = -8.0
@export var walk_step_interval: float = 0.45
@export var sprint_step_interval: float = 0.32
@export var crouch_step_interval: float = 0.65
@export var min_step_speed: float = 1.2          # don't play steps when almost still

# --- Nodes ---
@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var footstep_player = "goon" #$FootstepPlayer

# Internal
var _pitch: float = 0.0
var _target_height: float = standing_height
var _is_crouching: bool = false
var _wish_dir: Vector3 = Vector3.ZERO

var _step_timer: float = 0.0
var _was_on_floor: bool = true
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_target_height = standing_height
	_rng.randomize()

	if footstep_player:
		footstep_player.volume_db = footstep_volume_db


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, deg_to_rad(-pitch_limit), deg_to_rad(pitch_limit))
		head.rotation.x = _pitch

	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	_handle_crouch(delta)
	_handle_movement(delta)
	_handle_footsteps(delta)
	move_and_slide()

	_was_on_floor = is_on_floor()


func _handle_movement(delta: float) -> void:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	_wish_dir = (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	var target_speed := walk_speed
	if Input.is_action_pressed("sprint") and not _is_crouching:
		target_speed = sprint_speed
	elif _is_crouching:
		target_speed = crouch_speed

	if is_on_floor():
		if _wish_dir != Vector3.ZERO:
			velocity.x = move_toward(velocity.x, _wish_dir.x * target_speed, acceleration * delta)
			velocity.z = move_toward(velocity.z, _wish_dir.z * target_speed, acceleration * delta)
		else:
			velocity.x = move_toward(velocity.x, 0.0, friction * delta)
			velocity.z = move_toward(velocity.z, 0.0, friction * delta)

		if Input.is_action_just_pressed("jump"):
			velocity.y = jump_velocity
	else:
		if _wish_dir != Vector3.ZERO:
			velocity.x = move_toward(velocity.x, _wish_dir.x * target_speed, air_acceleration * delta)
			velocity.z = move_toward(velocity.z, _wish_dir.z * target_speed, air_acceleration * delta)

		velocity.y -= 15.0 * delta


func _handle_crouch(delta: float) -> void:
	var wants_crouch := Input.is_action_pressed("crouch")

	if wants_crouch and not _is_crouching:
		_is_crouching = true
		_target_height = crouch_height
	elif not wants_crouch and _is_crouching:
		if not _is_ceiling_blocking():
			_is_crouching = false
			_target_height = standing_height

	var shape := collision_shape.shape as CapsuleShape3D
	if shape:
		shape.height = move_toward(shape.height, _target_height, crouch_transition_speed * delta)
		collision_shape.position.y = shape.height * 0.5

	var head_target_y := 1.6 if not _is_crouching else 0.95
	head.position.y = move_toward(head.position.y, head_target_y, crouch_transition_speed * delta)


func _handle_footsteps(delta: float) -> void:
	if footstep_player == null:
		return

	# Landing sound
	if is_on_floor() and not _was_on_floor:
		_play_land_sound()
		_step_timer = 0.0   # reset so we don't instantly step after landing
		return

	if not is_on_floor():
		_step_timer = 0.0
		return

	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	if horizontal_speed < min_step_speed:
		_step_timer = 0.0
		return

	# Choose interval based on state
	var interval := walk_step_interval
	if _is_crouching:
		interval = crouch_step_interval
	elif Input.is_action_pressed("sprint"):
		interval = sprint_step_interval

	# Scale interval a bit with actual speed so it feels natural
	interval *= walk_speed / maxf(horizontal_speed, 1.0)

	_step_timer += delta
	if _step_timer >= interval:
		_step_timer = 0.0
		_play_footstep()


func _play_footstep() -> void:
	if footstep_sounds.is_empty():
		return

	var stream: AudioStream = footstep_sounds[_rng.randi_range(0, footstep_sounds.size() - 1)]
	footstep_player.stream = stream
	footstep_player.pitch_scale = _rng.randf_range(0.92, 1.08)  # slight variation
	footstep_player.play_spatial()   # uses your SpatialAudioPlayer3D delay + effects


func _play_land_sound() -> void:
	if land_sounds.is_empty():
		# fallback to a footstep if no dedicated land sounds
		_play_footstep()
		return

	var stream: AudioStream = land_sounds[_rng.randi_range(0, land_sounds.size() - 1)]
	footstep_player.stream = stream
	footstep_player.pitch_scale = _rng.randf_range(0.9, 1.05)
	footstep_player.play_spatial()


func _is_ceiling_blocking() -> bool:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3.UP * 0.1
	var to := global_position + Vector3.UP * (standing_height + 0.15)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	return not space.intersect_ray(query).is_empty()
