extends Node

class_name RaceManager

@export_range(1, 10, 1) var collision_resolution_passes := 4

var cars: Array[Car] = []
var track_path: TrackPath
var _car_indices: Dictionary = {}
var _order_dirty := true
var _collision_right := PackedVector3Array()
var _collision_forward := PackedVector3Array()
var _collision_half_extents := PackedVector2Array()
var _collision_radii := PackedFloat32Array()
var _collision_pairs := PackedInt32Array()


func _init() -> void:
	# Run after cars and drivers so collisions are resolved against this
	# frame's final positions, not the positions from before cars moved.
	# Otherwise a car driving into another would render overlapped for a
	# full frame before ever being pushed apart. Cars/drivers still see the
	# same ordering "from the end of the previous frame" as before, since
	# they run earlier in the frame than this node's sort.
	process_physics_priority = 100

func _ready():
    # Wait until the engine finishes processing the current frame
	await get_tree().process_frame
	print("This runs after the initial frame setup is complete.")
	_init_race()

func _physics_process(delta: float) -> void:
	_sort_cars_by_track_offset()
	_resolve_car_collisions(delta)


func register_track_path(value: TrackPath) -> void:
	track_path = value


func unregister_track_path(value: TrackPath) -> void:
	if track_path == value:
		track_path = null


func register_car(car: Car) -> void:
	if not cars.has(car):
		cars.append(car)
		_order_dirty = true


func unregister_car(car: Car) -> void:
	cars.erase(car)
	_car_indices.erase(car.get_instance_id())
	_order_dirty = true

func _init_race() -> void:
	pass

func _sort_cars_by_track_offset() -> void:
	cars.sort_custom(_car_is_before)
	_car_indices.clear()

	for index in cars.size():
		_car_indices[cars[index].get_instance_id()] = index

	_order_dirty = false


func _car_is_before(first: Car, second: Car) -> bool:
	if first.track_position.offset == second.track_position.offset:
		return first.get_instance_id() < second.get_instance_id()
	return first.track_position.offset < second.track_position.offset


func _resolve_car_collisions(delta: float) -> void:
	var track_length := _get_track_length()
	if cars.size() < 2 or track_length <= 0.0:
		return

	_prepare_collision_cache()

	var maximum_radius := 0.0
	for radius in _collision_radii:
		maximum_radius = maxf(maximum_radius, radius)

	# Two cars cannot overlap if their separation along the track is greater
	# than the sum of their bounding-circle radii.
	var broad_phase_range := minf(maximum_radius * 2.0, track_length * 0.5)
	_build_collision_pairs(broad_phase_range, track_length)

	for pass_index in collision_resolution_passes:
		var resolved_any := false

		for pair_offset in range(0, _collision_pairs.size(), 2):
			resolved_any = _resolve_car_pair(
				_collision_pairs[pair_offset],
				_collision_pairs[pair_offset + 1],
				delta,
				pass_index == 0
			) or resolved_any

		if not resolved_any:
			break


func _prepare_collision_cache() -> void:
	var car_count := cars.size()
	_collision_right.resize(car_count)
	_collision_forward.resize(car_count)
	_collision_half_extents.resize(car_count)
	_collision_radii.resize(car_count)

	for index in car_count:
		var car := cars[index]
		var half_extents := Vector2(car.width, car.length) * 0.5
		_collision_right[index] = car.transform.basis.x.normalized()
		_collision_forward[index] = car.transform.basis.z.normalized()
		_collision_half_extents[index] = half_extents
		_collision_radii[index] = half_extents.length()


func _build_collision_pairs(broad_phase_range: float, track_length: float) -> void:
	_collision_pairs.clear()

	for subject_index in cars.size():
		var subject_offset := cars[subject_index].track_position.offset

		for step in range(1, cars.size()):
			var candidate_index := (subject_index + step) % cars.size()
			var candidate_offset := cars[candidate_index].track_position.offset
			var distance_ahead := fposmod(
				candidate_offset - subject_offset,
				track_length
			)
			if distance_ahead > broad_phase_range:
				break

			# When both circular directions fit the broad-phase range, array
			# order selects one direction so the pair is emitted only once.
			var distance_behind := fposmod(
				subject_offset - candidate_offset,
				track_length
			)
			if distance_behind <= broad_phase_range and subject_index > candidate_index:
				continue

			_collision_pairs.append(subject_index)
			_collision_pairs.append(candidate_index)


