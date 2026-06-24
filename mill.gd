@tool
extends Node

const GROUP_ORIGINAL_THREE_WAY := 0
const GROUP_SINGLE_BODY := 1

const COLOR_KEEP_SOURCE := 0
const COLOR_NONE := 1
const COLOR_RANDOM_PER_PART := 2
const COLOR_RANDOM_PER_SOLID := 3
const COLOR_RANDOM_PER_FACE := 4


@export var source_step_path: String = "res://mill.step"

@export_tool_button("Reload") var reload_button: Callable = _do_reload


@export_group("Rendering Meshing")
@export_range(0.0001, 100.0, 0.0001, "or_greater")
var render_linear_deflection: float = 0.1
@export_range(0.0001, 100.0, 0.0001, "or_greater")
var render_angular_deflection: float = 0.5
@export var render_with_attributes: bool = true

@export_group("Colors")
@export_enum("Keep Source", "None", "Random Per Part", "Random Per Solid", "Random Per Face")
var color_mode: int = COLOR_KEEP_SOURCE
@export var random_seed: int = 12345
@export_range(0.0, 1.0, 0.01)
var random_saturation_min: float = 0.65
@export_range(0.0, 1.0, 0.01)
var random_saturation_max: float = 0.95
@export_range(0.0, 1.0, 0.01)
var random_value_min: float = 0.75
@export_range(0.0, 1.0, 0.01)
var random_value_max: float = 0.98
@export_range(0.0, 1.0, 0.01)
var random_alpha_min: float = 1.0
@export_range(0.0, 1.0, 0.01)
var random_alpha_max: float = 1.0

@export_group("Collision")
@export var generate_collision: bool = true
@export_range(0.0001, 100.0, 0.0001, "or_greater")
var collision_linear_deflection: float = 0.5
@export_range(0.0001, 100.0, 0.0001, "or_greater")
var collision_angular_deflection: float = 1.0
@export var collision_with_attributes: bool = false


@export_group("Stats")
@export var print_stats: bool = true
@export var print_group_stats: bool = true
@export var print_component_stats: bool = false
@export_range(1, 1000, 1, "or_greater")
var component_stats_limit: int = 20


var _rebuilding := false


