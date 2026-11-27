class_name BaseController
extends CharacterBody3D

# =========================
#  CS2-tuned movement
# =========================
@export var MAX_SPEED: float = 8.0
@export var SNEAK_SPEED: float = 4.0
@export var CROUCH_SPEED: float = 3.8
@export var MAX_AIR_WISH_SPEED: float = 0.76
@export var ACCELERATE: float = 5.5
@export var AIR_ACCELERATE: float = 12.0
@export var FRICTION: float = 5.2
@export var STOP_SPEED: float = 2.0
@export var GRAVITY: float = 20.0
@export var JUMP_VELOCITY: float = 7.25
@export var SENSITIVITY: float = 1.0
## When true, mouse Y look is inverted.
var invert_mouse_y: bool = false
var SENS_FACTOR: int = 200
@export var FOV: int = 103

@export var AUTO_BHOP: bool = false
@export var BHOP_SPEED_CLAMP: bool = false

@export var STAND_HEIGHT: float = 2.0
@export var CROUCH_HEIGHT: float = 1.2
@export var STAND_EYE_HEIGHT: float = 1.8
@export var CROUCH_EYE_HEIGHT: float = 1.0
@export var CROUCH_TRANSITION_TIME: float = 0.16
## Lower the visible model when crouched so Mixamo crouch poses don't float.
@export var CROUCH_MODEL_DROP: float = 0.55
## Death cam (first person only)
@export var DEATH_CAM_DISTANCE: float = 4.0
@export var DEATH_CAM_HEIGHT: float = 1.2
@export var DEATH_CAM_ZOOM_TIME: float = 0.85

@export var MAX_HEALTH: int = 100
@export var HEALTH: int = 100  ## current HP (kept for inspector / HUD compatibility)
@export var SHIELD: int = 0

## Fall damage: speed is |vertical velocity| on impact
@export var FALL_DAMAGE_MIN_SPEED: float = 10.0
@export var FALL_DAMAGE_MULTIPLIER: float = 4.0
@export var RESPAWN_DELAY: float = 3.0

var is_dead: bool = false
var _death_cam_active: bool = false
var _death_cam_from_fp: bool = false
var _death_cam_blend: float = 0.0
var _saved_collision_layer: int = 0
var _saved_collision_mask: int = 0
var _max_fall_speed: float = 0.0
var _fall_start_y: float = 0.0
var _airborne: bool = false
var _respawn_timer: float = 0.0
var _health_label: Label = null
var _death_overlay: Control = null
var _death_title: Label = null
var _death_countdown: Label = null

# Noclip
@export var NOCLIP_SPEED: float = 12.0
@export var NOCLIP_SPRINT_MULT: float = 2.5

# Footsteps / jump / land audio
@export var STEP_INTERVAL: float = 0.38
@export var MIN_MOVE_SPEED: float = 0.5
## Silent period after you start walking before the first footstep (Valorant-style)
@export var WALK_STEP_DELAY: float = 0.22
@export var JUMP_SOUND_VOLUME_DB: float = 4.0
@export var LAND_MIN_VOLUME_DB: float = -2.0
@export var LAND_MAX_VOLUME_DB: float = 8.0
@export var LAND_MIN_PITCH: float = 0.92
@export var LAND_MAX_PITCH: float = 0.72
## Fall height (units) that maps to max landing impact sound
@export var LAND_FULL_IMPACT_HEIGHT: float = 8.0

# Camera vertical bob on land / jump (local feel only)
@export var JUMP_CAM_BOB: float = 0.04
@export var LAND_CAM_BOB_MIN: float = 0.03
@export var LAND_CAM_BOB_MAX: float = 0.67
@export var CAM_BOB_RECOVERY: float = 9.0

enum STATE { FLOOR, SNEAK, CROUCH, JUMP, FALL, NOCLIP }
var active_state := STATE.FLOOR

var wish_crouch := false
var wish_sneak := false
var crouch_blend: float = 0.0

var _was_on_floor: bool = true
var _step_timer: float = 0.0
var _walk_move_time: float = 0.0
var _jumped_while_crouched: bool = false

## Weapon inventory slots (viewmodels later)
enum WeaponSlot { PRIMARY = 0, SECONDARY = 1, KNIFE = 2 }
var current_weapon_slot: int = WeaponSlot.PRIMARY
const WEAPON_SLOT_NAMES := ["Primary", "Secondary", "Knife"]
var _weapon_hud: Control = null
var _weapon_slot_labels: Array = []

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var model_root: Node3D = get_node_or_null("ModelRoot")
@onready var escape_menu: CanvasLayer = $EscapeMenu

## Character model id under res://assets/characters/models/
@export var character_model_id: String = "Male/Character_01"
var _character_model: CharacterModel = null
var _anim_controller: CharacterAnimController = null
var _net_anim_state: int = -1
var _net_anim_timer: float = 0.0
const NET_ANIM_RATE := 0.12

## One player each; arrays hold the sound files. Nodes use max_polyphony = 3.
@onready var footstep_player: Node = get_node_or_null("FootstepAudio")
@onready var land_player: Node = get_node_or_null("LandAudio")
@export var footstep_streams: Array[AudioStream] = []
@export var land_streams: Array[AudioStream] = []
const STEP_POLYPHONY: int = 3
## Ground ray: no hit / buried = mute step sounds
@export var FOOTSTEP_GROUND_RAY: float = 0.55

var _mesh_base_scale := Vector3.ONE

## When false (remote puppet), skip input / local camera / mouse capture.
var is_local_player: bool = true

## Look pitch separate from vertical bob so mouse look stays stable
var _look_pitch: float = 0.0
var _cam_bob_y: float = 0.0
var _camera_base_y: float = 0.0

## First / third person (local view only — does not change multiplayer authority)
var third_person: bool = false
@export var TP_DISTANCE: float = 2.8
@export var TP_HEIGHT: float = 0.55
@export var TP_SIDE: float = 0.0

## Network transform sync (RPC — avoids MultiplayerSynchronizer path-cache errors)
const NET_SYNC_RATE := 0.05  # 20 Hz
var _net_sync_timer: float = 0.0
var _net_target_pos: Vector3 = Vector3.ZERO
var _net_target_head_yaw: float = 0.0
var _net_target_cam_pitch: float = 0.0
var _net_target_crouch: float = 0.0
var _has_net_target: bool = false


