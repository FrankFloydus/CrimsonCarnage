extends RefCounted
## Samples the overcast reference atmosphere's isotropic distant-light approximation.

# Linear sky luminance at 6 km, sampled uniformly by the Sun's world-up component.
const DISTANT_SKY := [
	Vector3(0.02710001, 0.01953280, 0.02105530),
	Vector3(0.04663887, 0.05347705, 0.06939554),
	Vector3(0.05506566, 0.07673521, 0.11455893),
	Vector3(0.05929612, 0.09080406, 0.14613290),
	Vector3(0.06175932, 0.09978665, 0.16799263),
	Vector3(0.06335349, 0.10592018, 0.18370574),
	Vector3(0.06446411, 0.11034421, 0.19544580),
	Vector3(0.06528063, 0.11367664, 0.20451948),
	Vector3(0.06590520, 0.11627153, 0.21172377),
	Vector3(0.06639823, 0.11834818, 0.21757850),
	Vector3(0.06679699, 0.12004607, 0.22242454),
	Vector3(0.06712618, 0.12146010, 0.22650167),
	Vector3(0.06740249, 0.12265560, 0.22997814),
	Vector3(0.06763755, 0.12367880, 0.23297479),
	Vector3(0.06784011, 0.12456512, 0.23558684),
	Vector3(0.06801642, 0.12533999, 0.23788273),
	Vector3(0.06817130, 0.12602305, 0.23991589),
]


static func sample(sun_height: float) -> Vector3:
	var position := clampf(sun_height, 0.0, 1.0) * (DISTANT_SKY.size() - 1)
	var lower := floori(position)
	var upper := mini(lower + 1, DISTANT_SKY.size() - 1)
	var start: Vector3 = DISTANT_SKY[lower]
	return start.lerp(DISTANT_SKY[upper], position - lower)
