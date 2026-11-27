@tool
extends MeshInstance3D

func _ready() -> void:
	_clean_mesh()

func _clean_mesh() -> void:
	if mesh == null:
		print("No mesh assigned")
		return

	print("--- Cleaning mesh ---")
	print("Original mesh type: ", mesh.get_class())
	print("Surface count: ", mesh.get_surface_count())

	var new_mesh := ArrayMesh.new()
	var surface_idx := 0

	# Store override materials
	var override_materials: Array[Material] = []
	for i in get_surface_override_material_count():
		override_materials.append(get_surface_override_material(i))

	for i in mesh.get_surface_count():
		var arrays = mesh.surface_get_arrays(i)
		
		var verts = arrays[Mesh.ARRAY_VERTEX]
		var indices = arrays[Mesh.ARRAY_INDEX]

		print("Surface ", i)
		print("  verts: ", verts.size() if verts else 0)
		print("  indices is null?: ", indices == null)

		if verts == null or verts.size() == 0:
			print("  → skipping empty surface")
			continue

		# Generate indices if missing
		if indices == null or (indices is Array and indices.is_empty()) or (indices is PackedInt32Array and indices.is_empty()):
			print("  → generating sequential indices")
			indices = PackedInt32Array()
			indices.resize(verts.size())
			for j in verts.size():
				indices[j] = j
			arrays[Mesh.ARRAY_INDEX] = indices

		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

		# Keep original material
		var original_mat = mesh.surface_get_material(i)
		if original_mat:
			new_mesh.surface_set_material(surface_idx, original_mat)

		surface_idx += 1

	if new_mesh.get_surface_count() == 0:
		print("→ No valid surfaces found!")
		return

	mesh = new_mesh
	print("→ Replaced with cleaned ArrayMesh (", new_mesh.get_surface_count(), " surfaces)")

	# Restore overrides
	for i in override_materials.size():
		if override_materials[i]:
			set_surface_override_material(i, override_materials[i])

	print("--- Done ---")