func _do_reload() -> void:
	if _rebuilding:
		return

	_rebuilding = true
	var t_all := Time.get_ticks_msec()

	var file_path := ProjectSettings.globalize_path(source_step_path)
	if source_step_path.is_empty() or !FileAccess.file_exists(file_path):
		push_error("STEP file not found: %s" % source_step_path)
		_rebuilding = false
		return

	var t_import := Time.get_ticks_msec()
	var mill := TopoShape.new()
	if !mill.import_step_file(file_path) or mill.is_null():
		push_error("STEP load failed: %s" % source_step_path)
		_rebuilding = false
		return
	t_import = Time.get_ticks_msec() - t_import

	var t_collect := Time.get_ticks_msec()
	var components := _collect_components(mill)
	t_collect = Time.get_ticks_msec() - t_collect

	if components.is_empty():
		push_error("Imported STEP has no components.")
		_rebuilding = false
		return

	var groups: Dictionary = {}
	for i in range(components.size()):
		var group_id := _get_group_id(i)
		if !groups.has(group_id):
			groups[group_id] = []
		(groups[group_id] as Array).append({
			"index": i,
			"shape": components[i],
			"com": components[i].get_center_of_mass(),
			"type": components[i].get_shape_type_name(),
			"geom": components[i].get_geom_type_name(),
			"volume": components[i].get_volume(),
			"area": components[i].get_surface_area(),
			"has_color": components[i].has_color(),
		})

	var total_parts := 0
	for group_id_variant in groups.keys():
		total_parts += (groups[group_id_variant] as Array).size()

	if print_component_stats:
		_print_component_stats(components)

	var t_build := Time.get_ticks_msec()
	var group_ids := groups.keys()
	group_ids.sort()

	var group_stats: Array = []
	var total_triangles := 0
	var total_surfaces := 0
	var source_colored_parts := 0
	var total_volume := 0.0
	var total_area := 0.0

	for group_id_variant in group_ids:
		var group_id := int(group_id_variant)
		var parts: Array = groups[group_id]
		if parts.is_empty():
			continue

		var body := _get_or_create_body(group_id)
		if body == null:
			continue

		var group_center := Vector3.ZERO
		for p in parts:
			group_center += -((p as Dictionary)["com"] as Vector3)
		group_center /= float(parts.size())

		# This matches the original transform math.
		var group_xf := Transform3D(Vector3.RIGHT, Vector3.UP, Vector3.BACK, group_center)

		var t_group := Time.get_ticks_msec()

		# Build collision FIRST so OCCT caches the coarser tessellation.
		# The finer render tessellation below will then force a re-tessellation.
		if generate_collision:
			var collision_mesh := _build_collision_mesh(parts, group_xf)

			var col := _get_or_create_collision(body)
			if col != null:
				col.shape = collision_mesh.create_trimesh_shape()
			else:
				push_error("Can't set collision_mesh")

		var render_mesh := _build_group_mesh(
			parts,
			group_xf,
			group_id,
			render_linear_deflection,
			render_angular_deflection,
			render_with_attributes
		)

		var mi := _get_or_create_mesh_instance(body)
		if mi != null:
			mi.mesh = render_mesh
		else:
			push_error("Can't set render_mesh")

		body.transform = group_xf.affine_inverse()

		var group_triangles := _mesh_triangle_count(render_mesh)
		var group_surfaces := render_mesh.get_surface_count()
		var group_volume := 0.0
		var group_area := 0.0
		var g_has_color := 0
		for p in parts:
			group_volume += float((p as Dictionary)["volume"])
			group_area += float((p as Dictionary)["area"])
			if bool((p as Dictionary)["has_color"]):
				g_has_color += 1

		var group_time := Time.get_ticks_msec() - t_group

		total_triangles += group_triangles
		total_surfaces += group_surfaces
		total_parts += parts.size()
		source_colored_parts += g_has_color
		total_volume += group_volume
		total_area += group_area

		if print_group_stats:
			print(
				"[G%d] t=%dms parts=%d feats=%d surfs=%d tris=%d vol=%.6f area=%.6f com=(%.6f,%.6f,%.6f)"
				% [
					group_id,
					group_time,
					parts.size(),
					_get_feature_count(parts),
					group_surfaces,
					group_triangles,
					group_volume,
					group_area,
					group_center.x,
					group_center.y,
					group_center.z,
				]
			)

		group_stats.append({
			"group_id": group_id,
			"parts": parts.size(),
			"tris": group_triangles,
			"surfs": group_surfaces,
			"vol": group_volume,
			"area": group_area,
			"time": group_time,
		})

	t_build = Time.get_ticks_msec() - t_build

	if print_stats:
		_print_stats(
			mill,
			components,
			total_parts,
			total_surfaces,
			total_triangles,
			source_colored_parts,
			group_stats,
			total_volume,
			total_area,
			t_import,
			t_collect,
			t_build,
			Time.get_ticks_msec() - t_all
		)

	_rebuilding = false


func _collect_components(root: TopoShape) -> Array:
	var components: Array = []

	if root.has_method("get_component_count") and root.has_method("get_component_shape"):
		var count := int(root.get_component_count()) - 1
		if count > 0:
			for i in range(count):
				var comp := root.get_component_shape(i + 1)
				if comp is TopoShape and !(comp as TopoShape).is_null():
					components.append(comp)

	if components.is_empty():
		components.append(root)

	return components


func _get_group_id(i: int) -> int:
	if i <= 2:
		return 0
	elif i == 3:
		return 1
	return 2


func _get_or_create_body(group_id: int) -> Node3D:
	var name := "Group_%d" % group_id
	var existing := get_node_or_null(name)
	if existing != null:
		return existing as Node3D

	var body: Node3D = StaticBody3D.new() if _is_static(group_id) else RigidBody3D.new()
	body.name = name
	add_child(body)
	if Engine.is_editor_hint():
		var root := get_tree().edited_scene_root
		if root != null:
			body.owner = root
	return body


func _is_static(group_id: int) -> bool:
	return group_id == 2


func _get_or_create_mesh_instance(body: Node3D) -> MeshInstance3D:
	var mi := body.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mi != null:
		return mi

	mi = MeshInstance3D.new()
	mi.name = "MeshInstance3D"
	body.add_child(mi)
	if Engine.is_editor_hint():
		mi.owner = get_tree().edited_scene_root
	return mi


func _get_or_create_collision(body: Node3D) -> CollisionShape3D:
	var col := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col != null:
		return col

	col = CollisionShape3D.new()
	col.name = "CollisionShape3D"
	body.add_child(col)
	if Engine.is_editor_hint():
		col.owner = get_tree().edited_scene_root
	return col


func _get_feature_count(parts: Array) -> int:
	var count := 0
	for p in parts:
		count += _get_features_for_shape((p as Dictionary)["shape"]).size()
	return count


