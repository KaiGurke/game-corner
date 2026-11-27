extends Node
class_name ChatImageLoader
## Downloads remote images (png/jpg/webp/gif) for chat embeds.
## GIFs are decoded with ChatGifDecoder into AnimatedTexture.

signal image_ready(url: String, texture: Texture2D)
signal image_failed(url: String, reason: String)

const CACHE_DIR := "user://chat_img_cache"
const MAX_CACHE_FILES := 64

var _cache: Dictionary = {}  # url -> Texture2D
var _inflight: Dictionary = {}  # url -> true


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)


func get_cached(url: String) -> Texture2D:
	var clean := url.strip_edges()
	if _cache.has(clean):
		return _cache[clean] as Texture2D
	return null


func request_image(url: String) -> void:
	var clean := url.strip_edges()
	if clean.is_empty():
		image_failed.emit(url, "empty")
		return
	if _cache.has(clean):
		call_deferred("_emit_ready", clean, _cache[clean])
		return
	if _inflight.has(clean):
		return
	_inflight[clean] = true
	var http := HTTPRequest.new()
	http.timeout = 15.0
	http.use_threads = true
	add_child(http)
	http.request_completed.connect(_on_request_completed.bind(clean, http))
	var headers := PackedStringArray([
		"User-Agent: GameCornerChat/1.0",
		"Accept: image/*,*/*",
	])
	var err := http.request(clean, headers)
	if err != OK:
		_inflight.erase(clean)
		http.queue_free()
		call_deferred("_emit_failed", clean, "request_error_%s" % err)


func _emit_ready(url: String, tex: Texture2D) -> void:
	image_ready.emit(url, tex)


func _emit_failed(url: String, reason: String) -> void:
	image_failed.emit(url, reason)


func _on_request_completed(
	result: int,
	response_code: int,
	headers: PackedStringArray,
	body: PackedByteArray,
	url: String,
	http: HTTPRequest
) -> void:
	if is_instance_valid(http):
		http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_inflight.erase(url)
		image_failed.emit(url, "http_%s" % response_code)
		return
	if body.is_empty():
		_inflight.erase(url)
		image_failed.emit(url, "empty_body")
		return

	var content_type := _header_value(headers, "content-type").to_lower()

	# GIFs: decode off the main thread. Keep _inflight set until finished.
	var ext := _path_ext(url)
	if _is_gif_bytes(body):
		_decode_gif_async(url, body)
		return

	_inflight.erase(url)
	var tex := _texture_from_bytes(body, content_type, url)
	if tex == null:
		image_failed.emit(url, "decode_failed")
		return
	_cache[url] = tex
	_prune_cache_files()
	image_ready.emit(url, tex)


func _decode_gif_async(url: String, body: PackedByteArray) -> void:
	var task_id := WorkerThreadPool.add_task(
		func() -> Dictionary:
			return ChatGifDecoder.decode(body)
	)
	while not WorkerThreadPool.is_task_completed(task_id):
		await get_tree().process_frame
	var decoded: Variant = WorkerThreadPool.wait_for_task_completion(task_id)
	var d: Dictionary = {}
	if typeof(decoded) == TYPE_DICTIONARY:
		d = decoded

	# Fallback: if the worker path returned nothing, try a tight sync decode once.
	if d.is_empty() or d.get("frames_rgba", []).is_empty():
		push_warning("ChatImageLoader: worker GIF decode failed, retrying sync (%d bytes) %s" % [body.size(), url])
		d = ChatGifDecoder.decode(body)

	_inflight.erase(url)

	if d.is_empty():
		push_warning("ChatImageLoader: GIF decode failed completely %s" % url)
		image_failed.emit(url, "gif_decode_failed")
		return

	var frames_rgba: Array = d.get("frames_rgba", [])
	var delays: Array = d.get("delays", [])
	var cw := int(d.get("width", 0))
	var ch := int(d.get("height", 0))
	if frames_rgba.is_empty() or cw <= 0 or ch <= 0:
		push_warning("ChatImageLoader: GIF had no frames %s" % url)
		image_failed.emit(url, "gif_no_frames")
		return

	var scale := 1.0
	if cw > ChatGifDecoder.MAX_WIDTH or ch > ChatGifDecoder.MAX_HEIGHT:
		scale = minf(float(ChatGifDecoder.MAX_WIDTH) / float(cw), float(ChatGifDecoder.MAX_HEIGHT) / float(ch))
	var tw := maxi(1, int(cw * scale))
	var th := maxi(1, int(ch * scale))

	var textures: Array = []
	for rgba in frames_rgba:
		if typeof(rgba) != TYPE_PACKED_BYTE_ARRAY:
			continue
		var raw: PackedByteArray = rgba
		if raw.size() < cw * ch * 4:
			continue
		var img := Image.create_from_data(cw, ch, false, Image.FORMAT_RGBA8, raw)
		if scale < 0.999:
			img.resize(tw, th, Image.INTERPOLATE_BILINEAR)
		textures.append(ImageTexture.create_from_image(img))
		if textures.size() % 8 == 0:
			await get_tree().process_frame

	if textures.is_empty():
		image_failed.emit(url, "gif_no_frames")
		return

	var tex: Texture2D
	if textures.size() == 1:
		tex = textures[0] as Texture2D
	else:
		var anim := AnimatedTexture.new()
		anim.frames = mini(textures.size(), 256)
		anim.one_shot = false
		anim.pause = false
		for i in range(anim.frames):
			anim.set_frame_texture(i, textures[i] as Texture2D)
			var delay_s := 0.1
			if i < delays.size():
				delay_s = maxf(float(delays[i]), 0.02)
			anim.set_frame_duration(i, delay_s)
		tex = anim

	_cache[url] = tex
	_prune_cache_files()
	image_ready.emit(url, tex)


