extends Node3D

class_name CarModel

@onready var car: Car = get_parent()
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	mesh_instance.rotation.z = -car.angular_speed * 0.1