func _resolve_car_pair(
	first_index: int,
	second_index: int,
	delta: float,
	use_relative_velocity: bool
) -> bool:
	var first := cars[first_index]
	var second := cars[second_index]
	var first_right := _collision_right[first_index]
	var first_forward := _collision_forward[first_index]
	var second_right := _collision_right[second_index]
	var second_forward := _collision_forward[second_index]
	var center_delta := second.transform.origin - first.transform.origin

	# Most broad-phase candidates are still physically separated. Reject them
	# with one cheap planar bounding-circle test before projecting the AABB.
	var combined_radius := _collision_radii[first_index] + _collision_radii[second_index]
	if (
		center_delta.x * center_delta.x + center_delta.z * center_delta.z
		>= combined_radius * combined_radius
	):
		return false

	var local_center := Vector2(
		center_delta.dot(first_right),
		center_delta.dot(first_forward)
	)

	var first_half_extents := _collision_half_extents[first_index]
	var second_half_width := _collision_half_extents[second_index].x
	var second_half_length := _collision_half_extents[second_index].y

	# Project the second car's oriented footprint into the first car's local
	# X/Z axes. This forms the requested conservative local-space AABB.
	var second_half_extents := Vector2(
		absf(second_right.dot(first_right)) * second_half_width
			+ absf(second_forward.dot(first_right)) * second_half_length,
		absf(second_right.dot(first_forward)) * second_half_width
			+ absf(second_forward.dot(first_forward)) * second_half_length
	)
	var combined_half_extents := first_half_extents + second_half_extents
	var overlap := combined_half_extents - local_center.abs()

	if overlap.x <= 0.0 or overlap.y <= 0.0:
		return false

	var relative_velocity := second.velocity - first.velocity
	var local_relative_velocity := Vector2(
		relative_velocity.dot(first_right),
		relative_velocity.dot(first_forward)
	)
	var local_separation := Vector2.ZERO

	if use_relative_velocity and local_relative_velocity.length_squared() > 0.000001:
		# Rewind the relative motion until the second center exits the combined
		# AABB. The first reached boundary is the minimum separation along this
		# relative-motion direction.
		var direction := -local_relative_velocity.normalized()
		var distance_to_exit := INF

		if absf(direction.x) > 0.000001:
			var x_boundary := combined_half_extents.x * signf(direction.x)
			distance_to_exit = minf(
				distance_to_exit,
				(x_boundary - local_center.x) / direction.x
			)
		if absf(direction.y) > 0.000001:
			var y_boundary := combined_half_extents.y * signf(direction.y)
			distance_to_exit = minf(
				distance_to_exit,
				(y_boundary - local_center.y) / direction.y
			)

		# Relative velocity is only a valid explanation for the overlap if the
		# cars could have covered the rewind distance during the previous step.
		var maximum_rewind := local_relative_velocity.length() * delta + 0.001
		if distance_to_exit >= 0.0 and distance_to_exit <= maximum_rewind:
			local_separation = direction * (distance_to_exit + 0.001)

	# Stationary cars, or a degenerate relative-motion direction, use the
	# minimum penetration axis instead.
	if local_separation == Vector2.ZERO:
		if overlap.x < overlap.y:
			var direction_x := signf(local_center.x)
			if direction_x == 0.0:
				direction_x = 1.0 if second.get_instance_id() > first.get_instance_id() else -1.0
			local_separation.x = direction_x * (overlap.x + 0.001)
		else:
			var direction_y := signf(local_center.y)
			if direction_y == 0.0:
				direction_y = 1.0 if second.get_instance_id() > first.get_instance_id() else -1.0
			local_separation.y = direction_y * (overlap.y + 0.001)

	var world_separation := (
		first_right * local_separation.x
		+ first_forward * local_separation.y
	)
	first.apply_collision_displacement(-world_separation * 0.5)
	second.apply_collision_displacement(world_separation * 0.5)
	return true


func find_closest_car_ahead(
	subject: Car,
	maximum_distance: float
) -> Car:
	var track_length := _get_track_length()
	if cars.size() < 2 or track_length <= 0.0 or maximum_distance < 0.0:
		return null

	# Registration can occur after this frame's scheduled sort. Rebuild here
	# only in that exceptional case so normal per-car queries remain O(1).
	if _order_dirty:
		_sort_cars_by_track_offset()

	var subject_id := subject.get_instance_id()
	if not _car_indices.has(subject_id):
		return null

	var subject_index: int = _car_indices[subject_id]
	var closest_car: Car = cars[(subject_index + 1) % cars.size()]
	var distance_ahead := fposmod(
		closest_car.track_position.offset - subject.track_position.offset,
		track_length
	)

	return closest_car if distance_ahead <= maximum_distance else null


func get_cars_within_range(
	subject: Car,
	maximum_distance: float
) -> Array[Car]:
	var nearby_cars: Array[Car] = []
	var track_length := _get_track_length()
	if cars.size() < 2 or track_length <= 0.0 or maximum_distance < 0.0:
		return nearby_cars

	if _order_dirty:
		_sort_cars_by_track_offset()

	var subject_id := subject.get_instance_id()
	if not _car_indices.has(subject_id):
		return nearby_cars

	var subject_index: int = _car_indices[subject_id]
	var included_ids: Dictionary = {}

	# Walk forward in sorted track order until the circular distance is outside
	# the requested range. The iteration cap prevents revisiting the subject.
	for step in range(1, cars.size()):
		var candidate: Car = cars[(subject_index + step) % cars.size()]
		var distance_ahead := fposmod(
			candidate.track_position.offset - subject.track_position.offset,
			track_length
		)
		if distance_ahead > maximum_distance:
			break

		nearby_cars.append(candidate)
		included_ids[candidate.get_instance_id()] = true

	# Walk backward independently. For ranges greater than half a lap, a car
	# can be reached from both directions, so included_ids prevents duplicates.
	for step in range(1, cars.size()):
		var candidate: Car = cars[posmod(subject_index - step, cars.size())]
		var distance_behind := fposmod(
			subject.track_position.offset - candidate.track_position.offset,
			track_length
		)
		if distance_behind > maximum_distance:
			break

		var candidate_id := candidate.get_instance_id()
		if not included_ids.has(candidate_id):
			nearby_cars.append(candidate)
			included_ids[candidate_id] = true

	return nearby_cars


func _get_track_length() -> float:
	return track_path.track_length if is_instance_valid(track_path) else 0.0
