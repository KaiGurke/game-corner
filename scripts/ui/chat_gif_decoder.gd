extends RefCounted
class_name ChatGifDecoder
## Pure-GDScript GIF87a/89a decoder for chat embeds.
## Safe to call from WorkerThreadPool. Uses raw RGBA buffers (not set_pixel).
## Returns { "frames": Array[ImageTexture], "delays": Array[float] } or {}.

const MAX_FRAMES := 48
const MAX_WIDTH := 320
const MAX_HEIGHT := 320
const REJECT_WIDTH := 2048
const REJECT_HEIGHT := 2048


static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 13:
		return {}
	if not (bytes[0] == 0x47 and bytes[1] == 0x49 and bytes[2] == 0x46 and bytes[3] == 0x38 \
			and (bytes[4] == 0x39 or bytes[4] == 0x37) and bytes[5] == 0x61):
		return {}

	var r := _BitReader.new(bytes)
	r.pos = 6

	var width := r.read_u16()
	var height := r.read_u16()
	if width <= 0 or height <= 0 or width > REJECT_WIDTH or height > REJECT_HEIGHT:
		return {}

	var packed := r.read_u8()
	r.read_u8()
	r.read_u8()

	var gct_flag := (packed & 0x80) != 0
	var gct_size := 1 << ((packed & 0x07) + 1)
	var gct := PackedByteArray()
	if gct_flag:
		gct = r.read_bytes(gct_size * 3)
		if gct.size() < gct_size * 3:
			return {}

	var cw := width
	var ch := height
	var canvas := PackedByteArray()
	canvas.resize(cw * ch * 4)
	var backup := PackedByteArray()

	var frames_rgba: Array = []
	var delays: Array = []

	var delay_cs := 10
	var transparent_index := -1
	var disposal := 0

	var guard := 0
	while r.pos < r.data.size() and guard < MAX_FRAMES + 64:
		guard += 1
		var intro := r.read_u8()
		if intro == 0x3B:
			break
		if intro == 0x21:
			var label := r.read_u8()
			if label == 0xF9:
				var bs := r.read_u8()
				if bs >= 4:
					var flags := r.read_u8()
					delay_cs = r.read_u16()
					if delay_cs < 2:
						delay_cs = 10
					var tidx := r.read_u8()
					disposal = (flags >> 2) & 0x07
					transparent_index = tidx if (flags & 0x01) != 0 else -1
					for _i in range(bs - 4):
						r.read_u8()
				r.read_u8()
			else:
				r.skip_data_sub_blocks()
			continue
		if intro != 0x2C:
			continue

		var left := r.read_u16()
		var top := r.read_u16()
		var iw := r.read_u16()
		var ih := r.read_u16()
		var ipacked := r.read_u8()
		if iw <= 0 or ih <= 0:
			if (ipacked & 0x80) != 0:
				r.read_bytes((1 << ((ipacked & 0x07) + 1)) * 3)
			r.read_u8()
			r.skip_data_sub_blocks()
			continue

		var interlace := (ipacked & 0x40) != 0
		var lct := PackedByteArray()
		if (ipacked & 0x80) != 0:
			lct = r.read_bytes((1 << ((ipacked & 0x07) + 1)) * 3)

		var min_code_size := r.read_u8()
		var lzw_bytes := r.read_data_sub_blocks()
		if lzw_bytes.is_empty() or min_code_size < 2 or min_code_size > 8:
			continue

		var indices := _lzw_decode(lzw_bytes, min_code_size, iw * ih)
		if indices.size() < iw * ih:
			var padded := PackedByteArray()
			padded.resize(iw * ih)
			for i in range(mini(indices.size(), padded.size())):
				padded[i] = indices[i]
			indices = padded

		if interlace:
			indices = _deinterlace(indices, iw, ih)

		var palette := lct if lct.size() >= 3 else gct
		if palette.size() < 3:
			continue

		match disposal:
			2:
				_clear_rect_rgba(canvas, cw, ch, left, top, iw, ih)
			3:
				if backup.size() == canvas.size():
					canvas = backup.duplicate()
			_:
				pass

		if disposal != 3:
			backup = canvas.duplicate()

		_blit_rgba(canvas, cw, ch, indices, left, top, iw, ih, palette, transparent_index)
		frames_rgba.append(canvas.duplicate())
		delays.append(float(delay_cs) / 100.0)

		if frames_rgba.size() >= MAX_FRAMES:
			break

	if frames_rgba.is_empty():
		return {}

	# Return raw RGBA — ImageTexture must be created on the main thread.
	return {
		"width": cw,
		"height": ch,
		"frames_rgba": frames_rgba,
		"delays": delays,
	}


