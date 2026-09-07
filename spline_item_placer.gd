@tool
class_name SplineItemPlacer
extends Node3D
## 摆放样条线工具
## 控制点以子节点（Marker3D）形式存在，可以直接在场景中选中并用
## 编辑器自带的移动/旋转工具拖动；物品均匀放置在整条线上的每个点上，
## 并记录每个点的世界坐标。
## 用法：
## 1. 在场景中添加一个 SplineItemPlacer 节点（自动生成两个控制点）
## 2. 在场景中选中菱形标记直接拖动控制点
## 3. 设置 item_scene（要放置的物品）与 point_count（点的数量）
## 4. 需要更多控制点时点"添加控制点"按钮

@export_group("放置物品")
## 要在样条线每个点上放置的物品（PackedScene）
@export var item_scene: PackedScene:
	set(value):
		item_scene = value
		_request_rebuild()

## 物品是否自动朝向线条行进方向（绕 Y 轴旋转）
@export var align_to_path: bool = false:
	set(value):
		align_to_path = value
		_request_rebuild()

## 物品的旋转偏移（度），用于修正模型默认朝向。如路灯模型默认朝 X 轴，路面沿 Z 轴，可设 Y 偏移为 -90
@export var rotation_offset := Vector3.ZERO:
	set(value):
		rotation_offset = value
		_request_rebuild()

## 物品的缩放，默认为 (1, 1, 1)
@export var scale_offset := Vector3.ONE:
	set(value):
		scale_offset = value
		_request_rebuild()

@export_group("样条线")
## 均匀分布在整条线上的点的数量（use_fixed_spacing 启用时忽略，自动计算）
@export_range(1, 10000) var point_count: int = 10:
	set(value):
		point_count = maxi(1, value)
		_request_rebuild()

## 使用固定间距模式：指定相邻物品间距，自动计算放置数量
@export var use_fixed_spacing: bool = false:
	set(value):
		use_fixed_spacing = value
		_request_rebuild()

## 固定间距（米），use_fixed_spacing 启用时生效
@export var spacing_distance: float = 5.0:
	set(value):
		spacing_distance = maxf(0.01, value)
		_request_rebuild()

## 是否包含线条两个端点
@export var include_endpoints: bool = true:
	set(value):
		include_endpoints = value
		_request_rebuild()

## 曲线模式：Linear=直线连接，Smooth=平滑曲线（Catmull-Rom）
@export_enum("Linear", "Smooth") var curve_mode: int = 0:
	set(value):
		curve_mode = value
		_request_rebuild()

@export_group("调试显示")
## 是否显示样条线和点的辅助线
@export var show_debug_lines: bool = true:
	set(value):
		show_debug_lines = value
		if _debug_mesh != null:
			_debug_mesh.visible = value and Engine.is_editor_hint()
			_update_debug_mesh()

@export_tool_button("添加控制点", "Add") var add_point_button = _add_control_point
@export_tool_button("删除最后控制点", "Remove") var remove_point_button = _remove_last_control_point
@export_tool_button("重新生成物品", "Reload") var rebuild_button = _rebuild_now
@export_tool_button("烘焙到场景", "Save") var bake_button = _bake_to_scene

## 每个点在世界坐标系中的坐标（自动记录，只读）
var point_world_positions: Array[Vector3] = []
## 每个控制点在世界坐标系中的坐标（自动记录，只读）
var control_point_world_positions: Array[Vector3] = []

const CONTROL_ROOT_NAME := "ControlPoints"

var _control_root: Node3D
var _items_root: Node3D
var _debug_mesh: MeshInstance3D
var _rebuild_pending := false
var _baked := false
var _cached_control_positions: Array[Vector3] = []


func _ready() -> void:
	_setup_control_root()
	_setup_items_root()
	_setup_debug_mesh()
	rebuild()


func _process(_delta: float) -> void:
	# 控制点是子节点，移动它们不会通知父节点，这里轮询检测位置变化
	if _control_root == null:
		return
	var positions: Array[Vector3] = []
	for child in _control_root.get_children():
		if child is Node3D:
			positions.append(child.position)
	if positions != _cached_control_positions:
		_cached_control_positions = positions
		_request_rebuild()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_inside_tree():
		_request_rebuild()


func _request_rebuild() -> void:
	if _rebuild_pending:
		return
	_rebuild_pending = true
	call_deferred("_do_rebuild")


func _do_rebuild() -> void:
	_rebuild_pending = false
	if not is_inside_tree():
		return
	rebuild()


func _rebuild_now() -> void:
	"""手动重新生成：取消烘焙，重新摆放物品"""
	_baked = false
	_request_rebuild()


