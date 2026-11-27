class_name CharacterAnimController
extends RefCounted
## Maps player locomotion → animation names on CharacterModel.
## If the FBX has no clips yet, this still tracks logical state for multiplayer
## and will pick up Mixamo/retargeted clips when you add them.

enum State {
	IDLE,
	WALK,
	RUN,
	JUMP,
	FALL,
	CROUCH_IDLE,
	CROUCH_WALK,
	DEAD,
}

const STATE_NAMES := {
	State.IDLE: "idle",
	State.WALK: "walk",
	State.RUN: "run",
	State.JUMP: "jump",
	State.FALL: "fall",
	State.CROUCH_IDLE: "crouch",
	State.CROUCH_WALK: "crouch_walk",
	State.DEAD: "death",
}

var state: int = State.IDLE
var _model: CharacterModel = null


func setup(model: CharacterModel) -> void:
	_model = model


func set_state(new_state: int, speed_scale: float = 1.0) -> void:
	state = new_state
	if _model == null:
		return
	var anim: String = STATE_NAMES.get(new_state, "idle")
	_model.play_animation(anim, 0.2, speed_scale)


func update_from_locomotion(
	velocity: Vector3,
	on_floor: bool,
	crouching: bool,
	dead: bool,
	max_speed: float
) -> void:
	if dead:
		# Hold last pose — death uses ragdoll later, no death clip
		return
	var horizontal := Vector3(velocity.x, 0.0, velocity.z).length()
	if not on_floor:
		if velocity.y > 0.5:
			set_state(State.JUMP)
		else:
			set_state(State.FALL)
		return
	if crouching:
		if horizontal > 0.4:
			set_state(State.CROUCH_WALK, clampf(horizontal / maxf(max_speed * 0.5, 0.01), 0.6, 1.4))
		else:
			set_state(State.CROUCH_IDLE)
		return
	if horizontal < 0.4:
		set_state(State.IDLE)
	elif horizontal < max_speed * 0.75:
		set_state(State.WALK, clampf(horizontal / maxf(max_speed * 0.5, 0.01), 0.7, 1.5))
	else:
		set_state(State.RUN, clampf(horizontal / maxf(max_speed, 0.01), 0.8, 1.5))


func apply_network_state(state_id: int, speed_scale: float = 1.0) -> void:
	set_state(state_id, speed_scale)