static func _clear_rect_rgba(buf: PackedByteArray, cw: int, ch: int, x: int, y: int, w: int, h: int) -> void:
	var x1 := clampi(x, 0, cw)
	var y1 := clampi(y, 0, ch)
	var x2 := clampi(x + w, 0, cw)
	var y2 := clampi(y + h, 0, ch)
	for py in range(y1, y2):
		var row := py * cw * 4
		for px in range(x1, x2):
			var i := row + px * 4
			buf[i] = 0
			buf[i + 1] = 0
			buf[i + 2] = 0
			buf[i + 3] = 0


static func _blit_rgba(
	buf: PackedByteArray, cw: int, ch: int,
	indices: PackedByteArray,
	left: int, top: int, iw: int, ih: int,
	palette: PackedByteArray, trans: int
) -> void:
	var n := mini(indices.size(), iw * ih)
	for i in range(n):
		var idx := int(indices[i])
		if idx == trans:
			continue
		var px := left + (i % iw)
		var py := top + int(i / float(iw))
		if px < 0 or py < 0 or px >= cw or py >= ch:
			continue
		var pi := idx * 3
		if pi + 2 >= palette.size():
			continue
		var o := (py * cw + px) * 4
		buf[o] = palette[pi]
		buf[o + 1] = palette[pi + 1]
		buf[o + 2] = palette[pi + 2]
		buf[o + 3] = 255


static func _deinterlace(src: PackedByteArray, w: int, h: int) -> PackedByteArray:
	var dst := PackedByteArray()
	dst.resize(w * h)
	var offsets := [0, 4, 2, 1]
	var steps := [8, 8, 4, 2]
	var src_i := 0
	for p in range(4):
		var y = offsets[p]
		while y < h:
			for x in range(w):
				if src_i < src.size():
					dst[y * w + x] = src[src_i]
					src_i += 1
			y += steps[p]
	return dst


static func _lzw_decode(data: PackedByteArray, min_code_size: int, expected: int) -> PackedByteArray:
	var clear_code := 1 << min_code_size
	var end_code := clear_code + 1
	var code_size := min_code_size + 1
	var next_code := end_code + 1

	var dict: Array = []
	dict.resize(4096)
	for i in range(clear_code):
		dict[i] = PackedByteArray([i])

	var out := PackedByteArray()
	out.resize(maxi(expected, 64))
	var out_len := 0

	var bit_buf := 0
	var bit_count := 0
	var data_i := 0
	var prev_code := -1

	while out_len < expected:
		while bit_count < code_size:
			if data_i >= data.size():
				out.resize(out_len)
				return out
			bit_buf |= int(data[data_i]) << bit_count
			data_i += 1
			bit_count += 8
		var code: int = bit_buf & ((1 << code_size) - 1)
		bit_buf >>= code_size
		bit_count -= code_size

		if code == clear_code:
			code_size = min_code_size + 1
			next_code = end_code + 1
			for i in range(clear_code, 4096):
				dict[i] = null
			prev_code = -1
			continue
		if code == end_code:
			break

		var entry: PackedByteArray
		if code < next_code and dict[code] != null:
			entry = dict[code]
		elif code == next_code and prev_code >= 0 and dict[prev_code] != null:
			entry = (dict[prev_code] as PackedByteArray).duplicate()
			entry.append((dict[prev_code] as PackedByteArray)[0])
		else:
			break

		for b in entry:
			if out_len < out.size():
				out[out_len] = b
			else:
				out.append(b)
			out_len += 1
			if out_len >= expected:
				break

		if prev_code >= 0 and next_code < 4096 and dict[prev_code] != null:
			var neu: PackedByteArray = (dict[prev_code] as PackedByteArray).duplicate()
			neu.append(entry[0])
			dict[next_code] = neu
			next_code += 1
			if next_code >= (1 << code_size) and code_size < 12:
				code_size += 1

		prev_code = code

	out.resize(out_len)
	return out


class _BitReader:
	var data: PackedByteArray
	var pos: int = 0

	func _init(p: PackedByteArray) -> void:
		data = p
		pos = 0

	func read_u8() -> int:
		if pos >= data.size():
			return 0
		var v := int(data[pos])
		pos += 1
		return v

	func read_u16() -> int:
		return read_u8() | (read_u8() << 8)

	func read_bytes(n: int) -> PackedByteArray:
		var end := mini(pos + n, data.size())
		var s := data.slice(pos, end)
		pos = end
		return s

	func read_data_sub_blocks() -> PackedByteArray:
		var out := PackedByteArray()
		while pos < data.size():
			var sz := read_u8()
			if sz == 0:
				break
			out.append_array(read_bytes(sz))
		return out

	func skip_data_sub_blocks() -> void:
		while pos < data.size():
			var sz := read_u8()
			if sz == 0:
				break
			pos = mini(pos + sz, data.size())