func set_local_player(local: bool) -> void:
	is_local_player = local
	if camera:
		camera.current = local
	if escape_menu:
		escape_menu.visible = false
		escape_menu.process_mode = Node.PROCESS_MODE_DISABLED if not local else Node.PROCESS_MODE_INHERIT
	# Hide HUD for remote puppets
	var hud := get_node_or_null("Base Hud")
	if hud:
		hud.visible = local
	# First-person: hide own body so it does not clip the camera.
	# Remote peers still see the full character model.
	_update_model_visibility()
	# Nexus Resonance / Steam Audio: remove listener on remotes so it never runs with empty IR
	var listener := get_node_or_null("Head/Camera3D/ResonanceListener")
	if listener:
		if local:
			listener.process_mode = Node.PROCESS_MODE_INHERIT
		else:
			listener.queue_free()
	if local:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		call_deferred("_ensure_weapon_hud")
		call_deferred("_ensure_crosshair")
	elif _weapon_hud and is_instance_valid(_weapon_hud):
		_weapon_hud.visible = false


func _is_authority() -> bool:
	# Singleplayer or we own this node
	if multiplayer.multiplayer_peer == null:
		return true
	return is_multiplayer_authority()


func _send_network_pose() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if not is_multiplayer_authority():
		return
	# PlayerManager owns pose RPCs (avoids MultiplayerSynchronizer path-cache errors).
	if PlayerManager:
		var head_yaw := head.rotation.y if head else 0.0
		# Send look pitch without local camera punch so remotes don't see bounce
		PlayerManager.broadcast_player_pose(
			multiplayer.get_unique_id(), global_position, head_yaw, _look_pitch, crouch_blend
		)


func apply_network_pose(pos: Vector3, head_yaw: float, cam_pitch: float, crouch: float = 0.0) -> void:
	# First packet after spawn: snap so remote players don't lerp from the wrong spawn slot
	if not _has_net_target:
		global_position = pos
		if head:
			head.rotation.y = head_yaw
		if camera:
			_look_pitch = cam_pitch
			camera.rotation.x = cam_pitch
		crouch_blend = crouch
		_set_height_visual_only(lerpf(STAND_HEIGHT, CROUCH_HEIGHT, crouch_blend))
	_net_target_pos = pos
	_net_target_head_yaw = head_yaw
	_net_target_cam_pitch = cam_pitch
	_net_target_crouch = crouch
	_has_net_target = true


func _apply_network_pose(delta: float) -> void:
	if not _has_net_target:
		return
	var t := clampf(delta * 15.0, 0.0, 1.0)
	# Large error → snap (teleport / respawn / late packet catch-up)
	if global_position.distance_squared_to(_net_target_pos) > 25.0:
		global_position = _net_target_pos
		if head:
			head.rotation.y = _net_target_head_yaw
		_look_pitch = _net_target_cam_pitch
		crouch_blend = _net_target_crouch
	else:
		global_position = global_position.lerp(_net_target_pos, t)
		if head:
			head.rotation.y = lerp_angle(head.rotation.y, _net_target_head_yaw, t)
		_look_pitch = lerp_angle(_look_pitch, _net_target_cam_pitch, t)
		crouch_blend = lerpf(crouch_blend, _net_target_crouch, t)
	# Collision + eye height only — no mesh scale / no position nudge
	var current_height := lerpf(STAND_HEIGHT, CROUCH_HEIGHT, crouch_blend)
	_set_height_visual_only(current_height)
	_sync_model_yaw()


func _ready() -> void:
	add_to_group("player")
	active_state = STATE.FLOOR
	crouch_blend = 0.0
	velocity = Vector3.ZERO
	HEALTH = MAX_HEALTH
	is_dead = false

	if mesh_instance:
		_mesh_base_scale = mesh_instance.scale
		# Capsule is collision-debug only; CharacterModel is the real body
		mesh_instance.visible = false

	_setup_character_model()
	_set_height(STAND_HEIGHT)

	_setup_step_audio_pools()

	# Per-client mouse prefs from saved settings
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		SENSITIVITY = float(cfg.get_value("mouse", "sensitivity", SENSITIVITY))
		invert_mouse_y = bool(cfg.get_value("mouse", "invert", false))

	# HUD health label + death overlay
	var hud := get_node_or_null("Base Hud")
	if hud:
		_health_label = hud.get_node_or_null("Control/Health") as Label
	_ensure_death_overlay()
	_update_health_hud()
	if camera:
		_camera_base_y = camera.position.y
		_look_pitch = camera.rotation.x

	# Listen for noclip changes from the autoload
	Commands.noclip_changed.connect(_on_noclip_changed)

	# Console open/close → free / recapture mouse like escape menu
	if LimboConsole and LimboConsole.has_signal("toggled"):
		LimboConsole.toggled.connect(_on_console_toggled)
	if ChatManager:
		if ChatManager.has_signal("chat_opened"):
			ChatManager.chat_opened.connect(_on_chat_opened)
		if ChatManager.has_signal("chat_closed"):
			ChatManager.chat_closed.connect(_on_chat_closed)

	# Default offline = local. In multiplayer NetworkManager calls set_local_player after authority is set.
	if multiplayer.multiplayer_peer == null:
		set_local_player(true)
	# else: wait for NetworkManager — do not assume authority yet (set after add_child)


func _ui_blocks_gameplay() -> bool:
	if escape_menu and escape_menu.visible:
		return true
	if LimboConsole and LimboConsole.is_open():
		return true
	if ChatManager and ChatManager.blocks_gameplay():
		return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if not is_local_player or not _is_authority():
		return
	if is_dead:
		return
	if _ui_blocks_gameplay():
		return

	# Noclip keybind (input action "noclip", default key V)
	if event.is_action_pressed("noclip"):
		Commands.cmd_noclip()
		get_viewport().set_input_as_handled()
		return

	# Third-person toggle (F4 via action "third_person")
	if event.is_action_pressed("third_person"):
		toggle_third_person()
		get_viewport().set_input_as_handled()
		return

	# Weapon slots 1-3
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_1:
				_select_weapon_slot(WeaponSlot.PRIMARY)
				get_viewport().set_input_as_handled()
				return
			KEY_2:
				_select_weapon_slot(WeaponSlot.SECONDARY)
				get_viewport().set_input_as_handled()
				return
			KEY_3:
				_select_weapon_slot(WeaponSlot.KNIFE)
				get_viewport().set_input_as_handled()
				return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		head.rotate_y(-event.relative.x * SENSITIVITY / SENS_FACTOR)
		var y_sign := 1.0 if invert_mouse_y else -1.0
		_look_pitch = clamp(
			_look_pitch + y_sign * event.relative.y * SENSITIVITY / SENS_FACTOR,
			deg_to_rad(-89.0),
			deg_to_rad(89.0)
		)
		_apply_camera_rotation()


