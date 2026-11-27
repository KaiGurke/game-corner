class_name CSController
extends CharacterBody3D
## Counter-Strike (Source engine: CS:S / CS:GO style) movement for Godot 4.x.
##
## Scene setup:
##   CSPlayerController (CharacterBody3D, this script)
##   ├─ CollisionShape3D      (shape is created/overwritten by this script)
##   └─ Head (Node3D)
##      └─ Camera3D
##
## All Source constants are kept in Source units (1 unit = 0.01905 m)
## and converted to metres via U. Set Project Settings > Physics >
## Common > Physics Ticks Per Second to 64 (or enable match_tickrate).

const U := 0.01905 # metres per Source unit

# --- Source cvars ---------------------------------------------------------
const SV_ACCELERATE := 5.5
const SV_AIRACCELERATE := 12.0
const SV_FRICTION := 5.2
const SV_STOPSPEED := 80.0
const SV_GRAVITY := 800.0
const SV_MAXVELOCITY := 3500.0
const AIR_SPEED_CAP := 30.0 # the "30 u/s" air wishspeed clamp that enables strafing
const JUMP_SPEED := 301.993377 # sqrt(2 * 800 * 57)
const STEP_SIZE := 18.0
const WALKABLE_ANGLE := 45.573 # acos(0.7), Source's max walkable slope

# --- CS player hull -------------------------------------------------------
const WALK_MULT := 0.52 # +speed / shift-walk
const DUCK_MULT := 0.34
const STAND_HEIGHT := 72.0
const DUCK_HEIGHT := 54.0
const STAND_EYE := 64.0
const DUCK_EYE := 46.0
const HULL_RADIUS := 16.0

# Crouch-spam penalty (CS2-style). These are tunable guesses, not datamined values.
const DUCK_SPEED_IDEAL := 8.0 # duck_amount per second when unpenalised (0.125 s full crouch)
const DUCK_SPEED_MIN := 1.0 # slowest possible crouch (1 s for a full crouch)
const DUCK_TOGGLE_PENALTY := 2.0 # duck speed lost each time crouch is pressed or released
const DUCK_SPEED_RECOVERY := 2.5 # duck speed regained per second while not toggling

@export var weapon_max_speed := 250.0 # knife 250, rifles ~215-240, AWP ~200
@export var mouse_sensitivity := 1.0 # CS sensitivity
@export var m_yaw := 0.022 # degrees per mouse count (CS default m_yaw/m_pitch)
@export var auto_bhop := false # real CS needs a fresh jump press each hop
@export var match_tickrate := true
@export var tickrate := 64

@onready var shape_node: CollisionShape3D = $CollisionShape3D
@onready var head: Node3D = $Head

var duck_amount := 0.0 # 0 = standing, 1 = fully crouched
var duck_speed := DUCK_SPEED_IDEAL # current crouch transition speed (drops when spamming)
var _duck_held := false
var _capsule := CapsuleShape3D.new()


func _ready() -> void:
	_ensure_input_actions()
	if match_tickrate:
		Engine.physics_ticks_per_second = tickrate

	# Floor behaviour tuned to feel like Source
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	floor_max_angle = deg_to_rad(WALKABLE_ANGLE)
	floor_snap_length = STEP_SIZE * U
	floor_stop_on_slope = false
	floor_constant_speed = false
	floor_block_on_wall = false
	max_slides = 4
	safe_margin = 0.002

	_capsule.radius = HULL_RADIUS * U
	shape_node.shape = _capsule
	_set_hull()
	head.position.y = STAND_EYE * U
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var m := event as InputEventMouseMotion
		rotate_y(deg_to_rad(-m.relative.x * m_yaw * mouse_sensitivity))
		head.rotation.x = clampf(
			head.rotation.x + deg_to_rad(-m.relative.y * m_yaw * mouse_sensitivity),
			deg_to_rad(-89.0), deg_to_rad(89.0))
	elif event.is_action_pressed("escape_menu"): # Opens the escape menu
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(dt: float) -> void:
	_update_duck(dt)

	var on_ground := is_on_floor()

	# --- wish velocity (Source: forward/right * cmd, clamped to maxspeed) ---
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var wishdir := global_transform.basis * Vector3(input.x, 0.0, input.y)
	wishdir.y = 0.0
	wishdir = wishdir.normalized()

	var max_speed := weapon_max_speed
	if Input.is_action_pressed("walk"):
		max_speed *= WALK_MULT
	if on_ground:
		max_speed *= lerpf(1.0, DUCK_MULT, duck_amount)
	var wishspeed := input.length() * max_speed * U

	# --- StartGravity (half step) ---
	if not on_ground:
		velocity.y -= SV_GRAVITY * U * dt * 0.5

	# --- Jump (happens BEFORE friction, so bhopping skips friction) ---
	if on_ground and _jump_requested():
		velocity.y = JUMP_SPEED * U
		on_ground = false

	if on_ground:
		velocity.y = 0.0
		_friction(dt)
		_accelerate(wishdir, wishspeed, SV_ACCELERATE, dt)
	else:
		_air_accelerate(wishdir, wishspeed, SV_AIRACCELERATE, dt)

	# Source's sv_maxvelocity clamp per axis
	var maxv := SV_MAXVELOCITY * U
	velocity = velocity.clamp(Vector3(-maxv, -maxv, -maxv), Vector3(maxv, maxv, maxv))

	if on_ground:
		_try_step_up(dt)

	move_and_slide()

	# --- FinishGravity (second half step) ---
	if not is_on_floor():
		velocity.y -= SV_GRAVITY * U * dt * 0.5