func _bake_to_scene() -> void:
	"""烘焙物品到场景：物品变为独立节点，可单独调整 Transform"""
	if not Engine.is_editor_hint():
		return
	if _items_root == null:
		return
	var scene_root := get_tree().edited_scene_root
	if scene_root == null:
		return
	_items_root.owner = scene_root
	for c in _items_root.get_children():
		c.owner = scene_root
	_baked = true
	print("已将 %d 个物品烘焙到场景，现在可以单独调整每个物品的 Transform" % _items_root.get_child_count())


## 重新计算所有点的世界坐标并重新放置物品
func rebuild() -> void:
	_compute_points()
	if not _baked:
		_place_items()
	_update_debug_mesh()


## 获取每个点在世界坐标系中的坐标
func get_point_world_positions() -> Array[Vector3]:
	return point_world_positions


## 获取所有控制点的局部坐标（本节点坐标系）
func get_control_points() -> Array[Vector3]:
	var pts: Array[Vector3] = []
	if _control_root != null:
		for child in _control_root.get_children():
			if child is Node3D:
				pts.append(child.position)
	return pts


func _compute_points() -> void:
	point_world_positions.clear()
	control_point_world_positions.clear()
	var cps := get_control_points()
	for cp in cps:
		control_point_world_positions.append(to_global(cp))
	if cps.size() < 2:
		return

	# 构建采样点：Linear 直接用控制点，Smooth 用 Catmull-Rom 插值
	var sample_points: Array[Vector3]
	if curve_mode == 1:
		sample_points = _build_smooth_curve(cps, 20)
	else:
		sample_points = cps

	# 计算采样点之间的线段长度
	var seg_lengths: Array[float] = []
	var total_length := 0.0
	for i in range(sample_points.size() - 1):
		var seg_len: float = sample_points[i].distance_to(sample_points[i + 1])
		seg_lengths.append(seg_len)
		total_length += seg_len
	if total_length <= 0.0001:
		return

	# 确定放置点数量：固定间距模式根据总长自动计算
	var n: int
	if use_fixed_spacing:
		n = maxi(1, int(total_length / spacing_distance) + 1)
	else:
		n = point_count
	if n < 1:
		return

	var spacing: float
	if include_endpoints and n >= 2:
		spacing = total_length / float(n - 1)
	else:
		spacing = total_length / float(n)
	var start_offset := 0.0
	if not include_endpoints:
		start_offset = spacing * 0.5
	for i in range(n):
		var dist: float = minf(start_offset + spacing * float(i), total_length)
		point_world_positions.append(to_global(_sample_at_distance(dist, seg_lengths, sample_points)))


func _sample_at_distance(dist: float, seg_lengths: Array[float], cps: Array[Vector3]) -> Vector3:
	var idx := 0
	var rem := dist
	while idx < seg_lengths.size() - 1 and rem > seg_lengths[idx]:
		rem -= seg_lengths[idx]
		idx += 1
	var seg := seg_lengths[idx]
	var t := 0.0
	if seg > 0.0001:
		t = clampf(rem / seg, 0.0, 1.0)
	return cps[idx].lerp(cps[idx + 1], t)


func _build_smooth_curve(cps: Array[Vector3], samples_per_seg: int) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var n := cps.size()
	for i in range(n - 1):
		var p0 := cps[maxi(i - 1, 0)]
		var p1 := cps[i]
		var p2 := cps[i + 1]
		var p3 := cps[mini(i + 2, n - 1)]
		for j in range(samples_per_seg):
			var t := float(j) / float(samples_per_seg)
			result.append(_catmull_rom(p0, p1, p2, p3, t))
	result.append(cps[n - 1])
	return result