func _physics_process(delta: float) -> void:
	# Remote puppet: smooth toward last networked pose (skip while dead/ragdoll)
	if multiplayer.multiplayer_peer != null and not _is_authority():
		if not is_dead:
			_apply_network_pose(delta)
		return

	if not is_local_player or not _is_authority():
		return

	# Dead: wait for respawn, no control (ragdoll simulates on its own)
	if is_dead:
		_respawn_timer -= delta
		velocity = Vector3.ZERO
		_update_health_hud()
		if _respawn_timer <= 0.0:
			_do_respawn()
		# Don't broadcast standing pose while ragdolling — remotes keep their sim
		return

	# UI focus (chat / console / escape): still apply gravity, just freeze controls
	if _ui_blocks_gameplay():
		if not Commands.noclip_enabled:
			if not is_on_floor():
				if not _airborne:
					_airborne = true
					_fall_start_y = global_position.y
					_max_fall_speed = 0.0
				velocity.y -= GRAVITY * delta
				_max_fall_speed = maxf(_max_fall_speed, -velocity.y)
			else:
				_apply_friction(delta)
			var was_air_ui := _airborne or not is_on_floor()
			var vy_ui := velocity.y
			move_and_slide()
			_process_landing(was_air_ui, vy_ui)
		_net_sync_timer += delta
		if _net_sync_timer >= NET_SYNC_RATE:
			_net_sync_timer = 0.0
			_send_network_pose()
		return

	# Broadcast pose to other peers
	_net_sync_timer += delta
	if _net_sync_timer >= NET_SYNC_RATE:
		_net_sync_timer = 0.0
		_send_network_pose()

	wish_crouch = Input.is_action_pressed("crouch")
	wish_sneak  = Input.is_action_pressed("sneak")

	# Crouch blend (visual only) – skip while noclipping
	if not Commands.noclip_enabled:
		var target := 1.0 if wish_crouch else 0.0
		crouch_blend = move_toward(crouch_blend, target, delta / CROUCH_TRANSITION_TIME)
		var current_height := lerpf(STAND_HEIGHT, CROUCH_HEIGHT, crouch_blend)
		_set_height(current_height)

	if Commands.noclip_enabled:
		_state_noclip(delta)
		move_and_slide()
		_max_fall_speed = 0.0
		_airborne = false
		_was_on_floor = is_on_floor()
		return

	# Gravity while airborne (pre-slide floor check = last frame)
	if not is_on_floor():
		if not _airborne:
			_airborne = true
			_fall_start_y = global_position.y
			_max_fall_speed = 0.0
		velocity.y -= GRAVITY * delta
		_max_fall_speed = maxf(_max_fall_speed, -velocity.y)

	_update_state()

	match active_state:
		STATE.FLOOR:
			_state_floor(delta)
		STATE.SNEAK:
			_state_sneak(delta)
		STATE.CROUCH:
			_state_crouch(delta)
		STATE.JUMP, STATE.FALL:
			_state_air(delta)

	var was_airborne := _airborne or not is_on_floor()
	var vy_before := velocity.y
	move_and_slide()
	_process_landing(was_airborne, vy_before)
	_update_footsteps(delta)
	_update_character_anim(delta)

func _update_fov():
	camera.fov = FOV
# ============================================================
#  NOCLIP
# ============================================================
func _on_noclip_changed(enabled: bool) -> void:
	if enabled:
		active_state = STATE.NOCLIP
		# Keep current velocity when entering noclip
		collision_shape.disabled = true
	else:
		collision_shape.disabled = false
		# Keep current velocity when leaving noclip (do NOT zero it)
		if is_on_floor():
			active_state = STATE.FLOOR
		else:
			active_state = STATE.FALL


func _state_noclip(_delta: float) -> void:
	# Full camera-relative movement (including pitch)
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")

	var forward := -camera.global_transform.basis.z
	var right := camera.global_transform.basis.x
	var direction := (right * input_dir.x + forward * -input_dir.y).normalized()

	# Extra vertical from jump / crouch
	var vertical := 0.0
	if Input.is_action_pressed("jump"):
		vertical += 1.0
	if Input.is_action_pressed("crouch"):
		vertical -= 1.0

	var speed := NOCLIP_SPEED
	if Input.is_action_pressed("sneak"):
		speed *= NOCLIP_SPRINT_MULT

	var wish_vel := direction * speed
	wish_vel.y += vertical * speed

	velocity = wish_vel


# ============================================================
#  HEIGHT
# ============================================================
func _set_height(height: float) -> void:
	var shape := collision_shape.shape as CapsuleShape3D
	if shape == null:
		return
	# Collision + eye height. Mesh scale stays 1; crouch is anim + root drop.
	shape.height = height
	collision_shape.position.y = height * 0.5
	head.position.y = lerpf(STAND_EYE_HEIGHT, CROUCH_EYE_HEIGHT, crouch_blend)
	_apply_crouch_model_drop()


## Visual-only height for remote puppets (no floor correction / authority physics).
func _set_height_visual_only(height: float) -> void:
	var shape := collision_shape.shape as CapsuleShape3D
	if shape:
		shape.height = height
		collision_shape.position.y = height * 0.5
	if head:
		head.position.y = lerpf(STAND_EYE_HEIGHT, CROUCH_EYE_HEIGHT, crouch_blend)
	_apply_crouch_model_drop()


func _apply_crouch_model_drop() -> void:
	# Rotation-only Mixamo crouch poses leave hips high → feet float.
	# Lower the whole visual root so soles stay near the ground.
	if model_root == null:
		return
	model_root.scale = Vector3.ONE
	model_root.position.x = 0.0
	model_root.position.z = 0.0
	model_root.position.y = lerpf(0.0, -CROUCH_MODEL_DROP, crouch_blend)


# ============================================================
#  CHARACTER MODEL (Step 1)
# ============================================================
func _setup_character_model() -> void:
	# Only the local player loads appearance from disk. Remote puppets keep the
	# default until PlayerManager delivers apply_network_model (avoids every peer
	# showing your model and missing anim setup for the real remote id).
	if is_local_player:
		var cfg := ConfigFile.new()
		if cfg.load("user://player.cfg") == OK:
			var saved := str(cfg.get_value("player", "model_id", ""))
			if not saved.strip_edges().is_empty():
				character_model_id = saved
	_character_model = model_root as CharacterModel
	if _character_model == null and model_root:
		# Attach script at runtime if scene missed it
		if model_root.get_script() == null:
			model_root.set_script(load("res://scripts/character/character_model.gd"))
			_character_model = model_root as CharacterModel
	if _character_model:
		_character_model.default_model_id = character_model_id
		_character_model.target_height = STAND_HEIGHT
		_character_model.set_model(character_model_id)
	_anim_controller = CharacterAnimController.new()
	_anim_controller.setup(_character_model)
	_update_model_visibility()


