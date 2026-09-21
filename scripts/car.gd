extends Node3D

class_name Car

@onready var track_path: TrackPath = get_tree().current_scene.get_node("TrackPath")
@onready var race_manager: RaceManager = get_tree().current_scene.get_node("RaceManager")

@export var fly_height: float = 0.5
@export var acceleration: float = 40.0
@export var max_speed: float = 60.0
@export var z_drag: float = 4.0
@export var x_drag: float = 15.0
@export var x_drag_threshold: float = 10.0
@export var slip_drag: float = 2.0
@export var rotate_speed: float = 1.5
@export var rotate_acceleration: float = 6.0
@export var width: float = 1.9
@export var length: float = 3.4
@export var boundary_margin: float = 0.1

var velocity: Vector3 = Vector3.ZERO
var angular_speed: float = 0.0

var move_axis: float = 0.0
var rotate_axis: float = 0.0

var track_position: TrackPosition = TrackPosition.new()
var _scratch_corners: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]

@onready var old_location: Vector3 = transform.origin

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	race_manager.register_car(self)


func _exit_tree() -> void:
	if is_instance_valid(race_manager):
		race_manager.unregister_car(self)


func apply_collision_displacement(displacement: Vector3) -> void:
	transform.origin += displacement
	old_location += displacement


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	pass

func _physics_process(delta: float) -> void:

	var local_velocity: Vector3 = transform.basis.transposed() * velocity

	angular_speed = move_toward(angular_speed, rotate_axis * rotate_speed, rotate_acceleration * delta)
	transform.basis = transform.basis.orthonormalized()
	var yaw_axis: Vector3 = transform.basis.y
	if yaw_axis.length_squared() <= 0.000001:
		push_warning("Car yaw axis became degenerate; resetting rotation basis.")
		transform.basis = Basis.IDENTITY
		yaw_axis = Vector3.UP
	transform.basis = transform.basis.rotated(yaw_axis.normalized(), -angular_speed * delta)

	# x drag
	local_velocity.x = move_toward(local_velocity.x, 0.0, x_drag * delta)


	# snap local lateral velocity to zero if it's very small
	if absf(local_velocity.x) < x_drag_threshold:
		local_velocity.x = 0.0

	# forward is -z, so track speed as a positive "forward" value for clarity
	var forward_speed: float = -local_velocity.z
	if move_axis != 0.0:
		forward_speed = move_toward(forward_speed, move_axis * max_speed, acceleration * delta)
	else:
		forward_speed = move_toward(forward_speed, 0.0, z_drag * delta)

	# slipping sideways saps forward speed
	forward_speed = move_toward(forward_speed, 0.0, absf(local_velocity.x) * slip_drag * delta)

	local_velocity.z = -forward_speed

	transform.origin += transform.basis * local_velocity * delta

	# handle collisions

	var half_width: float = width * 0.5
	var half_length: float = length * 0.5

	# Cheap early-out: query the track position once at the car's own center
	# (needed anyway for the final alignment step below) and compare against
	# a conservative bound - the car's half-diagonal, i.e. the farthest any
	# corner can possibly be from the center regardless of heading. If even
	# that worst case corner distance keeps every corner within the track
	# width, none of the 4 corners can be outside, so the expensive per-corner
	# track_position queries can be skipped entirely.
	#
	# The center's closest-offset search is reused for the corner queries too:
	# boundary_margin/width are small relative to the curve's curvature, so
	# the corners' true closest offsets are effectively the same as the
	# center's, making a fresh get_closest_offset search per corner redundant.
	
	track_path.get_track_position(transform.origin, track_position)
	
	var center_path_transform: Transform3D = track_position.transform
	var center_lateral_offset: float = track_position.lateral_offset
	var center_track_width: float = track_position.track_segment.track_width

	var half_diagonal: float = Vector2(half_width, half_length).length()
	var safe_lateral: float = center_track_width * 0.5 - boundary_margin - half_diagonal

	var worst_overshoot: float = 0.0
	var worst_push_direction: Vector3 = Vector3.ZERO

	if absf(center_lateral_offset) > safe_lateral:
		_scratch_corners[0] = transform.origin + transform.basis.x * half_width + transform.basis.z * half_length
		_scratch_corners[1] = transform.origin + transform.basis.x * half_width - transform.basis.z * half_length
		_scratch_corners[2] = transform.origin - transform.basis.x * half_width + transform.basis.z * half_length
		_scratch_corners[3] = transform.origin - transform.basis.x * half_width - transform.basis.z * half_length

		for corner in _scratch_corners:
			var corner_lateral_offset: float = MathUtils.lateral_offset(corner, center_path_transform)

			var corner_track_width: float = track_position.track_segment.track_width
			var max_lateral: float = corner_track_width * 0.5 - boundary_margin

			var overshoot: float = 0.0
			if corner_lateral_offset > max_lateral:
				overshoot = corner_lateral_offset - max_lateral
			elif corner_lateral_offset < -max_lateral:
				overshoot = corner_lateral_offset + max_lateral

			if absf(overshoot) > absf(worst_overshoot):
				worst_overshoot = overshoot
				worst_push_direction = center_path_transform.basis.x

	# pull the worst-offending corner back within the track boundary
	if worst_overshoot != 0.0:
		transform.origin -= worst_push_direction * worst_overshoot

	# align position to track

	var path_transform: Transform3D = track_position.transform
	var lateral_offset: float = track_position.lateral_offset

	if worst_overshoot != 0.0:
		# the collision push moved the origin, but only laterally by a small
		# amount, so the along-track offset is still center_offset - reuse it
		# instead of running another get_closest_offset search
		track_path.get_track_position_at_offset(transform.origin, track_position.offset, track_position)
		path_transform = track_position.transform
		lateral_offset = track_position.lateral_offset
	else:
		path_transform = center_path_transform
		lateral_offset = center_lateral_offset

	# we only snap y axis to prevent the snapped position from messing up the physics
	var snapped_position: Vector3 = path_transform.origin + path_transform.basis.x * lateral_offset + path_transform.basis.y * fly_height
	transform.origin.y = snapped_position.y

	# align rotation to track: rotate basis by the shortest arc from its up to the track's up
	
	transform.basis = MathUtils.y_aligned_basis(transform.basis, path_transform.basis.y)

	velocity = (transform.origin - old_location) / delta
	old_location = transform.origin
	
