@tool
class_name DynamicSkyAstronomy
extends Resource
## Provides approximate Sun, Moon, and sidereal orientation for a civil date and location.
## Time uses a fixed UTC offset. The horizon is geometric and excludes atmospheric refraction.

const JULIAN_UNIX_EPOCH: float = 2440587.5
const JULIAN_J2000: float = 2451545.0
const SECONDS_PER_DAY: int = 86400
const MONTH_LENGTHS: Array[int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

## Gregorian year at the start of the sky clock.
@export_range(1900, 2100) var year: int = 2026:
	set(value):
		year = clampi(value, 1900, 2100)
		emit_changed()

## Gregorian month at the start of the sky clock. January is 1.
@export_range(1, 12) var month: int = 6:
	set(value):
		month = clampi(value, 1, 12)
		emit_changed()

## Day of the month. Sampling uses the month's last day if this is larger.
@export_range(1, 31) var day: int = 21:
	set(value):
		day = clampi(value, 1, 31)
		emit_changed()

## Geographic longitude in degrees. East of Greenwich is positive.
@export_range(-180.0, 180.0, 0.01, "degrees") var longitude: float = 0.0:
	set(value):
		longitude = clampf(value, -180.0, 180.0)
		emit_changed()

## Fixed difference from UTC in hours. Author any daylight-saving adjustment here.
@export_range(-12.0, 14.0, 0.25, "suffix:h") var utc_offset_hours: float = 0.0:
	set(value):
		utc_offset_hours = clampf(value, -12.0, 14.0)
		emit_changed()


## Samples world-space directions and a world-to-equatorial star basis at a civil hour.
## Latitude is north-positive in degrees. At zero north rotation, north is world negative Z.
## Phase runs from new (0) through full (0.5) and back to new (1).
func sample(
	hour: float, latitude: float, north_rotation: float, day_offset: int = 0,
) -> Dictionary[StringName, Variant]:
	var julian_date := _julian_date(hour, day_offset)
	var days_since_j2000 := julian_date - JULIAN_J2000
	# Geocentric apparent ecliptic longitude from the USNO solar approximation.
	# https://aa.usno.navy.mil/faq/sun_approx
	var mean_sun_anomaly := _radians(357.529 + 0.98560028 * days_since_j2000)
	var mean_sun_longitude := _radians(280.459 + 0.98564736 * days_since_j2000)
	var sun_longitude := mean_sun_longitude + deg_to_rad(
		1.915 * sin(mean_sun_anomaly) + 0.020 * sin(2.0 * mean_sun_anomaly)
	)
	var moon := _lunar_ecliptic(days_since_j2000 + 1.5, mean_sun_longitude, mean_sun_anomaly)
	var obliquity := deg_to_rad(23.439 - 0.00000036 * days_since_j2000)
	var ecliptic_to_equatorial := Basis(Vector3.RIGHT, obliquity)
	var sun_equatorial := ecliptic_to_equatorial * Vector3(
		cos(sun_longitude), sin(sun_longitude), 0.0
	)
	var moon_equatorial := ecliptic_to_equatorial * Vector3(
		cos(moon.y) * cos(moon.x), cos(moon.y) * sin(moon.x), sin(moon.y)
	)
	var world_to_equatorial := _star_basis(
		julian_date, clampf(latitude, -90.0, 90.0), north_rotation
	)
	var equatorial_to_world := world_to_equatorial.transposed()
	# Distance is in Earth radii. Move from the Earth's center to a surface observer.
	var moon_from_observer := equatorial_to_world * (moon_equatorial * moon.z) - Vector3.UP

	return {
		&"sun_direction": (equatorial_to_world * sun_equatorial).normalized(),
		&"moon_direction": moon_from_observer.normalized(),
		&"moon_phase": fposmod(moon.x - sun_longitude, TAU) / TAU,
		&"star_rotation": world_to_equatorial,
	}


## Returns the local Gregorian year, month, and day at a whole-day offset.
func get_civil_date(day_offset: int = 0) -> Dictionary:
	var date := Time.get_datetime_dict_from_unix_time(
		_civil_midnight_unix() + day_offset * SECONDS_PER_DAY
	)
	return {"year": date.year, "month": date.month, "day": date.day}


func _julian_date(hour: float, day_offset: int) -> float:
	return (
		JULIAN_UNIX_EPOCH + float(_civil_midnight_unix()) / float(SECONDS_PER_DAY)
		+ float(day_offset) + (hour - utc_offset_hours) / 24.0
	)


func _civil_midnight_unix() -> int:
	var last_day := MONTH_LENGTHS[month - 1]
	if month == 2 and year % 4 == 0 and (year % 100 != 0 or year % 400 == 0):
		last_day += 1
	return Time.get_unix_time_from_datetime_dict({
		"year": year, "month": month, "day": mini(day, last_day),
	})


func _star_basis(julian_date: float, latitude: float, north_rotation: float) -> Basis:
	# Greenwich mean sidereal time from USNO, treating UTC as UT1.
	# https://aa.usno.navy.mil/faq/GAST
	var midnight := floorf(julian_date - 0.5) + 0.5
	var utc_hours := (julian_date - midnight) * 24.0
	var centuries := (julian_date - JULIAN_J2000) / 36525.0
	var gmst_hours := (
		6.697375 + 0.065709824279 * (midnight - JULIAN_J2000)
		+ 1.0027379 * utc_hours + 0.0000258 * centuries * centuries
	)
	var meridian := _radians(gmst_hours * 15.0 + longitude)
	var latitude_rad := deg_to_rad(latitude)
	var east := Vector3(-sin(meridian), cos(meridian), 0.0)
	var up := Vector3(
		cos(latitude_rad) * cos(meridian),
		cos(latitude_rad) * sin(meridian),
		sin(latitude_rad)
	)
	var south := east.cross(up)
	return Basis(east, up, south) * Basis(Vector3.UP, deg_to_rad(-north_rotation))


# Paul Schlyter's lunar elements and leading perturbations use JD 2451543.5.
# https://stjarnhimlen.se/comp/ppcomp.html
static func _lunar_ecliptic(
	days: float, sun_mean_longitude: float, sun_mean_anomaly: float,
) -> Vector3:
	const ECCENTRICITY: float = 0.0549
	const SEMI_MAJOR_AXIS: float = 60.2666
	var node_longitude := _radians(125.1228 - 0.0529538083 * days)
	var inclination := deg_to_rad(5.1454)
	var perigee := _radians(318.0634 + 0.1643573223 * days)
	var anomaly := _radians(115.3654 + 13.0649929509 * days)
	var eccentric_anomaly := anomaly + ECCENTRICITY * sin(anomaly) * (
		1.0 + ECCENTRICITY * cos(anomaly)
	)
	var orbital_x := cos(eccentric_anomaly) - ECCENTRICITY
	var orbital_y := sqrt(1.0 - ECCENTRICITY * ECCENTRICITY) * sin(eccentric_anomaly)
	var argument := atan2(orbital_y, orbital_x) + perigee
	var orbital_plane := Vector3(cos(argument), sin(argument), 0.0)
	var ecliptic := orbital_plane.rotated(Vector3.RIGHT, inclination).rotated(
		Vector3.BACK, node_longitude
	)
	var ecliptic_longitude := atan2(ecliptic.y, ecliptic.x)
	var ecliptic_latitude := asin(ecliptic.z)
	var distance := SEMI_MAJOR_AXIS * sqrt(orbital_x * orbital_x + orbital_y * orbital_y)

	var elongation := node_longitude + perigee + anomaly - sun_mean_longitude
	var latitude_argument := perigee + anomaly
	var double_elongation := 2.0 * elongation
	# Evection, variation, annual equation, and the smaller longitude corrections.
	ecliptic_longitude += deg_to_rad(
		-1.274 * sin(anomaly - double_elongation)
		+ 0.658 * sin(double_elongation)
		- 0.186 * sin(sun_mean_anomaly)
		- 0.059 * sin(2.0 * anomaly - double_elongation)
		- 0.057 * sin(anomaly - double_elongation + sun_mean_anomaly)
		+ 0.053 * sin(anomaly + double_elongation)
		+ 0.046 * sin(double_elongation - sun_mean_anomaly)
		+ 0.041 * sin(anomaly - sun_mean_anomaly)
		- 0.035 * sin(elongation)
		- 0.031 * sin(anomaly + sun_mean_anomaly)
		- 0.015 * sin(2.0 * latitude_argument - double_elongation)
		+ 0.011 * sin(anomaly - 2.0 * double_elongation)
	)
	ecliptic_latitude += deg_to_rad(
		-0.173 * sin(latitude_argument - double_elongation)
		- 0.055 * sin(anomaly - latitude_argument - double_elongation)
		- 0.046 * sin(anomaly + latitude_argument - double_elongation)
		+ 0.033 * sin(latitude_argument + double_elongation)
		+ 0.017 * sin(2.0 * anomaly + latitude_argument)
	)
	distance -= 0.58 * cos(anomaly - double_elongation) + 0.46 * cos(double_elongation)
	return Vector3(ecliptic_longitude, ecliptic_latitude, distance)


static func _radians(degrees: float) -> float:
	return deg_to_rad(fposmod(degrees, 360.0))
