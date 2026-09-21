extends Node

class_name Driver

@export var show_debug: bool = false

@export var is_human: bool = false
@export var ideal_line_offset: float = -2.0
@export var line_offset_margin: float = 0.0
@export var steering_damping: float = 0.01
@export var brake_lookahead_distance: float = 60.0
@export var curvature_sample_step: float = 5.0
@export var pursuit_min_lookahead: float = 10.0
@export var pursuit_lookahead_time: float = 0.3
@export var enemy_detection_distance: float = 20.0
@export var rotate_axis_min: float = -2.0
@export var rotate_axis_max: float = 2.0
@export var move_axis_min: float = -1.0
@export var move_axis_max: float = 1.0


@onready var track_path: TrackPath = get_tree().current_scene.get_node("TrackPath")
@onready var race_manager: RaceManager = get_tree().current_scene.get_node("RaceManager")
@onready var car: Car = get_parent() as Car

var _scratch_track_segment: TrackSegment = TrackSegment.new()

# The maximum yaw rate the car can actually sustain depends on which way it
# needs to turn: car.rotate_axis is clamped to [rotate_axis_min,
# rotate_axis_max], which need not be symmetric. Turning one way is
# limited by rotate_axis_max, the other by rotate_axis_min, so callers must
# pick the right bound for the turn direction they're evaluating.
func _max_yaw_rate(turn_sign: float) -> float:
	var axis_limit: float = rotate_axis_max if turn_sign >= 0.0 else absf(rotate_axis_min)
	return axis_limit * car.rotate_speed

# The car's body must still fit within the track along the racing line.
# Clamp the offset so the car's near edge stays at least line_offset_margin
# from the wall.
func _target_line_offset(segment: TrackSegment) -> float:
	var max_offset: float = segment.track_width * 0.5 - car.width * 0.5 - line_offset_margin
	return clampf(segment.race_line_offset, -max_offset, max_offset)


# Look at every other car on the track and, among those within
# enemy_detection_distance ahead of us (measured along the track), find the
# closest one. If one is found, dodge it by a full car width to whichever
# side it isn't on - the side is determined by projecting its position onto
# our basis.x: a positive projection means it's to our right, so we offset
# left (negative), and vice versa.
func _enemies_offset(track_position: TrackPosition) -> float:
	var closest_car := race_manager.find_closest_car_ahead(
		car,
		enemy_detection_distance
	)
	if closest_car == null:
		return 0.0

	var closest_distance := fposmod(
		closest_car.track_position.offset - track_position.offset,
		track_path.track_length
	)
	var closest_lateral_projection := (
		closest_car.transform.origin - car.transform.origin
	).dot(track_position.transform.basis.x)
	var correction: float = car.width * 4.0 * (1.0 - closest_distance / enemy_detection_distance)

	return -correction if closest_lateral_projection >= 0.0 else correction

# Displace a target point ideal_line_offset along the track transform's
# basis.x (e.g. to overtake or defend a position), clamped so the resulting
# point stays within the track width at that position.
func _apply_ideal_line_offset(target: Vector3, track_position: TrackPosition) -> Vector3:
	var offset: float = ideal_line_offset

	var enemies_offset: float = _enemies_offset(track_position)

	if enemies_offset != 0.0:
		offset = enemies_offset
	
	var car_offset: float = track_position.lateral_offset
	var track_max_offset: float = track_position.track_segment.track_width * 0.5 - car.width * 0.5 - line_offset_margin
	var min_offset: float = -track_max_offset if car_offset >= 0.0 else -track_max_offset - car_offset
	var max_offset: float = track_max_offset if car_offset <= 0.0 else track_max_offset - car_offset
	var total_offset = clampf(offset, min_offset, max_offset)

	return target + track_position.transform.basis.x * total_offset
	