func _header_value(headers: PackedStringArray, key: String) -> String:
	var k := key.to_lower()
	for h in headers:
		var parts := h.split(":", true, 1)
		if parts.size() == 2 and parts[0].strip_edges().to_lower() == k:
			return parts[1].strip_edges()
	return ""


func _path_ext(url: String) -> String:
	## Strip query/fragment then return lowercased extension including dot.
	var u := url.to_lower().strip_edges()
	var q := u.find("?")
	if q >= 0:
		u = u.substr(0, q)
	var h := u.find("#")
	if h >= 0:
		u = u.substr(0, h)
	var slash := u.rfind("/")
	var name := u.substr(slash + 1) if slash >= 0 else u
	var dot := name.rfind(".")
	if dot < 0:
		return ""
	return name.substr(dot)


func _is_gif_bytes(body: PackedByteArray) -> bool:
	return body.size() >= 6 and body[0] == 0x47 and body[1] == 0x49 and body[2] == 0x46 \
			and body[3] == 0x38 and (body[4] == 0x39 or body[4] == 0x37) and body[5] == 0x61


func _texture_from_bytes(body: PackedByteArray, content_type: String, url: String) -> Texture2D:
	var ext := _path_ext(url)
	var ct := content_type

	# GIFs are handled async in _on_request_completed — never sync-decode here.
	if _is_gif_bytes(body):
		return null

	# --- Magic-byte based static formats (no noisy multi-probe) ---
	if _is_png(body) or ct.find("png") >= 0 or ext == ".png":
		var img_png := Image.new()
		if img_png.load_png_from_buffer(body) == OK and not img_png.is_empty():
			return ImageTexture.create_from_image(img_png)

	if _is_jpeg(body) or ct.find("jpeg") >= 0 or ct.find("jpg") >= 0 \
			or ext == ".jpg" or ext == ".jpeg":
		var img_jpg := Image.new()
		if img_jpg.load_jpg_from_buffer(body) == OK and not img_jpg.is_empty():
			return ImageTexture.create_from_image(img_jpg)

	if _is_webp(body) or ct.find("webp") >= 0 or ext == ".webp":
		var img_webp := Image.new()
		if img_webp.load_webp_from_buffer(body) == OK and not img_webp.is_empty():
			return ImageTexture.create_from_image(img_webp)

	if ct.find("bmp") >= 0 or ext == ".bmp":
		var img_bmp := Image.new()
		if img_bmp.load_bmp_from_buffer(body) == OK and not img_bmp.is_empty():
			return ImageTexture.create_from_image(img_bmp)

	# Last resort: try GIF magic again, then silent single probes
	if _is_gif_bytes(body):
		var anim2 := _decode_gif_animated(body)
		if anim2:
			return anim2

	return null


func _decode_gif_animated(body: PackedByteArray) -> Texture2D:
	## Sync path kept as fallback (prefer _decode_gif_async).
	var decoded: Dictionary = ChatGifDecoder.decode(body)
	if decoded.is_empty():
		return null
	var frames: Array = decoded.get("frames", [])
	var delays: Array = decoded.get("delays", [])
	if frames.is_empty():
		return null
	if frames.size() == 1:
		return frames[0] as Texture2D
	var anim := AnimatedTexture.new()
	anim.frames = mini(frames.size(), 256)
	anim.one_shot = false
	anim.pause = false
	for i in range(anim.frames):
		anim.set_frame_texture(i, frames[i] as Texture2D)
		var d := 0.1
		if i < delays.size():
			d = maxf(float(delays[i]), 0.02)
		anim.set_frame_duration(i, d)
	return anim


func _is_png(body: PackedByteArray) -> bool:
	return body.size() >= 8 and body[0] == 0x89 and body[1] == 0x50 and body[2] == 0x4E and body[3] == 0x47


func _is_jpeg(body: PackedByteArray) -> bool:
	return body.size() >= 3 and body[0] == 0xFF and body[1] == 0xD8 and body[2] == 0xFF


func _is_webp(body: PackedByteArray) -> bool:
	# RIFF....WEBP
	return body.size() >= 12 and body[0] == 0x52 and body[1] == 0x49 and body[2] == 0x46 and body[3] == 0x46 \
			and body[8] == 0x57 and body[9] == 0x45 and body[10] == 0x42 and body[11] == 0x50


func _prune_cache_files() -> void:
	var dir := DirAccess.open(CACHE_DIR)
	if dir == null:
		return
	var files: Array = []
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if not dir.current_is_dir():
			files.append(n)
		n = dir.get_next()
	dir.list_dir_end()
	if files.size() <= MAX_CACHE_FILES:
		return
	files.sort()
	while files.size() > MAX_CACHE_FILES:
		var victim: String = files.pop_front()
		dir.remove(victim)