func _catmull_rom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * (
		(2.0 * p1) +
		(-p0 + p2) * t +
		(2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
		(-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
	)


func _place_items() -> void:
	if _items_root == null:
		return
	for c in _items_root.get_children():
		_items_root.remove_child(c)
		c.queue_free()
	if item_scene == null:
		return
	for i in range(point_world_positions.size()):
		var inst := item_scene.instantiate()
		_items_root.add_child(inst)
		if inst is Node3D:
			inst.global_position = point_world_positions[i]
			inst.global_rotation = Vector3(deg_to_rad(rotation_offset.x), deg_to_rad(rotation_offset.y), deg_to_rad(rotation_offset.z))
			inst.scale = scale_offset
			if align_to_path:
				inst.global_rotation.y += _yaw_at(i)
		if Engine.is_editor_hint():
			inst.owner = null


func _yaw_at(i: int) -> float:
	var prev: Vector3 = point_world_positions[maxi(i - 1, 0)]
	var next: Vector3 = point_world_positions[mini(i + 1, point_world_positions.size() - 1)]
	var dir := next - prev
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		return 0.0
	dir = dir.normalized()
	return atan2(-dir.x, -dir.z)


func _setup_control_root() -> void:
	_control_root = get_node_or_null(CONTROL_ROOT_NAME) as Node3D
	if _control_root == null:
		_control_root = Node3D.new()
		_control_root.name = CONTROL_ROOT_NAME
		add_child(_control_root)
		if Engine.is_editor_hint():
			var scene_root := get_tree().edited_scene_root
			if scene_root != null:
				_control_root.owner = scene_root
		_create_marker(Vector3.ZERO)
		_create_marker(Vector3(10, 0, 0))


func _create_marker(pos: Vector3) -> Marker3D:
	var marker := Marker3D.new()
	marker.name = "控制点%d" % (_control_root.get_child_count() + 1)
	marker.position = pos
	_control_root.add_child(marker)
	if Engine.is_editor_hint():
		var scene_root := get_tree().edited_scene_root
		if scene_root != null:
			marker.owner = scene_root
	return marker


func _add_control_point() -> void:
	if _control_root == null:
		return
	var pos := Vector3(10, 0, 0)
	var n := _control_root.get_child_count()
	if n >= 1:
		var last := _control_root.get_child(n - 1) as Node3D
		var dir := Vector3(10, 0, 0)
		if n >= 2:
			var prev := _control_root.get_child(n - 2) as Node3D
			dir = last.position - prev.position
			if dir.length() < 0.0001:
				dir = Vector3(10, 0, 0)
		pos = last.position + dir
	_create_marker(pos)
	_cached_control_positions.clear()
	_request_rebuild()


func _remove_last_control_point() -> void:
	if _control_root == null or _control_root.get_child_count() <= 0:
		return
	var last := _control_root.get_child(_control_root.get_child_count() - 1)
	last.queue_free()
	_cached_control_positions.clear()
	_request_rebuild()


func _setup_items_root() -> void:
	if _items_root != null:
		return
	_items_root = get_node_or_null("GeneratedItems") as Node3D
	if _items_root == null:
		_items_root = Node3D.new()
		_items_root.name = "GeneratedItems"
		add_child(_items_root)
		if Engine.is_editor_hint():
			_items_root.owner = null


func _setup_debug_mesh() -> void:
	if _debug_mesh != null:
		return
	_debug_mesh = get_node_or_null("DebugLines") as MeshInstance3D
	if _debug_mesh == null:
		_debug_mesh = MeshInstance3D.new()
		_debug_mesh.name = "DebugLines"
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.no_depth_test = true
		_debug_mesh.material_override = mat
		_debug_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_debug_mesh)
		if Engine.is_editor_hint():
			_debug_mesh.owner = null
	_debug_mesh.visible = show_debug_lines and Engine.is_editor_hint()


func _update_debug_mesh() -> void:
	if _debug_mesh == null:
		return
	var im := ImmediateMesh.new()
	_debug_mesh.mesh = im
	if not show_debug_lines:
		return
	var cps := get_control_points()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	# 控制点连线（黄色）
	im.surface_set_color(Color(1.0, 0.85, 0.2))
	if curve_mode == 1 and cps.size() >= 2:
		var curve_pts := _build_smooth_curve(cps, 10)
		for i in range(curve_pts.size() - 1):
			im.surface_add_vertex(curve_pts[i])
			im.surface_add_vertex(curve_pts[i + 1])
	else:
		for i in range(cps.size() - 1):
			im.surface_add_vertex(cps[i])
			im.surface_add_vertex(cps[i + 1])
	# 均匀点（绿色十字）
	im.surface_set_color(Color(0.2, 1.0, 0.4))
	for p in point_world_positions:
		_add_cross(im, to_local(p), 0.25)
	# 控制点（红色十字）
	im.surface_set_color(Color(1.0, 0.3, 0.3))
	for cp in cps:
		_add_cross(im, cp, 0.4)
	im.surface_end()


func _add_cross(im: ImmediateMesh, center: Vector3, half: float) -> void:
	im.surface_add_vertex(center + Vector3(-half, 0, 0))
	im.surface_add_vertex(center + Vector3(half, 0, 0))
	im.surface_add_vertex(center + Vector3(0, -half, 0))
	im.surface_add_vertex(center + Vector3(0, half, 0))
	im.surface_add_vertex(center + Vector3(0, 0, -half))
	im.surface_add_vertex(center + Vector3(0, 0, half))
