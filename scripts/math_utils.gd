extends RefCounted

class_name MathUtils

static func lateral_offset(position: Vector3, path_transform: Transform3D) -> float:
    return (position - path_transform.origin).dot(path_transform.basis.x)

static func y_aligned_basis(basis: Basis, target_up: Vector3) -> Basis:
    var align_rotation: Quaternion = Quaternion(basis.y.normalized(), target_up.normalized())
    return Basis(align_rotation) * basis