func set_character_model(id: String) -> void:
	character_model_id = id
	if _character_model:
		_character_model.set_model(id)
	if _anim_controller:
		_anim_controller.setup(_character_model)
	_update_model_visibility()
	# Multiplayer: other peers need the same model (avoids desync on appearance).
	if multiplayer.multiplayer_peer != null and is_multiplayer_authority() and PlayerManager:
		PlayerManager.broadcast_player_model(multiplayer.get_unique_id(), character_model_id)


func apply_network_model(id: String) -> void:
	character_model_id = id
	if _character_model:
		_character_model.set_model(id)
	if _anim_controller:
		_anim_controller.setup(_character_model)
	_update_model_visibility()


func apply_network_anim(state_id: int, speed_scale: float = 1.0) -> void:
	# Remotes only — authority drives anim from local locomotion.
	if is_multiplayer_authority() and multiplayer.multiplayer_peer != null:
		return
	if _anim_controller:
		_anim_controller.apply_network_state(state_id, speed_scale)


func get_anim_state_id() -> int:
	if _anim_controller == null:
		return 0
	return int(_anim_controller.state)


func _update_character_anim(delta: float) -> void:
	if _anim_controller == null:
		return
	_anim_controller.update_from_locomotion(
		velocity,
		is_on_floor(),
		crouch_blend > 0.5,
		is_dead,
		MAX_SPEED
	)
	# Sync logical anim state to other peers (clips play on their local AnimationPlayer).
	# Resend on change (fast) and every ~1s so late join / dropped unreliable packets recover.
	if multiplayer.multiplayer_peer == null or not is_multiplayer_authority():
		return
	if PlayerManager == null:
		return
	_net_anim_timer += delta
	var state_changed := _anim_controller.state != _net_anim_state
	if not state_changed and _net_anim_timer < 1.0:
		return
	if state_changed and _net_anim_timer < NET_ANIM_RATE:
		return
	_net_anim_timer = 0.0
	_net_anim_state = _anim_controller.state
	PlayerManager.broadcast_player_anim(multiplayer.get_unique_id(), _net_anim_state, 1.0)


func _update_model_visibility() -> void:
	if model_root == null:
		return
	# Dead: always show body (ragdoll / death cam)
	if is_dead:
		model_root.visible = true
		return
	# Remote puppets: always show body.
	# Local: show body only in third person (hide in FPS to avoid camera clip).
	if not is_local_player:
		model_root.visible = true
	else:
		model_root.visible = third_person


func toggle_third_person() -> void:
	if not is_local_player:
		return
	third_person = not third_person
	_update_model_visibility()
	_apply_camera_rotation()


func set_third_person(enabled: bool) -> void:
	if not is_local_player:
		return
	third_person = enabled
	_update_model_visibility()
	_apply_camera_rotation()


# ============================================================
#  STATE MACHINE
# ============================================================
func _update_state() -> void:
	if Commands.noclip_enabled:
		return

	var on_floor := is_on_floor()

	match active_state:
		STATE.FLOOR:
			if not on_floor:
				active_state = STATE.JUMP if velocity.y > 0.0 else STATE.FALL
			elif wish_crouch:
				active_state = STATE.CROUCH
			elif wish_sneak:
				active_state = STATE.SNEAK

		STATE.SNEAK:
			if not on_floor:
				active_state = STATE.JUMP if velocity.y > 0.0 else STATE.FALL
			elif wish_crouch:
				active_state = STATE.CROUCH
			elif not wish_sneak:
				active_state = STATE.FLOOR

		STATE.CROUCH:
			if not on_floor:
				active_state = STATE.JUMP if velocity.y > 0.0 else STATE.FALL
			elif not wish_crouch:
				active_state = STATE.SNEAK if wish_sneak else STATE.FLOOR

		STATE.JUMP:
			if on_floor:
				_land()
			elif velocity.y <= 0.0:
				active_state = STATE.FALL

		STATE.FALL:
			if on_floor:
				_land()


func _land() -> void:
	if wish_crouch:
		active_state = STATE.CROUCH
	elif wish_sneak:
		active_state = STATE.SNEAK
	else:
		active_state = STATE.FLOOR


# ============================================================
#  STATE BEHAVIOURS
# ============================================================
func _state_floor(delta: float) -> void:
	if _wants_jump():
		_do_jump()
		return
	_apply_friction(delta)
	_move(MAX_SPEED, delta)


func _state_sneak(delta: float) -> void:
	if _wants_jump():
		_do_jump()
		return
	_apply_friction(delta)
	_move(SNEAK_SPEED, delta)


func _state_crouch(delta: float) -> void:
	if _wants_jump():
		_do_jump()
		return
	_apply_friction(delta)
	_move(CROUCH_SPEED, delta)


func _state_air(delta: float) -> void:
	var wish_dir := _get_wish_dir()
	if wish_dir.length_squared() > 0.0:
		_air_accelerate(wish_dir, MAX_SPEED, AIR_ACCELERATE, delta)


func _move(speed: float, delta: float) -> void:
	var wish_dir := _get_wish_dir()
	if wish_dir.length_squared() > 0.0:
		_accelerate(wish_dir, speed, ACCELERATE, delta)


func _wants_jump() -> bool:
	return Input.is_action_just_pressed("jump") or (AUTO_BHOP and Input.is_action_pressed("jump"))


func _do_jump() -> void:
	if BHOP_SPEED_CLAMP:
		var horizontal := Vector3(velocity.x, 0.0, velocity.z)
		var max_takeoff := MAX_SPEED * 1.1
		if horizontal.length() > max_takeoff:
			horizontal = horizontal.normalized() * max_takeoff
			velocity.x = horizontal.x
			velocity.z = horizontal.z

	velocity.y = JUMP_VELOCITY
	active_state = STATE.JUMP
	_airborne = true
	_fall_start_y = global_position.y
	_max_fall_speed = 0.0

	_jumped_while_crouched = wish_crouch

	# Silent jump while crouching; otherwise louder jump step + slight cam bob up
	if not wish_crouch:
		_play_step_sound("jump", 1.0)
		_add_camera_bob(JUMP_CAM_BOB)


