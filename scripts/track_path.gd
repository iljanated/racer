@tool
extends Node

class_name TrackPath

@onready var path3Ds: Array[Path3D] = []
@onready var race_manager: RaceManager = get_node("../RaceManager")

@export var track_segment_length: float = 10.0
@export var line_offset_margin: float = 4.0
@export_range(0.0, 1.0, 0.05) var race_line_curvature_weight: float = 0.85
@export_range(0.05, 1.0, 0.05) var race_line_relaxation: float = 0.25

var track_length: float = 0.0
var track_segments: Array[TrackSegment] = []
var num_segments: int = 0

var _track_dirty := false
var _track_update_running := false

var _scratch_track_segment: TrackSegment = TrackSegment.new()

signal track_segments_updated

func _ready() -> void:
	path3Ds.append($Path3D)

	if not Engine.is_editor_hint():
		race_manager.register_track_path(self)

	for path3d in path3Ds:
		path3d.curve.bake_interval = 5.0
		if not path3d.is_connected("curve_changed", _on_curve_changed):
			path3d.connect("curve_changed", _on_curve_changed.bind(path3d))
		_on_curve_changed(path3d)


func _exit_tree() -> void:
	if is_instance_valid(race_manager) and not Engine.is_editor_hint():
		race_manager.unregister_track_path(self)


func _get_total_track_length() -> float:
	var total_length: float = 0.0
	for path3d in path3Ds:
		total_length += path3d.curve.get_baked_length()
	return total_length

func _on_curve_changed(path3d: Path3D) -> void:
	track_length = _get_total_track_length()
	if _track_dirty:
		return
	_track_dirty = true
	print("Curve changed, updating track segments.")
	if not _track_update_running:
		_update_track_segments.call_deferred()

func get_track_position(point: Vector3, out_result: TrackPosition) -> void :
	var path3d: Path3D = path3Ds[0]
	var curve : Curve3D = path3d.curve
	var offset: float = curve.get_closest_offset(point)
	get_track_position_at_offset(point, offset, out_result)

# Same as get_track_position, but for callers that already know the point's
# approximate offset along the curve (e.g. nearby points such as a car's
# corners relative to its center) - skips the O(baked point count)
# get_closest_offset search and just samples directly at the given offset.
#
# Uses the precomputed track_segments (linearly interpolated) for both
# transform and track_width instead of sampling the raw curve. This is
# cheaper than curve.sample_baked_with_rotation, but note the position is
# only exact on straight sections - on curved sections it's a straight chord
# between the two nearest segments rather than the true arc, so it can
# disagree with get_closest_offset-based results (used elsewhere) by an
# amount that grows with track_segment_length and curve tightness.
func get_track_position_at_offset(point: Vector3, offset: float, out_result: TrackPosition) -> void:
	var path3d: Path3D = path3Ds[0]
	var curve : Curve3D = path3d.curve
	var path_transform: Transform3D = curve.sample_baked_with_rotation(offset, true, true)
	
	get_track_segment_at_offset(offset, _scratch_track_segment)
	var lateral_offset: float = MathUtils.lateral_offset(point, path_transform)

	out_result.offset = offset
	out_result.transform = path_transform
	out_result.lateral_offset = lateral_offset
	out_result.track_segment.init(_scratch_track_segment)

func get_track_transform(point: Vector3, offset: float) -> Transform3D:
	var path3d: Path3D = path3Ds[0]
	var curve : Curve3D = path3d.curve
	var total_length = curve.get_baked_length()
	var wrapped_offset: float = fmod(curve.get_closest_offset(point) + offset, total_length)
	return curve.sample_baked_with_rotation(wrapped_offset, true, true)

func get_transform_at_offset(offset: float) -> Transform3D:
	var path3d: Path3D = path3Ds[0]
	var curve : Curve3D = path3d.curve
	return curve.sample_baked_with_rotation(offset, true, true)

func get_offset_along_track(point: Vector3) -> float:
	var path3d: Path3D = path3Ds[0]
	var curve : Curve3D = path3d.curve
	return curve.get_closest_offset(point)

func get_track_segment(point: Vector3, offset: float, out_result: TrackSegment) -> void:
	var path3d: Path3D = path3Ds[0]
	var curve : Curve3D = path3d.curve
	var total_offset := curve.get_closest_offset(point) + offset
	get_track_segment_at_offset(total_offset, out_result)

func get_track_segment_at_offset(offset: float, out_result: TrackSegment) -> void:

	if num_segments == 0:
		return

	var segment0_index: int = int(offset / track_segment_length) % num_segments
	var segment1_index: int = (segment0_index + 1) % num_segments
	var delta = fmod(offset, track_segment_length) / track_segment_length

	TrackSegment.lerp_into(track_segments[segment0_index], track_segments[segment1_index], delta, out_result)

