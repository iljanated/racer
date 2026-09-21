@tool
extends MeshInstance3D

class_name PathMesh3D

@onready var track_path: TrackPath = get_parent() as TrackPath
@export var floor_width: float = 17.0
@export var wall_height: float = 1.5
@export var segment_length: float = 5.0

var _mesh_dirty := false

# Cached buffers reused across rebuilds to avoid per-call allocation
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _uvs := PackedVector2Array()
var _indices := PackedInt32Array()
var _cached_steps := -1
var _arr_mesh := ArrayMesh.new()

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if not track_path.is_connected("track_segments_updated", _on_track_changed):
		track_path.connect("track_segments_updated", _on_track_changed)
	_on_track_changed()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	pass

func _on_track_changed():
	if _mesh_dirty:
		return
	_mesh_dirty = true
	update_mesh_along_curve.call_deferred()

func update_mesh_along_curve():
	_mesh_dirty = false

	if not track_path or not track_path.path3d.curve:
		print("Track path or curve is not available.")
		return

	print("Updating mesh along curve.")
	var curve: Curve3D = track_path.path3d.curve
	var total_length: float = curve.get_baked_length()
	
	# Calculate how many cross-sections we need
	var steps: int = max(2, int(total_length / segment_length))

	_vertices.resize((steps + 1) * 4)
	_normals.resize((steps + 1) * 4)
	_uvs.resize((steps + 1) * 4)

	# 1. Generate Vertices, Normals, and UVs for each cross-section loop
	for i in range(steps + 1):
		# Sample the curve position and orientation in path's local space
		var offset: float = (float(i) / steps) * total_length
		var local_transform: Transform3D = curve.sample_baked_with_rotation(offset, true, true)
		
		# Define the 4 points of our cross-section relative to the track frame
		# Vector3.RIGHT (X) is the horizontal width, Vector3.UP (Y) is the wall height
		var p0 = local_transform * Vector3(-floor_width / 2.0, wall_height, 0)       # Left Wall Top
		var p1 = local_transform * Vector3(-floor_width / 2.0, 0, 0)                 # Left Wall Bottom
		var p2 = local_transform * Vector3(floor_width / 2.0, 0, 0)                  # Right Wall Bottom
		var p3 = local_transform * Vector3(floor_width / 2.0, wall_height, 0)        # Right Wall Top
		
		var row: int = i * 4
		_vertices[row + 0] = p0
		_vertices[row + 1] = p1
		_vertices[row + 2] = p2
		_vertices[row + 3] = p3
		
		# Directions matching the transform basis orientation
		var left_dir: Vector3 = -local_transform.basis.x
		var up_dir: Vector3 = local_transform.basis.y
		var right_dir: Vector3 = local_transform.basis.x
		
		_normals[row + 0] = left_dir
		_normals[row + 1] = up_dir
		_normals[row + 2] = up_dir
		_normals[row + 3] = right_dir
		
		# Basic texture UV mapping (X wrap across profile, Y running along curve length)
		var v_coord: float = offset
		_uvs[row + 0] = Vector2(0.0, v_coord) * 0.1
		_uvs[row + 1] = Vector2(wall_height, v_coord) * 0.1
		_uvs[row + 2] = Vector2(wall_height + floor_width, v_coord) * 0.1
		_uvs[row + 3] = Vector2(wall_height * 2 + floor_width, v_coord) * 0.1

	# 2. Stitch the cross-sections together into triangles (Quads)
	# Topology only depends on `steps`, so skip rebuilding it if unchanged
	if steps != _cached_steps:
		_indices.resize(steps * 18)
		for i in range(steps):
			var curr_row: int = i * 4
			var next_row: int = (i + 1) * 4
			var idx: int = i * 18

			# Every segment has 3 faces: Left Wall, Floor, Right Wall
			# Each face requires 2 triangles (6 indices) clockwise / counter-clockwise order

			# --- Left Wall ---
			_indices[idx + 0] = curr_row + 0
			_indices[idx + 1] = next_row + 1
			_indices[idx + 2] = curr_row + 1
			_indices[idx + 3] = curr_row + 0
			_indices[idx + 4] = next_row + 0
			_indices[idx + 5] = next_row + 1

			# --- Floor ---
			_indices[idx + 6] = curr_row + 1
			_indices[idx + 7] = next_row + 2
			_indices[idx + 8] = curr_row + 2
			_indices[idx + 9] = curr_row + 1
			_indices[idx + 10] = next_row + 1
			_indices[idx + 11] = next_row + 2

			# --- Right Wall ---
			_indices[idx + 12] = curr_row + 2
			_indices[idx + 13] = next_row + 3
			_indices[idx + 14] = curr_row + 3
			_indices[idx + 15] = curr_row + 2
			_indices[idx + 16] = next_row + 2
			_indices[idx + 17] = next_row + 3

		_cached_steps = steps

	# 3. Commit Arrays to MeshDataTool / ArrayMesh
	var surface_array := []
	surface_array.resize(Mesh.ARRAY_MAX)
	
	surface_array[Mesh.ARRAY_VERTEX] = _vertices
	surface_array[Mesh.ARRAY_INDEX] = _indices
	surface_array[Mesh.ARRAY_NORMAL] = _normals
	surface_array[Mesh.ARRAY_TEX_UV] = _uvs
	
	_arr_mesh.clear_surfaces()
	_arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
	
	# Apply generated geometry to the MeshInstance3D
	self.mesh = _arr_mesh