# ============================================================
#  CORE MATH
# ============================================================
func _get_wish_dir() -> Vector3:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	return (head.transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()


func _accelerate(wish_dir: Vector3, wish_speed: float, accel: float, delta: float) -> void:
	var current_speed := velocity.dot(wish_dir)
	var add_speed := wish_speed - current_speed
	if add_speed <= 0.0:
		return
	var accel_speed := minf(accel * wish_speed * delta, add_speed)
	velocity += wish_dir * accel_speed


func _air_accelerate(wish_dir: Vector3, wish_speed: float, accel: float, delta: float) -> void:
	var wish_spd := minf(wish_speed, MAX_AIR_WISH_SPEED)
	var current_speed := velocity.dot(wish_dir)
	var add_speed := wish_spd - current_speed
	if add_speed <= 0.0:
		return
	var accel_speed := minf(accel * wish_speed * delta, add_speed)
	velocity += wish_dir * accel_speed


func _apply_friction(delta: float) -> void:
	var speed := Vector3(velocity.x, 0.0, velocity.z).length()
	if speed < 0.05:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var control := speed if speed >= STOP_SPEED else STOP_SPEED
	var drop := control * FRICTION * delta
	var new_speed := maxf(speed - drop, 0.0)
	if new_speed != speed:
		velocity.x *= new_speed / speed
		velocity.z *= new_speed / speed


# ============================================================
#  HEALTH / FALL DAMAGE / DEATH / RESPAWN
# ============================================================
func _process_landing(was_airborne: bool, vy_before_slide: float) -> void:
	var on_floor := is_on_floor()
	if Commands.noclip_enabled or is_dead:
		_max_fall_speed = 0.0
		_airborne = false
		_was_on_floor = on_floor
		return

	# Just landed
	if on_floor and was_airborne:
		var real_vy := absf(get_real_velocity().y)
		var impact := maxf(_max_fall_speed, maxf(-vy_before_slide, real_vy))
		var fall_height := maxf(_fall_start_y - global_position.y, 0.0)
		var dmg := 0
		# Speed-based
		if impact >= FALL_DAMAGE_MIN_SPEED:
			dmg = int(round((impact - FALL_DAMAGE_MIN_SPEED + 0.01) * FALL_DAMAGE_MULTIPLIER))
		# Height-based fallback (take the larger)
		if fall_height >= 3.5:
			var height_dmg := int(round((fall_height - 3.5) * 10.0))
			dmg = maxi(dmg, height_dmg)
		if dmg > 0:
			take_damage(dmg, -1, "fall")
		# Impact 0..1 from height + speed for audio / camera
		var height_t := clampf(fall_height / maxf(LAND_FULL_IMPACT_HEIGHT, 0.01), 0.0, 1.0)
		var speed_t := clampf(impact / maxf(FALL_DAMAGE_MIN_SPEED * 2.0, 0.01), 0.0, 1.0)
		var intensity := clampf(maxf(height_t, speed_t * 0.85), 0.15, 1.0)
		# Landing sound (crouch land softer); vertical camera bob scales with impact
		if _jumped_while_crouched:
			intensity *= 0.65
		_play_step_sound("land", intensity)
		_add_camera_bob(-lerpf(LAND_CAM_BOB_MIN, LAND_CAM_BOB_MAX, intensity))
		_jumped_while_crouched = false
		_step_timer = STEP_INTERVAL
		_max_fall_speed = 0.0
		_airborne = false
	elif on_floor:
		_max_fall_speed = 0.0
		_airborne = false
	else:
		_airborne = true

	_was_on_floor = on_floor


func take_damage(amount: int, _attacker_id: int = -1, _reason: String = "") -> void:
	if is_dead or amount <= 0:
		return
	if not _is_authority() and multiplayer.multiplayer_peer != null:
		return
	# Shield absorbs first
	var remaining := amount
	if SHIELD > 0:
		var absorbed := mini(SHIELD, remaining)
		SHIELD -= absorbed
		remaining -= absorbed
	if remaining <= 0:
		_sync_health()
		_update_health_hud()
		return
	HEALTH = maxi(HEALTH - remaining, 0)
	_update_health_hud()
	_sync_health()
	if HEALTH <= 0:
		_die(_attacker_id, _reason)


func heal(amount: int) -> void:
	if is_dead or amount <= 0:
		return
	HEALTH = mini(HEALTH + amount, MAX_HEALTH)
	_update_health_hud()
	_sync_health()


func dev_set_health(value: int) -> void:
	if value <= 0:
		take_damage(maxi(HEALTH, 9999), -1, "dev")
		return
	is_dead = false
	HEALTH = mini(value, MAX_HEALTH)
	_respawn_timer = 0.0
	_update_health_hud()
	_sync_health()


func _die(attacker_id: int = -1, reason: String = "") -> void:
	if is_dead:
		return
	is_dead = true
	HEALTH = 0
	velocity = Vector3.ZERO
	_respawn_timer = RESPAWN_DELAY
	_update_health_hud()
	_sync_health()
	_start_death_visuals(attacker_id, reason)
	if NetworkManager and NetworkManager.is_online():
		NetworkManager.report_player_death(multiplayer.get_unique_id(), attacker_id, reason)
	elif KillFeed:
		var n := NetworkManager.username if NetworkManager else "Player"
		if reason == "fall":
			KillFeed.add_fall(n)
		elif attacker_id > 0:
			KillFeed.add_kill("Player", n)
		else:
			KillFeed.add_death(n)


func _do_respawn() -> void:
	# Stop ragdoll/cam first but do NOT restore collision until after teleport.
	# Restoring collision at the death pose was launching the body across the map.
	_stop_ragdoll_visual()
	_death_cam_active = false
	_death_cam_blend = 0.0
	if is_local_player and _death_cam_from_fp:
		third_person = false
	_death_cam_from_fp = false

	is_dead = false
	HEALTH = MAX_HEALTH
	SHIELD = 0
	velocity = Vector3.ZERO
	_max_fall_speed = 0.0
	_airborne = false
	_was_on_floor = true
	_respawn_timer = 0.0
	crouch_blend = 0.0
	active_state = STATE.FLOOR

	var xform := Transform3D.IDENTITY
	if NetworkManager and NetworkManager.has_method("get_spawn_transform_for"):
		var pid := multiplayer.get_unique_id() if multiplayer.multiplayer_peer else 1
		xform = NetworkManager.get_spawn_transform_for(pid)
	elif MapLoader and MapLoader.current_map and MapLoader.has_method("_find_spawn_transform"):
		xform = MapLoader._find_spawn_transform(MapLoader.current_map)

	# Teleport while collision is still disabled
	global_transform = Transform3D(Basis(), xform.origin)
	if head:
		head.rotation = Vector3(0.0, xform.basis.get_euler().y, 0.0)
	_look_pitch = 0.0
	_set_height(STAND_HEIGHT)
	velocity = Vector3.ZERO
	if has_method("reset_physics_interpolation"):
		reset_physics_interpolation()

	# Safe to collide again only at spawn
	_restore_collision_after_death()
	_update_model_visibility()
	_apply_camera_rotation()
	_update_health_hud()
	_sync_health()
	if NetworkManager and NetworkManager.is_online():
		NetworkManager.report_player_respawn(multiplayer.get_unique_id())
	_send_network_pose()


func apply_network_health(hp: int, dead: bool) -> void:
	var was_dead := is_dead
	HEALTH = hp
	is_dead = dead
	_update_health_hud()
	# Do NOT start ragdoll here with zero impulse — that races death_visual RPC and
	# locks out the real kick (start_ragdoll early-outs when already active).
	# Death visual owns the impulse; health only clears ragdoll on respawn.
	if not dead and was_dead:
		_stop_ragdoll_visual()
		velocity = Vector3.ZERO
		_airborne = false
		_was_on_floor = true
		if has_method("reset_physics_interpolation"):
			reset_physics_interpolation()
	elif dead and not was_dead:
		# Fallback if death_visual packet was lost: start with no extra kick.
		# Deferred so a same-frame death_visual RPC can win first.
		call_deferred("_fallback_ragdoll_if_needed")


func apply_height_cvars() -> void:
	## Called after STAND_HEIGHT / related cvars change — collision + mesh.
	var h := lerpf(STAND_HEIGHT, CROUCH_HEIGHT, crouch_blend)
	_set_height(h)
	if _character_model and _character_model.has_method("refit_height"):
		_character_model.refit_height(STAND_HEIGHT)


func _start_death_visuals(attacker_id: int = -1, _reason: String = "") -> void:
	# Impulse away from attacker or backward from look dir
	var impulse := Vector3.ZERO
	if head:
		impulse = -head.global_transform.basis.z * 3.5 + Vector3.UP * 1.5
	if attacker_id > 0 and PlayerManager:
		var atk = PlayerManager.get_player_node(attacker_id)
		if is_instance_valid(atk):
			var away: Vector3 = global_position - atk.global_position
			away.y = 0.0
			if away.length_squared() > 0.01:
				impulse = away.normalized() * 4.0 + Vector3.UP * 1.8
	_start_ragdoll_visual(impulse)
	# Remotes need the same kick — health-only path used zero impulse and looked wrong.
	if multiplayer.multiplayer_peer != null and is_multiplayer_authority() and PlayerManager:
		PlayerManager.broadcast_player_death_visual(multiplayer.get_unique_id(), impulse)
	# Soft-disable character capsule so it doesn't stand through the ragdoll
	if collision_shape:
		_saved_collision_layer = collision_layer
		_saved_collision_mask = collision_mask
		collision_layer = 0
		collision_mask = 0
	# Death cam: first person only — zoom out and watch the body
	if is_local_player and not third_person:
		_death_cam_from_fp = true
		_death_cam_active = true
		_death_cam_blend = 0.0
		if model_root:
			model_root.visible = true
	else:
		_death_cam_from_fp = false
		_death_cam_active = false
		if model_root:
			model_root.visible = true


func _stop_death_visuals() -> void:
	## Full cleanup (ragdoll + cam + collision). Prefer _do_respawn's ordered path.
	_stop_ragdoll_visual()
	_death_cam_active = false
	_death_cam_blend = 0.0
	velocity = Vector3.ZERO
	if is_local_player and _death_cam_from_fp:
		third_person = false
	_death_cam_from_fp = false
	_restore_collision_after_death()
	_update_model_visibility()
	_apply_camera_rotation()
	if has_method("reset_physics_interpolation"):
		reset_physics_interpolation()


func _restore_collision_after_death() -> void:
	if _saved_collision_layer != 0 or _saved_collision_mask != 0:
		collision_layer = _saved_collision_layer
		collision_mask = _saved_collision_mask
	else:
		collision_layer = 1
		collision_mask = 1
	_saved_collision_layer = 0
	_saved_collision_mask = 0
	velocity = Vector3.ZERO


func _start_ragdoll_visual(impulse: Vector3) -> void:
	if _character_model == null:
		return
	# If health RPC already flipped is_dead and started a zero-impulse ragdoll,
	# still apply the kick so remote death looks the same as local.
	if _character_model.has_method("is_ragdolling") and _character_model.is_ragdolling():
		if impulse.length_squared() > 0.0001 and _character_model.has_method("apply_ragdoll_impulse"):
			_character_model.apply_ragdoll_impulse(impulse)
	elif _character_model.has_method("start_ragdoll"):
		_character_model.start_ragdoll(impulse)
	if model_root:
		model_root.visible = true
		# Ragdoll bones are in world-ish space under skeleton — zero crouch drop
		model_root.position.y = 0.0


func _fallback_ragdoll_if_needed() -> void:
	if not is_dead:
		return
	if _character_model and _character_model.has_method("is_ragdolling") and _character_model.is_ragdolling():
		return
	_start_ragdoll_visual(Vector3.ZERO)


func _stop_ragdoll_visual() -> void:
	if _character_model and _character_model.has_method("stop_ragdoll"):
		_character_model.stop_ragdoll()


func _sync_health() -> void:
	if multiplayer.multiplayer_peer == null or not is_multiplayer_authority():
		return
	if PlayerManager:
		PlayerManager.broadcast_player_health(multiplayer.get_unique_id(), HEALTH, is_dead)


func _ensure_death_overlay() -> void:
	if _death_overlay != null and is_instance_valid(_death_overlay):
		return
	var hud := get_node_or_null("Base Hud")
	var parent: Node = hud.get_node_or_null("Control") if hud else null
	if parent == null:
		# Fallback: attach to self as CanvasLayer
		var layer := CanvasLayer.new()
		layer.name = "DeathOverlayLayer"
		layer.layer = 60
		add_child(layer)
		parent = layer
	_death_overlay = Control.new()
	_death_overlay.name = "DeathOverlay"
	_death_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_death_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_overlay.visible = false
	parent.add_child(_death_overlay)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_CENTER_TOP)
	vbox.anchor_left = 0.5
	vbox.anchor_right = 0.5
	vbox.anchor_top = 0.0
	vbox.anchor_bottom = 0.0
	vbox.offset_left = -200.0
	vbox.offset_right = 200.0
	vbox.offset_top = 48.0
	vbox.offset_bottom = 160.0
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_overlay.add_child(vbox)

	_death_title = Label.new()
	_death_title.text = "You died..."
	_death_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_title.add_theme_font_size_override("font_size", 42)
	_death_title.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))
	vbox.add_child(_death_title)

	_death_countdown = Label.new()
	_death_countdown.text = "3"
	_death_countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_countdown.add_theme_font_size_override("font_size", 36)
	_death_countdown.add_theme_color_override("font_color", Color(1.0, 0.25, 0.25))
	vbox.add_child(_death_countdown)