func _build_group_mesh(
	parts: Array,
	group_xf: Transform3D,
	group_id: int,
	linear_deflection: float,
	angular_deflection: float,
	with_attributes: bool
) -> ArrayMesh:
	var final_mesh := ArrayMesh.new()
	var use_source_attrs := with_attributes or color_mode == COLOR_KEEP_SOURCE

	for p in parts:
		var rec: Dictionary = p
		var shape: TopoShape = rec["shape"]
		var part_index := int(rec["index"])

		var features := _get_features_for_shape(shape)

		for f_i in range(features.size()):
			var feature: TopoShape = features[f_i]
			var feature_key := "%s|g%d|p%d|f%d" % [source_step_path, group_id, part_index, f_i]
			var color_info := _get_feature_color(feature, part_index, f_i, feature_key)

			var source_mesh := feature.to_array_mesh(linear_deflection, angular_deflection, use_source_attrs)
			_append_transformed_mesh_surface(
				final_mesh,
				source_mesh,
				group_xf,
				color_info["apply_color"],
				color_info["color"],
				color_info["use_source_color"],
				color_info["source_color"]
			)

	return final_mesh

func _build_collision_mesh(parts: Array, group_xf: Transform3D) -> ArrayMesh:
	var old_mode := color_mode
	color_mode = COLOR_NONE

	var mesh := _build_group_mesh(
		parts,
		group_xf,
		-1,
		collision_linear_deflection,
		collision_angular_deflection,
		collision_with_attributes
	)

	color_mode = old_mode
	return mesh

func _get_features_for_shape(shape: TopoShape) -> Array:
	match color_mode:
		COLOR_RANDOM_PER_SOLID:
			var solids := shape.get_solids()
			if solids.size() > 0:
				return solids
		COLOR_RANDOM_PER_FACE:
			var faces := shape.get_faces()
			if faces.size() > 0:
				return faces
		_:
			pass

	return [shape]


func _get_feature_color(feature: TopoShape, part_index: int, feature_index: int, feature_key: String) -> Dictionary:
	var info := {
		"apply_color": false,
		"use_source_color": false,
		"color": Color.WHITE,
		"source_color": Color.WHITE,
	}

	match color_mode:
		COLOR_NONE:
			return info

		COLOR_KEEP_SOURCE:
			if feature.has_color():
				info["use_source_color"] = true
				info["source_color"] = feature.get_color()
			return info

		COLOR_RANDOM_PER_PART:
			info["apply_color"] = true
			info["color"] = _make_random_color("%s|part|%d" % [feature_key, part_index])
			return info

		COLOR_RANDOM_PER_SOLID:
			info["apply_color"] = true
			info["color"] = _make_random_color("%s|solid|%d" % [feature_key, feature_index])
			return info

		COLOR_RANDOM_PER_FACE:
			info["apply_color"] = true
			info["color"] = _make_random_color("%s|face|%d" % [feature_key, feature_index])
			return info

		_:
			return info


func _append_transformed_mesh_surface(
	dst: ArrayMesh,
	src: ArrayMesh,
	xf: Transform3D,
	apply_color: bool,
	override_color: Color,
	use_source_color: bool,
	source_color: Color
) -> void:
	if src == null or src.get_surface_count() == 0:
		return

	for s in range(src.get_surface_count()):
		var arrays: Array = src.surface_get_arrays(s)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue

		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue

		var idxs := PackedInt32Array()
		if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
			idxs = arrays[Mesh.ARRAY_INDEX]
		if idxs.is_empty():
			idxs = PackedInt32Array()
			idxs.resize(verts.size())
			for i in range(verts.size()):
				idxs[i] = i

		var uvs := PackedVector2Array()
		if arrays.size() > Mesh.ARRAY_TEX_UV and arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
			uvs = arrays[Mesh.ARRAY_TEX_UV]

		var colors := PackedColorArray()
		if arrays.size() > Mesh.ARRAY_COLOR and arrays[Mesh.ARRAY_COLOR] is PackedColorArray:
			colors = arrays[Mesh.ARRAY_COLOR]

		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)

		for i in range(0, idxs.size(), 3):
			if i + 2 >= idxs.size():
				continue

			for k in range(3):
				var vi := idxs[i + k]
				if vi < 0 or vi >= verts.size():
					continue

				if apply_color:
					st.set_color(override_color)
				elif use_source_color:
					st.set_color(source_color if colors.is_empty() or vi >= colors.size() else colors[vi])

				if not uvs.is_empty() and vi < uvs.size():
					st.set_uv(uvs[vi])

				st.add_vertex(xf * verts[vi])

		st.generate_normals()
		var rebuilt := st.commit()
		if rebuilt == null:
			continue

		for rs in range(rebuilt.get_surface_count()):
			dst.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, rebuilt.surface_get_arrays(rs))


