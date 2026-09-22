@tool
extends Node3D

class_name TrackDraggable

@export var track_offset: float = 0.0 :
	set(value):
		track_offset = value
		_apply_track_transform_at_offset.call_deferred()

var track_path: TrackPath

var _snap_pending := false
var _snapping := false

func _ready() -> void:
	track_path = _get_track_path()
	if track_path == null:
		push_warning("TrackDraggable could not find TrackPath as a direct child of the scene root.")
	elif not track_path.is_connected("track_segments_updated", _on_track_segments_updated):
		track_path.connect("track_segments_updated", _on_track_segments_updated)
	set_notify_transform(Engine.is_editor_hint())
	_apply_track_transform_at_offset.call_deferred()


func _exit_tree() -> void:
	if track_path != null and track_path.is_connected("track_segments_updated", _on_track_segments_updated):
		track_path.disconnect("track_segments_updated", _on_track_segments_updated)


func _notification(what: int) -> void:
	if (
		what == NOTIFICATION_TRANSFORM_CHANGED
		and Engine.is_editor_hint()
		and not _snapping
		and not _snap_pending
	):
		_snap_pending = true
		_snap_to_track.call_deferred()


func _snap_to_track() -> void:
	_snap_pending = false

	if not is_inside_tree():
		return

	if track_path == null:
		return

	track_offset = track_path.get_offset_along_track(transform.origin)
	_apply_track_transform_at_offset()


func _on_track_segments_updated() -> void:
	_apply_track_transform_at_offset.call_deferred()


func _apply_track_transform_at_offset() -> void:
	if not is_inside_tree():
		return

	if track_path == null:
		return

	var snapped_transform := track_path.get_transform_at_offset(track_offset)

	if global_transform.is_equal_approx(snapped_transform):
		return

	_snapping = true
	global_transform = snapped_transform
	_on_track_position_changed()
	_snapping = false


func _get_track_path() -> TrackPath:
	var scene_root := owner
	if scene_root == null:
		scene_root = get_tree().current_scene

	if scene_root == null:
		return null

	return scene_root.get_node_or_null("TrackPath") as TrackPath

func _on_track_position_changed() -> void:
	# Placeholder for handling track position changes.
	# You can override this function in a subclass or connect to it as needed.
	pass
