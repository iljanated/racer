extends Camera3D

@export var target: Node3D

@export var follow_speed: float = 50.0

# the fixed ideal offset from the target
var _ideal_local_transform: Transform3D

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	_ideal_local_transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(3.7), 0.0, 0.0)), Vector3(0.0, 2.5, 5.5))


func _physics_process(delta: float) -> void:
	var ideal_global_transform: Transform3D = target.global_transform * _ideal_local_transform

	# frame-rate independent exponential smoothing toward the ideal transform
	var weight: float = 1.0 - exp(-follow_speed * delta)
	global_transform = global_transform.interpolate_with(ideal_global_transform, weight)