func _update_track_segments() -> void:
	if _track_update_running:
		_track_dirty = true
		return

	_track_update_running = true
	if not _track_dirty:
		_track_dirty = true

	while _track_dirty:
		_track_dirty = false
		# Implement the logic to update track segments along the track
		num_segments = int(track_length / track_segment_length)
		var old_size = track_segments.size()
		track_segments.resize(num_segments)

		if num_segments > old_size:
			for i in range(old_size, num_segments):
				track_segments[i] = TrackSegment.new()

		var path3d: Path3D = path3Ds[0]
		var curve = path3d.curve

		for i in num_segments:
			if track_segments[i] == null:
				track_segments[i] = TrackSegment.new()
		
			var segment: TrackSegment = track_segments[i]
			segment.transform = curve.sample_baked_with_rotation(track_segment_length * i, true, true)

		emit_signal("track_segments_updated")
		await _optimize_race_line()

	_track_update_running = false
	

## Builds a closed racing line by iteratively moving each sampled point toward
## a blend of distance-reduction and curvature-reduction targets.
##
## The distance target attracts p[i] to the midpoint of p[i-d] and p[i+d].
## This shortens the path and retains the original optimizer's tendency to
## approach corner apexes.
##
## Curvature is represented by the discrete second derivative:
##     D2[i] = p[i-d] - 2*p[i] + p[i+d]
## Minimizing variation between neighboring second derivatives produces the
## five-point fairing target:
##     target = (4*(p[i-d] + p[i+d]) - p[i-2d] - p[i+2d]) / 6
## Applying both targets at several sample spacings smooths local steering as
## well as longer corner-entry and corner-exit transitions.
##
## Each iteration uses a snapshot of the entire line (Jacobi iteration), so
## processing order does not bias the result. New world-space points are
## projected onto their segment's lateral axis and clamped to the usable track
## width before all offsets are committed simultaneously.
func _optimize_race_line() -> void:
	# The five-point curvature stencil needs two distinct neighbors on each
	# side of every point.
	if num_segments < 5:
		return

	# With the default 10 m segment length, a spread of three evaluates the
	# racing line over approximately 10 m, 20 m, and 30 m scales.
	var iterations := 500
	var segment_spread := mini(3, floori((num_segments - 1) / 2.0))
	var convergence_threshold := 0.001

	# positions is an immutable snapshot for the current iteration.
	# new_offsets delays writes until every point has been evaluated.
	var positions := PackedVector3Array()
	var new_offsets := PackedFloat32Array()
	positions.resize(num_segments)
	new_offsets.resize(num_segments)

	for iteration in iterations:
		# Convert each scalar lateral offset into its world-space line point.
		for index in num_segments:
			var segment := track_segments[index]
			positions[index] = (
				segment.transform.origin
				+ segment.transform.basis.x * segment.race_line_offset
			)

		var maximum_change := 0.0

		for index in num_segments:
			var current := positions[index]
			var distance_target := Vector3.ZERO
			var curvature_target := Vector3.ZERO

			# Accumulate short-, medium-, and long-range targets. posmod wraps
			# every lookup around the closed circuit.
			for spacing in range(1, segment_spread + 1):
				var previous := positions[posmod(index - spacing, num_segments)]
				var next := positions[posmod(index + spacing, num_segments)]
				var previous_previous := positions[posmod(index - spacing * 2, num_segments)]
				var next_next := positions[posmod(index + spacing * 2, num_segments)]

				# Dividing this sum by 2 * segment_spread below produces the
				# mean midpoint of all surrounding point pairs.
				distance_target += previous + next

				# This five-point target reduces changes in the discrete second
				# derivative, which acts as the curvature proxy.
				curvature_target += (
				4.0 * (previous + next)
					- previous_previous
					- next_next
				) / 6.0

			distance_target /= segment_spread * 2.0
			curvature_target /= segment_spread

			# The exported weight selects the objective blend. Relaxation moves
			# only partway to that target to keep repeated updates stable.
			var optimization_target := distance_target.lerp(
				curvature_target,
				race_line_curvature_weight
			)
			var new_position := current.lerp(optimization_target, race_line_relaxation)
			var segment := track_segments[index]

			# Reserve line_offset_margin on both sides of the usable track.
			var maximum_offset := maxf(
				0.0,
				segment.track_width * 0.5 - line_offset_margin
			)

			# Project the unconstrained world-space point onto this segment's
			# lateral axis, then enforce the track-width constraint.
			new_offsets[index] = clampf(
				(new_position - segment.transform.origin).dot(segment.transform.basis.x),
				-maximum_offset,
				maximum_offset
			)

			# Record the largest update for the convergence test.
			maximum_change = maxf(
				maximum_change,
				absf(new_offsets[index] - segment.race_line_offset)
			)

		# Commit simultaneously so no calculation observes a partially updated
		# racing line from this iteration.
		for index in num_segments:
			track_segments[index].race_line_offset = new_offsets[index]

		# Stop once every offset changes by less than one millimeter.
		if maximum_change < convergence_threshold:
			break

		# Keep the editor responsive during long optimization runs.
		if Engine.is_editor_hint() and iteration % 10 == 0:
			await get_tree().process_frame

	print("Race line optimization completed!")
	emit_signal("track_segments_updated")
