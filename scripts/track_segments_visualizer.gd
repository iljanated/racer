@tool

extends Node3D

class_name TrackSegmentsVisualizer

@onready var track_path: TrackPath = get_parent() as TrackPath

var mesh_instances: Array[MeshInstance3D] = []

var material: StandardMaterial3D = StandardMaterial3D.new()

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if not track_path.is_connected("track_segments_updated", _on_track_segments_updated):
		track_path.connect("track_segments_updated", _on_track_segments_updated)

	material.albedo_color = Color(1, 0, 0)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	pass

func _on_track_segments_updated() -> void:
	print("Track segments updated.")
	_build_meshes.call_deferred()

func _build_meshes() -> void:
	var segments := track_path.track_segments
	var old_size = mesh_instances.size()
	var new_size = track_path.num_segments

	if old_size > new_size:
		for i in range(new_size - 1, old_size - 1):
			var old_mesh_instance : MeshInstance3D = mesh_instances[i]
			if is_instance_valid(old_mesh_instance):
				old_mesh_instance.queue_free()
	mesh_instances.resize(new_size)

	for i in new_size:
		if mesh_instances[i] == null:
			mesh_instances[i] = MeshInstance3D.new()
			var sphere_mesh := SphereMesh.new()
			sphere_mesh.radius = 1.0        # Default is 0.5
			sphere_mesh.height = 2.0        # Default is 1.0 (always double the radius for a perfect sphere)
			# 3. Assign the mesh resource to the node
			mesh_instances[i].mesh = sphere_mesh
			mesh_instances[i].material_override = material
			add_child(mesh_instances[i])
		
		var segment := segments[i]
		var mesh_instance := mesh_instances[i]
		mesh_instance.transform.origin = segment.transform.origin + segment.transform.basis.x * segment.race_line_offset
		
		
