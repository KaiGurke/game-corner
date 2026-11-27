extends PathFollow3D

@export var speed: float = 3.0

func _process(delta: float) -> void:
	# In multiplayer only the authority (host) advances the path; clients receive progress via sync.
	if multiplayer.multiplayer_peer != null \
		and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
		and not is_multiplayer_authority():
		return
	progress += speed * delta
	if progress_ratio >= 1.0:
		progress_ratio = 0.0
