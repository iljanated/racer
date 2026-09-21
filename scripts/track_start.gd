@tool

extends TrackDraggable

class_name TrackStart

@export var grid_spot_count: int = 20 :
	set(value):
		grid_spot_count = value
		_instantiate_grid_spots()
@export var spacing: float = 8.0 :
	set(value):
		spacing = value
		_position_grid_spots()
@export var initial_offset: float = 4.0 :
	set(value):
		initial_offset = value
		_position_grid_spots()
@export var center_offset: float = 0.5 :
	set(value):
		center_offset = value
		_position_grid_spots()

var grid_spots: Array[Node3D] = []

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	super._ready()
	_instantiate_grid_spots()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func _on_track_position_changed() -> void:
	_position_grid_spots()

func _position_grid_spots() -> void:
	# Placeholder for positioning grid spots.
	# Implement the logic to position grid spots based on the track start.
	pass

func _instantiate_grid_spots() -> void:
	# Placeholder for instantiating grid spots.
	# Implement the logic to create and add grid spot nodes as children.
	for i in range(grid_spot_count):
		var grid_spot := Node3D.new()
		add_child(grid_spot)
		grid_spots.append(grid_spot)

	_position_grid_spots()