func _update_health_hud() -> void:
	if not is_local_player:
		return
	if _health_label == null:
		var hud := get_node_or_null("Base Hud")
		if hud:
			_health_label = hud.get_node_or_null("Control/Health") as Label
	if _health_label:
		# Always show numeric HP (0 while dead) — death message is the overlay
		_health_label.text = str(maxi(HEALTH, 0))
	_ensure_death_overlay()
	if _death_overlay:
		_death_overlay.visible = is_dead
		if is_dead and _death_countdown:
			_death_countdown.text = str(maxi(int(ceil(_respawn_timer)), 0))


# ============================================================
#  FOOTSTEPS / JUMP / LAND AUDIO + CAMERA PUNCH
# ============================================================
func _process(delta: float) -> void:
	# Body faces look yaw — freeze while ragdolling so bones aren't overwritten
	if not is_dead:
		_sync_model_yaw()
	if not is_local_player:
		return
	var k := 1.0 - exp(-CAM_BOB_RECOVERY * delta)
	_cam_bob_y = lerpf(_cam_bob_y, 0.0, k)
	if is_dead and _death_cam_active:
		_death_cam_blend = move_toward(_death_cam_blend, 1.0, delta / maxf(DEATH_CAM_ZOOM_TIME, 0.05))
		_apply_death_camera()
	else:
		_apply_camera_rotation()