# ---------------------------------------------------------------------------
# Source movement primitives (gamemovement.cpp equivalents)
# ---------------------------------------------------------------------------

func _friction(dt: float) -> void:
	var speed := Vector3(velocity.x, 0.0, velocity.z).length()
	if speed < 0.1 * U:
		return
	var control := maxf(speed, SV_STOPSPEED * U)
	var drop := control * SV_FRICTION * dt # surface friction assumed 1.0
	var newspeed := maxf(speed - drop, 0.0)
	var speed_ratio := newspeed / speed
	velocity.x *= speed_ratio
	velocity.z *= speed_ratio


func _accelerate(wishdir: Vector3, wishspeed: float, accel: float, dt: float) -> void:
	var current := velocity.dot(wishdir)
	var addspeed := wishspeed - current
	if addspeed <= 0.0:
		return
	var accelspeed := minf(accel * dt * wishspeed, addspeed)
	velocity += wishdir * accelspeed


func _air_accelerate(wishdir: Vector3, wishspeed: float, accel: float, dt: float) -> void:
	# The wishspeed is clamped to 30 u/s ONLY when computing how much speed
	# can be added. The accel step still scales with the unclamped wishspeed.
	# This is what allows airstrafing / bunnyhopping to gain speed.
	var capped := minf(wishspeed, AIR_SPEED_CAP * U)
	var current := velocity.dot(wishdir)
	var addspeed := capped - current
	if addspeed <= 0.0:
		return
	var accelspeed := minf(accel * wishspeed * dt, addspeed)
	velocity += wishdir * accelspeed


func _jump_requested() -> bool:
	if auto_bhop:
		return Input.is_action_pressed("jump")
	return Input.is_action_just_pressed("jump")


# ---------------------------------------------------------------------------
# Stairs / steps (Source's StepMove, simplified)
# ---------------------------------------------------------------------------

func _try_step_up(dt: float) -> void:
	var horiz := Vector3(velocity.x, 0.0, velocity.z) * dt
	if horiz.length_squared() < 1e-8:
		return
	if not test_move(global_transform, horiz):
		return # nothing in the way

	# Probe far enough that the capsule's rounded bottom ends up fully over the
	# step. With a short probe it lands on the step's edge, and the contact
	# normal looks like a steep slope, so the step gets rejected.
	var probe := horiz.normalized() * maxf(horiz.length(), HULL_RADIUS * U * 1.25)

	var step := STEP_SIZE * U
	if test_move(global_transform, Vector3.UP * step):
		return # no headroom
	var raised := global_transform.translated(Vector3.UP * step)
	if test_move(raised, probe):
		return # still blocked at step height

	var landing := KinematicCollision3D.new()
	var after := raised.translated(probe)
	if not test_move(after, Vector3.DOWN * step, landing):
		return # no ground to land on
	if landing.get_normal().y < cos(deg_to_rad(WALKABLE_ANGLE)):
		return # landing surface too steep

	global_position.y += step - landing.get_travel().length()


# ---------------------------------------------------------------------------
# Ducking
# ---------------------------------------------------------------------------

func _update_duck(dt: float) -> void:
	var want_duck := Input.is_action_pressed("crouch")

	# Every press or release costs duck speed; it slowly recovers while idle.
	if want_duck != _duck_held:
		_duck_held = want_duck
		duck_speed = maxf(DUCK_SPEED_MIN, duck_speed - DUCK_TOGGLE_PENALTY)
	else:
		duck_speed = minf(DUCK_SPEED_IDEAL, duck_speed + DUCK_SPEED_RECOVERY * dt)

	var target := 1.0 if want_duck else 0.0
	var new_amount := move_toward(duck_amount, target, duck_speed * dt)

	if new_amount < duck_amount:
		# Standing up: only grow the hull if there is headroom for it.
		var dh := _hull_height(new_amount) - _hull_height(duck_amount)
		if test_move(global_transform, Vector3.UP * dh):
			new_amount = duck_amount

	duck_amount = new_amount
	_set_hull()

	var eye := lerpf(STAND_EYE, DUCK_EYE, smoothstep(0.0, 1.0, duck_amount))
	head.position.y = eye * U


func _hull_height(amount: float) -> float:
	return lerpf(STAND_HEIGHT, DUCK_HEIGHT, amount) * U


func _set_hull() -> void:
	var h := _hull_height(duck_amount)
	_capsule.height = h
	shape_node.position.y = h * 0.5 # origin at the feet, like Source


# ---------------------------------------------------------------------------
# Input map bootstrap so the script works out of the box
# ---------------------------------------------------------------------------

func _ensure_input_actions() -> void:
	var keys := {
		"move_forward": KEY_W, "move_back": KEY_S,
		"move_left": KEY_A, "move_right": KEY_D,
		"jump": KEY_SPACE, "crouch": KEY_CTRL, "walk": KEY_SHIFT,
	}
	for action in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			var ev := InputEventKey.new()
			ev.physical_keycode = keys[action]
			InputMap.action_add_event(action, ev)
