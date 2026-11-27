extends RefCounted
class_name CrosshairProfile
## Valorant-style crosshair config: 5 elements + outlines + code import/export.

const CODE_PREFIX := "GCX1:"

## Element keys
const EL_DOT := "dot"
const EL_INNER_LINES := "inner_lines"
const EL_OUTER_LINES := "outer_lines"
const EL_INNER_CIRCLE := "inner_circle"
const EL_OUTER_CIRCLE := "outer_circle"
const ELEMENT_KEYS := [EL_DOT, EL_INNER_LINES, EL_OUTER_LINES, EL_INNER_CIRCLE, EL_OUTER_CIRCLE]

const ELEMENT_LABELS := {
	EL_DOT: "Center Dot",
	EL_INNER_LINES: "Inner Lines",
	EL_OUTER_LINES: "Outer Lines",
	EL_INNER_CIRCLE: "Inner Circle",
	EL_OUTER_CIRCLE: "Outer Circle",
}

var elements: Dictionary = {}  # key -> Dictionary of props
var name: String = "Custom"


static func default_element(kind: String) -> Dictionary:
	var e := {
		"enabled": false,
		"color": Color(0.0, 1.0, 0.0, 1.0),
		"opacity": 1.0,
		"thickness": 2.0,
		"outline_enabled": true,
		"outline_color": Color(0, 0, 0, 1),
		"outline_thickness": 1.0,
		# lines / dot
		"size": 2.0,       # dot diameter; circle stroke uses thickness
		"length": 6.0,     # line length
		"gap": 3.0,        # distance from center to start of line / circle gap
		"radius": 20.0,    # circle radius
	}
	match kind:
		EL_DOT:
			e["enabled"] = true
			e["size"] = 2.0
		EL_INNER_LINES:
			e["enabled"] = true
			e["length"] = 6.0
			e["thickness"] = 2.0
			e["gap"] = 4.0
		EL_OUTER_LINES:
			e["enabled"] = false
			e["length"] = 4.0
			e["thickness"] = 2.0
			e["gap"] = 14.0
		EL_INNER_CIRCLE:
			e["enabled"] = false
			e["radius"] = 12.0
			e["thickness"] = 1.5
		EL_OUTER_CIRCLE:
			e["enabled"] = false
			e["radius"] = 28.0
			e["thickness"] = 1.5
	return e


static func make_default() -> CrosshairProfile:
	var p := CrosshairProfile.new()
	p.name = "Default"
	for k in ELEMENT_KEYS:
		p.elements[k] = default_element(k)
	return p


