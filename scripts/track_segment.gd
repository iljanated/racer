extends RefCounted

class_name TrackSegment

var track_width: float = 17.0
var race_line_offset: float = 0.0
var transform: Transform3D = Transform3D()

func init(other: TrackSegment) -> void:
	track_width = other.track_width
	race_line_offset = other.race_line_offset
	transform = other.transform

static func lerp_into(segment0: TrackSegment, segment1: TrackSegment, delta: float, out_result: TrackSegment) -> void:
	out_result.track_width = lerp(segment0.track_width, segment1.track_width, delta)
	out_result.race_line_offset = lerp(segment0.race_line_offset, segment1.race_line_offset, delta)
	out_result.transform = segment0.transform.interpolate_with(segment1.transform, delta)