func _sync_model_yaw() -> void:
	if model_root == null or head == null:
		return
	# Model yaw follows head look direction so body turns with the camera
	model_root.rotation.y = head.rotation.y


func _apply_camera_rotation() -> void:
	if camera == null or head == null:
		return
	_look_pitch = clamp(_look_pitch, deg_to_rad(-89.0), deg_to_rad(89.0))
	if third_person and is_local_player:
		_apply_minecraft_third_person_camera()
	else:
		# First person: camera under head
		_ensure_camera_parent(head)
		camera.rotation = Vector3(_look_pitch, 0.0, 0.0)
		camera.position = Vector3(0.0, _camera_base_y + _cam_bob_y, 0.0)


func _apply_death_camera() -> void:
	## First-person death: zoom out and track the ragdoll (hips).
	if camera == null:
		return
	_ensure_camera_parent(self)
	var pivot := global_position + Vector3.UP * 1.0
	if _character_model and _character_model.has_method("get_ragdoll_pivot_global"):
		pivot = _character_model.get_ragdoll_pivot_global()
	var yaw := head.rotation.y if head else 0.0
	var pitch := clampf(_look_pitch, deg_to_rad(-60.0), deg_to_rad(20.0))
	var dist := lerpf(1.2, DEATH_CAM_DISTANCE, _death_cam_blend)
	var height := lerpf(0.4, DEATH_CAM_HEIGHT, _death_cam_blend)
	var offset := Vector3(0.0, height, dist)
	offset = offset.rotated(Vector3.RIGHT, pitch * 0.35)
	offset = offset.rotated(Vector3.UP, yaw)
	var target_pos := pivot + offset
	var space := get_world_3d().direct_space_state
	if space:
		var q := PhysicsRayQueryParameters3D.create(pivot + Vector3.UP * 0.2, target_pos)
		q.exclude = [self]
		# World geometry only — ragdoll limbs are on layers 2/4 and caused the death-cam flicker.
		q.collision_mask = 1
		var hit := space.intersect_ray(q)
		if hit:
			target_pos = hit.position + hit.normal * 0.2
	camera.global_position = target_pos
	camera.look_at(pivot, Vector3.UP)


func _apply_minecraft_third_person_camera() -> void:
	# Orbit around eye pivot like Minecraft (yaw + pitch), camera not parented under head pitch
	_ensure_camera_parent(self)
	var eye_height := lerpf(STAND_EYE_HEIGHT, CROUCH_EYE_HEIGHT, crouch_blend)
	var pivot := global_position + Vector3(0.0, eye_height + _cam_bob_y * 0.25, 0.0)
	var yaw := head.rotation.y
	var pitch := _look_pitch
	# Offset behind the look direction, then rotate by yaw/pitch
	var offset := Vector3(TP_SIDE, 0.0, TP_DISTANCE)
	offset = offset.rotated(Vector3.RIGHT, pitch)
	offset = offset.rotated(Vector3.UP, yaw)
	offset.y += TP_HEIGHT * 0.25
	var target_pos := pivot + offset
	# Soft collision: pull in if something is between pivot and camera
	var space := get_world_3d().direct_space_state
	if space:
		var q := PhysicsRayQueryParameters3D.create(pivot, target_pos)
		q.exclude = [self]
		var hit := space.intersect_ray(q)
		if hit:
			target_pos = hit.position + hit.normal * 0.15
	camera.global_position = target_pos
	camera.look_at(pivot, Vector3.UP)


func _ensure_camera_parent(new_parent: Node) -> void:
	if camera == null or new_parent == null:
		return
	if camera.get_parent() == new_parent:
		return
	var gpos := camera.global_position
	var grot := camera.global_rotation
	camera.reparent(new_parent, true)
	# Keep continuity; caller sets final transform
	camera.global_position = gpos
	camera.global_rotation = grot


func _add_camera_bob(amount: float) -> void:
	if not is_local_player:
		return
	_cam_bob_y += amount
	_apply_camera_rotation()


func _setup_step_audio_pools() -> void:
	# Default stream arrays from concrete footsteps if not set in the inspector
	if footstep_streams.is_empty():
		for i in range(1, 5):
			var path := "res://assets/sounds/footsteps/concrete_footstep_%d.ogg" % i
			if ResourceLoader.exists(path):
				var s: AudioStream = load(path) as AudioStream
				if s:
					footstep_streams.append(s)
	if land_streams.is_empty():
		# Reuse footstep clips for lands until dedicated land SFXes exist
		land_streams = footstep_streams.duplicate()
	for p in [footstep_player, land_player]:
		if p == null:
			continue
		if p is Node3D:
			(p as Node3D).position = Vector3(0.0, 0.08, 0.0)
		if p.get("max_polyphony") != null:
			p.max_polyphony = STEP_POLYPHONY


func _has_ground_underfoot() -> bool:
	## True only when a surface is under the feet. Mutes steps when buried / no floor.
	if Commands.noclip_enabled:
		return false
	if not is_on_floor():
		return false
	var space := get_world_3d().direct_space_state
	if space == null:
		return is_on_floor()
	var from := global_position + Vector3.UP * 0.25
	var to := global_position + Vector3.DOWN * FOOTSTEP_GROUND_RAY
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [self]
	var hit := space.intersect_ray(q)
	return not hit.is_empty()


func _update_footsteps(delta: float) -> void:
	if Commands.noclip_enabled or is_dead:
		return

	var on_floor := is_on_floor()
	var speed := Vector3(velocity.x, 0.0, velocity.z).length()

	# Walking footsteps only in FLOOR state (landing step is handled in _process_landing)
	var allow_walk_steps := active_state == STATE.FLOOR
	var moving := on_floor and allow_walk_steps and speed >= MIN_MOVE_SPEED and _has_ground_underfoot()

	if moving:
		_walk_move_time += delta
		# Quiet startup: no steps until you've been moving for WALK_STEP_DELAY
		if _walk_move_time < WALK_STEP_DELAY:
			_step_timer = STEP_INTERVAL
			return
		_step_timer -= delta
		if _step_timer <= 0.0:
			_play_step_sound("walk", 0.35)
			_step_timer = STEP_INTERVAL
	else:
		_walk_move_time = 0.0
		if not on_floor:
			_step_timer = STEP_INTERVAL