static func preset_list() -> Array:
	## Array of { "name": String, "profile": CrosshairProfile }
	var out: Array = []
	out.append({"name": "Default", "profile": make_default()})

	var dot := make_default()
	dot.name = "Dot"
	dot.elements[EL_INNER_LINES]["enabled"] = false
	dot.elements[EL_DOT]["size"] = 3.0
	out.append({"name": "Dot", "profile": dot})

	var cross := make_default()
	cross.name = "Cross"
	cross.elements[EL_DOT]["enabled"] = false
	cross.elements[EL_INNER_LINES]["length"] = 10.0
	cross.elements[EL_INNER_LINES]["gap"] = 2.0
	out.append({"name": "Cross", "profile": cross})

	var classic := make_default()
	classic.name = "Classic"
	classic.elements[EL_DOT]["enabled"] = true
	classic.elements[EL_INNER_LINES]["length"] = 5.0
	classic.elements[EL_INNER_LINES]["gap"] = 3.0
	classic.elements[EL_OUTER_LINES]["enabled"] = true
	classic.elements[EL_OUTER_LINES]["gap"] = 12.0
	classic.elements[EL_OUTER_LINES]["length"] = 3.0
	out.append({"name": "Classic", "profile": classic})

	var circle := make_default()
	circle.name = "Circle"
	circle.elements[EL_INNER_LINES]["enabled"] = false
	circle.elements[EL_DOT]["enabled"] = true
	circle.elements[EL_INNER_CIRCLE]["enabled"] = true
	circle.elements[EL_INNER_CIRCLE]["radius"] = 16.0
	out.append({"name": "Circle", "profile": circle})

	var tactical := make_default()
	tactical.name = "Tactical"
	tactical.elements[EL_DOT]["enabled"] = true
	tactical.elements[EL_DOT]["size"] = 1.5
	tactical.elements[EL_INNER_LINES]["length"] = 4.0
	tactical.elements[EL_INNER_LINES]["gap"] = 6.0
	tactical.elements[EL_INNER_LINES]["thickness"] = 1.5
	tactical.elements[EL_OUTER_CIRCLE]["enabled"] = true
	tactical.elements[EL_OUTER_CIRCLE]["radius"] = 32.0
	tactical.elements[EL_OUTER_CIRCLE]["thickness"] = 1.0
	tactical.elements[EL_OUTER_CIRCLE]["opacity"] = 0.6
	for k in ELEMENT_KEYS:
		tactical.elements[k]["color"] = Color(0.2, 1.0, 0.4, 1.0)
	out.append({"name": "Tactical", "profile": tactical})

	var cyan := make_default()
	cyan.name = "Cyan Cross"
	for k in ELEMENT_KEYS:
		cyan.elements[k]["color"] = Color(0.2, 0.9, 1.0, 1.0)
	cyan.elements[EL_DOT]["enabled"] = false
	cyan.elements[EL_INNER_LINES]["length"] = 8.0
	cyan.elements[EL_INNER_LINES]["gap"] = 3.0
	out.append({"name": "Cyan Cross", "profile": cyan})

	return out


func duplicate_profile() -> CrosshairProfile:
	var p := CrosshairProfile.new()
	p.name = name
	p.elements = _deep_copy_elements(elements)
	return p


func _deep_copy_elements(src: Dictionary) -> Dictionary:
	var out := {}
	for k in src.keys():
		var e: Dictionary = src[k]
		var ne := {}
		for pk in e.keys():
			var v = e[pk]
			if v is Color:
				ne[pk] = Color(v)
			else:
				ne[pk] = v
		out[k] = ne
	return out


func to_dict() -> Dictionary:
	var els := {}
	for k in elements.keys():
		var e: Dictionary = elements[k]
		var ne := {}
		for pk in e.keys():
			var v = e[pk]
			if v is Color:
				ne[pk] = [v.r, v.g, v.b, v.a]
			else:
				ne[pk] = v
		els[k] = ne
	return {"name": name, "elements": els}


static func from_dict(d: Dictionary) -> CrosshairProfile:
	var p := make_default()
	p.name = str(d.get("name", "Custom"))
	var els = d.get("elements", {})
	if typeof(els) != TYPE_DICTIONARY:
		return p
	for k in ELEMENT_KEYS:
		if not els.has(k):
			continue
		var src: Dictionary = els[k]
		var dst: Dictionary = p.elements[k]
		for pk in dst.keys():
			if not src.has(pk):
				continue
			var v = src[pk]
			if pk == "color" or pk == "outline_color":
				if v is Array and v.size() >= 3:
					dst[pk] = Color(float(v[0]), float(v[1]), float(v[2]), float(v[3]) if v.size() > 3 else 1.0)
				elif v is Color:
					dst[pk] = v
			else:
				dst[pk] = v
		p.elements[k] = dst
	return p


func export_code() -> String:
	var json := JSON.stringify(to_dict())
	var bytes := json.to_utf8_buffer()
	return CODE_PREFIX + Marshalls.raw_to_base64(bytes)


static func import_code(code: String) -> CrosshairProfile:
	var c := code.strip_edges()
	if c.begins_with(CODE_PREFIX):
		c = c.substr(CODE_PREFIX.length())
	var bytes := Marshalls.base64_to_raw(c)
	if bytes.is_empty():
		return null
	var json_text := bytes.get_string_from_utf8()
	var data = JSON.parse_string(json_text)
	if typeof(data) != TYPE_DICTIONARY:
		return null
	return from_dict(data)


func get_element(key: String) -> Dictionary:
	if elements.has(key):
		return elements[key]
	return default_element(key)