func _make_random_color(key: String) -> Color:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key) ^ random_seed

	var s_min := minf(random_saturation_min, random_saturation_max)
	var s_max := maxf(random_saturation_min, random_saturation_max)
	var v_min := minf(random_value_min, random_value_max)
	var v_max := maxf(random_value_min, random_value_max)
	var a_min := minf(random_alpha_min, random_alpha_max)
	var a_max := maxf(random_alpha_min, random_alpha_max)

	return Color.from_hsv(
		rng.randf(),
		rng.randf_range(s_min, s_max),
		rng.randf_range(v_min, v_max),
		rng.randf_range(a_min, a_max)
	)


func _mesh_triangle_count(mesh: ArrayMesh) -> int:
	var count := 0
	for s in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(s)
		if arrays.size() <= Mesh.ARRAY_INDEX:
			continue
		var idx = arrays[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array and (idx as PackedInt32Array).size() > 0:
			count += int((idx as PackedInt32Array).size() / 3)
		else:
			var verts = arrays[Mesh.ARRAY_VERTEX]
			if verts is PackedVector3Array:
				count += int((verts as PackedVector3Array).size() / 3)
	return count


func _print_component_stats(components: Array) -> void:
	var limit := mini(component_stats_limit, components.size())
	for i in range(limit):
		var comp: TopoShape = components[i]
		print(
			"[C%03d] type=%s geom=%s vol=%.6f area=%.6f com=(%.6f,%.6f,%.6f) bbox=(%.6f,%.6f,%.6f) color=%s"
			% [
				i,
				comp.get_shape_type_name(),
				comp.get_geom_type_name(),
				comp.get_volume(),
				comp.get_surface_area(),
				comp.get_center_of_mass().x,
				comp.get_center_of_mass().y,
				comp.get_center_of_mass().z,
				comp.get_bounding_box_size().x,
				comp.get_bounding_box_size().y,
				comp.get_bounding_box_size().z,
				"yes" if comp.has_color() else "no",
			]
		)


func _print_stats(
	root_shape: TopoShape,
	components: Array,
	total_parts: int,
	total_surfaces: int,
	total_triangles: int,
	source_colored_parts: int,
	group_stats: Array,
	total_volume: float,
	total_area: float,
	t_import: int,
	t_collect: int,
	t_build: int,
	t_total: int
) -> void:
	var bbox_min := root_shape.get_bounding_box_min()
	var bbox_max := root_shape.get_bounding_box_max()
	var bbox_size := root_shape.get_bounding_box_size()

	var shape_hist: Dictionary = {}
	var geom_hist: Dictionary = {}
	for comp_variant in components:
		var comp: TopoShape = comp_variant
		shape_hist[comp.get_shape_type_name()] = int(shape_hist.get(comp.get_shape_type_name(), 0)) + 1
		geom_hist[comp.get_geom_type_name()] = int(geom_hist.get(comp.get_geom_type_name(), 0)) + 1

	var shape_hist_str := _hist_to_string(shape_hist)
	var geom_hist_str := _hist_to_string(geom_hist)

	print(
		"[STEP] import=%dms collect=%dms build=%dms total=%dms comps=%d groups=%d parts=%d surfs=%d tris=%d vol=%.6f area=%.6f bbox_min=(%.6f,%.6f,%.6f) bbox_max=(%.6f,%.6f,%.6f) bbox_size=(%.6f,%.6f,%.6f) source_colored=%d color_mode=%s shapes=%s geoms=%s"
		% [
			t_import,
			t_collect,
			t_build,
			t_total,
			components.size(),
			group_stats.size(),
			total_parts,
			total_surfaces,
			total_triangles,
			total_volume,
			total_area,
			bbox_min.x, bbox_min.y, bbox_min.z,
			bbox_max.x, bbox_max.y, bbox_max.z,
			bbox_size.x, bbox_size.y, bbox_size.z,
			source_colored_parts,
			_color_mode_string(),
			shape_hist_str,
			geom_hist_str
		]
	)


func _hist_to_string(hist: Dictionary) -> String:
	var keys := hist.keys()
	keys.sort()
	var parts: Array[String] = []
	for k in keys:
		parts.append("%s=%s" % [str(k), str(hist[k])])
	return ",".join(parts)


func _color_mode_string() -> String:
	match color_mode:
		COLOR_KEEP_SOURCE:
			return "keep"
		COLOR_NONE:
			return "none"
		COLOR_RANDOM_PER_PART:
			return "per_part"
		COLOR_RANDOM_PER_SOLID:
			return "per_solid"
		COLOR_RANDOM_PER_FACE:
			return "per_face"
		_:
			return "unknown"