func _physics_process(_delta: float) -> void:
	if is_human:
		car.move_axis = Input.get_axis("backward", "forward")
		car.rotate_axis = Input.get_axis("left", "right") + Input.get_axis("power_left", "power_right")
	else:
		var car_transform = car.transform

		# The forward speed car.gd will actually command is move_axis *
		# max_speed, so if move_axis is clamped to a range other than [-1, 1]
		# the car's reachable top speed changes accordingly.
		var effective_max_speed: float = car.max_speed * move_axis_max

		# If move_axis can't go negative, the car can't actively brake or
		# reverse - forward_speed can only bleed off via z_drag once
		# move_axis is 0, which decelerates far more gently than
		# car.acceleration. Use whichever deceleration is actually achievable
		# so the braking lookahead doesn't assume braking power the car
		# doesn't have.
		var braking_deceleration: float = car.acceleration if move_axis_min < 0.0 else car.z_drag

		var local_velocity: Vector3 = car_transform.basis.transposed() * car.velocity
		if absf(local_velocity.x) < car.x_drag_threshold:
			local_velocity.x = 0.0
		var planar_velocity := Vector2(local_velocity.x, local_velocity.z)
		var speed := planar_velocity.length()

		# A fixed lookahead distance makes the pursuit target's bearing swing
		# more rapidly (in angle per second) as speed increases, since the car
		# covers the fixed distance to the target faster. That over-excites the
		# steering response at high speed and shows up as oscillation. Scaling
		# the lookahead distance with speed keeps the target's angular sweep
		# rate roughly constant across speeds, damping out the high-speed
		# wobble without softening low-speed cornering precision.
		var pursuit_lookahead: float = pursuit_min_lookahead + speed * pursuit_lookahead_time

		track_path.get_track_segment_at_offset(car.track_position.offset + pursuit_lookahead, _scratch_track_segment)
		var ai_transform: Transform3D = _scratch_track_segment.transform
		var ai_target: Vector3 = ai_transform.origin + ai_transform.basis.x * _target_line_offset(_scratch_track_segment)
	 	
		ai_target = _apply_ideal_line_offset(ai_target, car.track_position)
			
		if show_debug:
			DebugDraw3D.draw_line(car_transform.origin,ai_target, Color(1, 1, 0))

		#DebugDraw3D.draw_line(car_transform.origin,ai_target, Color(1, 1, 0))

		var distance: float = car_transform.origin.distance_to(ai_target)
		var target_direction: Vector3 = car_transform.basis.z
		if distance > 0.000001:
			target_direction = (ai_target - car_transform.origin) / distance

		var pursuit_reference_direction: Vector3 = car_transform.basis.z
		var local_planar_velocity := Vector3(local_velocity.x, 0.0, local_velocity.z)
		if local_planar_velocity.length_squared() > 0.000001:
			pursuit_reference_direction = (car_transform.basis * (-local_planar_velocity)).normalized()

		var angle: float = pursuit_reference_direction.signed_angle_to(target_direction, car_transform.basis.y)

		# Pure-pursuit against the car's effective planar motion. car.gd snaps
		# tiny lateral velocity to zero via x_drag_threshold, so the AI applies
		# the same deadband before estimating the arc to the target.
		var curvature: float = 2.0 * sin(angle) / distance if distance != 0.0 else 0.0
		var desired_yaw_rate: float = curvature * speed

		# The pure pursuit yaw rate above is a proportional ("P") term on heading
		# error. car.gd doesn't turn instantly though: rotate_acceleration makes
		# angular_speed lag behind rotate_axis, so a pure-P controller driving a
		# lagging actuator is an under-damped system that rings as it converges
		# onto the racing line (visible as oscillation even on straight sections).
		# Subtracting a fraction of the car's current yaw rate acts as a
		# derivative/damping term (PD control) that kills the ringing.
		var rotate_speed: float = desired_yaw_rate - steering_damping * car.angular_speed

		car.rotate_axis = clampf(rotate_speed / car.rotate_speed, rotate_axis_min, rotate_axis_max)
		# The immediate target's own curvature already limits our speed (see
		# below), but that only accounts for the corner we're pursuing right
		# now. To brake early enough for a sharper corner further down the
		# track - without braking sooner than necessary - scan the racing
		# line's curvature at increasing distances ahead. Each sampled corner
		# limits the car to the speed it can safely be going *now* such that,
		# braking at the car's max deceleration over the remaining distance,
		# it arrives at exactly that corner's max cornering speed (the yaw
		# rate the car can actually hold in that corner's turn direction):
		# v_now = sqrt(v_corner^2 + 2 * a * d). The tightest such constraint
		# over all sampled corners wins.
		var max_corner_speed: float = _max_yaw_rate(curvature) / absf(curvature) if curvature != 0.0 else effective_max_speed
		var speed_limit: float = minf(effective_max_speed, max_corner_speed)

		var previous_point: Vector3 = ai_target
		var previous_direction: Vector3 = (ai_target - car_transform.origin).normalized()
		var distance_travelled: float = distance

		var sample_count: int = int(brake_lookahead_distance / curvature_sample_step)
		for i in sample_count:
			var sample_offset: float = pursuit_lookahead + curvature_sample_step * (i + 1)
			track_path.get_track_segment_at_offset(car.track_position.offset + sample_offset, _scratch_track_segment)
			var sample_transform: Transform3D = _scratch_track_segment.transform
			var sample_point: Vector3 = sample_transform.origin + sample_transform.basis.x * _target_line_offset(_scratch_track_segment)
			
			var sample_direction: Vector3 = (sample_point - previous_point).normalized()
			var turn_angle: float = previous_direction.signed_angle_to(sample_direction, sample_transform.basis.y)
			var sample_curvature: float = turn_angle / curvature_sample_step

			var sample_max_speed: float = minf(effective_max_speed, _max_yaw_rate(sample_curvature) / absf(sample_curvature) if sample_curvature != 0.0 else effective_max_speed)
			var speed_allowed_now: float = sqrt(sample_max_speed * sample_max_speed + 2.0 * braking_deceleration * distance_travelled)
			speed_limit = minf(speed_limit, speed_allowed_now)

			previous_point = sample_point
			previous_direction = sample_direction
			distance_travelled += curvature_sample_step

		car.move_axis = clampf(speed_limit / car.max_speed, move_axis_min, move_axis_max)
		