## kind: "walk" | "jump" | "land", intensity 0..1 (used for land impact)
func _play_step_sound(kind: String, intensity: float = 0.0) -> void:
	# Ground gate for walk/jump; land always tries (just hit floor)
	if kind != "land" and not _has_ground_underfoot():
		return
	_play_step_sound_local(kind, intensity)
	if multiplayer.multiplayer_peer != null and is_multiplayer_authority() and PlayerManager:
		PlayerManager.broadcast_step_sound(multiplayer.get_unique_id(), kind, intensity)


func play_network_footstep() -> void:
	# Back-compat for plain footstep RPCs
	_play_step_sound_local("walk", 0.35)


func play_network_step_sound(kind: String, intensity: float = 0.0) -> void:
	_play_step_sound_local(kind, intensity)


func _pick_stream(streams: Array[AudioStream]) -> AudioStream:
	if streams.is_empty():
		return null
	return streams[randi() % streams.size()]


func _play_step_sound_local(kind: String, intensity: float = 0.0) -> void:
	var player: Node = land_player if kind == "land" else footstep_player
	var streams: Array[AudioStream] = land_streams if kind == "land" else footstep_streams
	if player == null:
		return
	var stream: AudioStream = _pick_stream(streams)
	if stream == null:
		return

	var vol: float = 0.0
	var pitch: float = 1.0
	match kind:
		"jump":
			vol = JUMP_SOUND_VOLUME_DB
			pitch = 1.05
		"land":
			var t: float = clampf(intensity, 0.0, 1.0)
			vol = lerpf(LAND_MIN_VOLUME_DB, LAND_MAX_VOLUME_DB, t)
			pitch = lerpf(LAND_MIN_PITCH, LAND_MAX_PITCH, t)
			if t < 0.2:
				vol = maxf(vol, -4.0)
		_:
			vol = 0.0
			pitch = randf_range(0.97, 1.03)
	if "volume_db" in player:
		player.volume_db = vol
	if "pitch_scale" in player:
		player.pitch_scale = pitch
	# Assign clip then play; max_polyphony=3 allows overlap without extra nodes
	player.stream = stream
	player.play()


func _play_footstep() -> void:
	_play_step_sound("walk", 0.35)


# ============================================================
#  WEAPON INVENTORY (slots only — viewmodels later)
# ============================================================
func _select_weapon_slot(slot: int) -> void:
	if slot < 0 or slot > 2:
		return
	if current_weapon_slot == slot:
		return
	current_weapon_slot = slot
	_refresh_weapon_hud()


func _ensure_crosshair() -> void:
	if not is_local_player:
		return
	var hud := get_node_or_null("Base Hud")
	var parent: Node = hud.get_node_or_null("Control") if hud else null
	if parent == null:
		return
	var existing := parent.get_node_or_null("CrosshairView")
	if existing:
		existing.visible = true
		if CrosshairManager and existing.has_method("set_profile"):
			existing.set_profile(CrosshairManager.profile)
		return
	var view_script: Script = load("res://scripts/ui/crosshair_view.gd") as Script
	if view_script == null:
		return
	var view := Control.new()
	view.set_script(view_script)
	view.name = "CrosshairView"
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view.add_to_group("crosshair_views")
	parent.add_child(view)
	# Keep under weapon/health: draw in center without blocking
	parent.move_child(view, 0)
	if CrosshairManager:
		view.set_profile(CrosshairManager.profile)


func _ensure_weapon_hud() -> void:
	if not is_local_player:
		return
	if _weapon_hud and is_instance_valid(_weapon_hud):
		_weapon_hud.visible = true
		_refresh_weapon_hud()
		return
	var hud := get_node_or_null("Base Hud")
	var parent: Node = hud.get_node_or_null("Control") if hud else null
	if parent == null:
		return
	_weapon_hud = VBoxContainer.new()
	_weapon_hud.name = "WeaponInventory"
	_weapon_hud.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_weapon_hud.anchor_left = 1.0
	_weapon_hud.anchor_right = 1.0
	_weapon_hud.anchor_top = 0.5
	_weapon_hud.anchor_bottom = 0.5
	_weapon_hud.offset_left = -180.0
	_weapon_hud.offset_right = -24.0
	_weapon_hud.offset_top = -70.0
	_weapon_hud.offset_bottom = 70.0
	_weapon_hud.add_theme_constant_override("separation", 6)
	_weapon_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(_weapon_hud)

	_weapon_slot_labels.clear()
	for i in range(3):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_weapon_hud.add_child(row)

		var key := Label.new()
		key.text = str(i + 1)
		key.custom_minimum_size = Vector2(28, 0)
		key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		key.add_theme_font_size_override("font_size", 18)
		row.add_child(key)

		var name_l := Label.new()
		name_l.text = WEAPON_SLOT_NAMES[i]
		name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_l.add_theme_font_size_override("font_size", 20)
		row.add_child(name_l)
		_weapon_slot_labels.append({"key": key, "name": name_l})

	_refresh_weapon_hud()


func _refresh_weapon_hud() -> void:
	if _weapon_hud == null or not is_instance_valid(_weapon_hud):
		return
	for i in range(_weapon_slot_labels.size()):
		var entry: Dictionary = _weapon_slot_labels[i]
		var active := i == current_weapon_slot
		var col := Color(1.0, 0.9, 0.35) if active else Color(0.75, 0.75, 0.8, 0.7)
		var size := 22 if active else 18
		if entry.key:
			entry.key.add_theme_color_override("font_color", col)
			entry.key.add_theme_font_size_override("font_size", size)
		if entry.name:
			entry.name.add_theme_color_override("font_color", col)
			entry.name.add_theme_font_size_override("font_size", size + 2)
			entry.name.text = WEAPON_SLOT_NAMES[i] + ("  ◂" if active else "")


# ============================================================
#  ESCAPE MENU
# ============================================================
func _on_escape_menu_is_open() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_escape_menu_is_not_open() -> void:
	if _ui_blocks_gameplay():
		return
	if is_local_player:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_console_toggled(is_shown: bool) -> void:
	if not is_local_player:
		return
	if is_shown:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif not _ui_blocks_gameplay():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_chat_opened() -> void:
	if is_local_player:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_chat_closed() -> void:
	if not is_local_player:
		return
	if _ui_blocks_gameplay():
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
