@tool
class_name DynamicSkyRadialStormSpawning
extends Resource
## Opt-in schedule for traveling Radial Storm actors owned by one DynamicSky rig.

enum SeasonMode { RIG_DATE, MANUAL }

## Enables future automatic storms. A storm already traveling completes its normal lifecycle.
@export var enabled: bool = false
## Fixed isolated spawn-sequence seed. A value of −1 chooses a fresh seed when the schedule starts.
@export_range(-1, 2147483647, 1, "or_greater") var random_seed: int = -1
## Shortest and longest wait between storms, in game-time seconds.
@export var wait_seconds: Vector2 = Vector2(1000.0, 2000.0)
## Multiplier applied to the first wait after enabling. Zero schedules the first check after 0.1 seconds.
@export_range(0.0, 1.0, 0.01, "or_greater") var first_wait_multiplier: float = 0.5

@export_group("Travel")
## Distances upstream and downstream of the control point, in world meters.
@export var travel_distances: Vector2 = Vector2(25000.0, 25000.0)
## Full width of the random heading interval. At 60 degrees the route can turn up to 30 degrees either way.
@export_range(0.0, 360.0, 0.1, "degrees") var direction_variation: float = 60.0
## Optional offset of the route center at a random azimuth, in world meters.
@export_range(0.0, 25000.0, 1.0, "or_greater", "suffix:m") var route_offset: float = 0.0
## Shortest and longest travel durations, in game-time seconds.
@export var lifetime_seconds: Vector2 = Vector2(500.0, 700.0)
## Fraction of the lifetime used by both fades together. At 0.2 each fade takes 10% of the lifetime.
@export_range(0.0, 1.0, 0.01) var fade_fraction: float = 0.2

@export_group("Footprint")
## Distance from the center where a scheduled storm stops influencing weather, in world meters.
@export_range(0.01, 40000.0, 1.0, "or_greater", "suffix:m") var outer_radius: float = 13000.0
## Authored material core fraction of the outer radius. The radial actor resolves its physical core separately.
@export_range(0.0, 1.0, 0.01) var inner_radius_fraction: float = 0.3

@export_group("Season")
## Uses the rig's civil date, or a manually authored season.
@export var season_mode: SeasonMode = SeasonMode.RIG_DATE
## Seasonal phase when Manual is selected or the rig has no date. 0 is spring and 4 returns to spring.
@export_range(0.0, 4.0, 0.01) var manual_season: float = 0.0
## Advances season selection by whole days relative to the current civil date.
@export var season_day_offset: int = 0
## Aligns seasons near March, June, September and December starts. Disable for solstice/equinox timing.
@export var meteorological_seasons: bool = true
## Candidate weather profiles and their relative weights in spring, summer, autumn and winter.
@export var probabilities: Array[DynamicSkyWeatherProbability]
