extends Control

const Orb = preload("res://orb.gd")
const GLOBAL_COUNT := Orb.GLOBAL_COUNT
const GREEN := Color("5de2b1")
const CYAN := Color("6ebdff")
const GOLD := Color("ffc278")
const TEXT := Color("e9f3f7")

const CIRCLE_SIDES := 24
const INSTANCE_FLOATS := 12

var objects: Array[Orb] = []
var configured := 128
var backend: Node
var _circles: MultiMesh
var _instances := PackedFloat32Array()
var _circle_count := 0

func _ready() -> void:
	var vertices := PackedVector2Array([Vector2.ZERO])
	var indices := PackedInt32Array()
	for side in CIRCLE_SIDES:
		vertices.append(Vector2.from_angle(TAU * side / CIRCLE_SIDES))
		indices.append(0)
		indices.append(side + 1)
		indices.append((side + 1) % CIRCLE_SIDES + 1)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_circles = MultiMesh.new()
	_circles.transform_format = MultiMesh.TRANSFORM_2D
	_circles.use_colors = true
	_circles.mesh = mesh
	_resize_circle_bounds()

func _resize_circle_bounds() -> void:
	if _circles == null:
		return
	_circles.custom_aabb = AABB(Vector3(-16.0, -16.0, -1.0), Vector3(size.x + 32.0, size.y + 32.0, 2.0))

func _draw() -> void:
	var bounds := Rect2(1, 1, size.x - 2, size.y - 2)
	draw_rect(bounds, Color("09131f"))
	draw_rect(bounds, Color("2d4052"), false, 1)
	var pad := 20.0
	var global_height := 78.0
	var lane_width := (size.x - pad * 3.0) * 0.5
	var lower_y := global_height + pad * 1.5
	var lane_height := maxf(40.0, size.y - lower_y - pad)
	var left := Rect2(pad, lower_y, lane_width, lane_height)
	var right := Rect2(pad * 2.0 + lane_width, lower_y, lane_width, lane_height)
	_lane(Rect2(pad, pad, size.x - pad * 2.0, global_height), "全局 · 玩家及公共对象", GREEN)
	_lane(left, "AOI 1", CYAN)
	_lane(right, "AOI 2", GOLD)
	var cols := mini(12 if configured <= 512 else 17, ceili((configured - GLOBAL_COUNT) / 2.0))
	var rows := ceili(float(configured - GLOBAL_COUNT) / (2 * cols))
	var stride := Vector2((lane_width - 18) / cols, (lane_height - 38) / rows)
	var radius := clampf(minf(stride.x, stride.y) * 0.26, 1.4, 6.6)
	var capacity := maxi(0, objects.size() - 2) * 2
	if _circles.instance_count != capacity:
		_circles.instance_count = capacity
		_instances.resize(capacity * INSTANCE_FLOATS)
	_circle_count = 0
	for i in range(2, objects.size()):
		var orb := objects[i]
		if not backend.visible(i): continue
		if i < GLOBAL_COUNT:
			var px := pad + 18.0 + (size.x - 2.0 * pad - 36.0) * (i - 2) / (GLOBAL_COUNT - 3.0)
			_orb(Vector2(px, pad + 54), minf(5.0, size.x / 115.0), GREEN, orb)
			continue
		@warning_ignore("integer_division")
		var index := (i - GLOBAL_COUNT) / 2
		var lane := left if i % 2 == 0 else right
		@warning_ignore("integer_division")
		var point := lane.position + Vector2(9, 31) + (Vector2(index % cols, index / cols) + Vector2(0.5, 0.5)) * stride
		point += orb.offset.limit_length() * stride * 0.33
		_orb(point, radius, CYAN if i % 2 == 0 else GOLD, orb)
	if _circle_count > 0:
		_circles.visible_instance_count = _circle_count
		_circles.buffer = _instances
		draw_multimesh(_circles, null)
	var play := bounds.grow(-32.0)
	for i in mini(2, objects.size()):
		var avatar := objects[i]
		if not is_instance_valid(avatar) or not backend.visible(i): continue
		var pos := play.position + ((avatar.offset + Vector2.ONE) * 0.5) * play.size
		var color := GREEN if i == 0 else Color("ff989f")
		draw_circle(pos, 16.0, Color(color, 0.22))
		draw_arc(pos, 13.0, 0, TAU, 24, color, 2.0, true)
		draw_circle(pos, 7.0, color)
		draw_string(get_theme_default_font(), pos + Vector2(17, 5), "A" if i == 0 else "B",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 17, TEXT)

func _lane(rect: Rect2, caption: String, accent: Color) -> void:
	draw_rect(rect, Color(accent, 0.045))
	draw_rect(rect, Color(accent, 0.30), false, 1.0)
	draw_string(get_theme_default_font(), rect.position + Vector2(12, 22), caption,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, accent)

func _orb(pos: Vector2, radius: float, color: Color, orb: Orb) -> void:
	if orb.active:
		_circle(pos, radius * 1.71, Color(color, 0.20))
	_circle(pos, radius, color.darkened(0.27 * (1.0 - orb.energy)))

func _circle(pos: Vector2, radius: float, color: Color) -> void:
	# A 2D MultiMesh stores two padded transform rows followed by RGBA.
	var base := _circle_count * INSTANCE_FLOATS
	_instances[base] = radius
	_instances[base + 3] = pos.x
	_instances[base + 5] = radius
	_instances[base + 7] = pos.y
	_instances[base + 8] = color.r
	_instances[base + 9] = color.g
	_instances[base + 10] = color.b
	_instances[base + 11] = color.a
	_circle_count += 1
