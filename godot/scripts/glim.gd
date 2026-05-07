extends Node3D

# Glim — Tux's wisp companion (Navi equivalent). Tiny floating spark of
# the Source. Follows the player at a camera-relative shoulder offset
# with smooth lag, gentle bob, and an idle pulse. No interaction logic
# yet; this is presence + personality.

@export var follow_smooth: float = 5.0
@export var bob_amplitude: float = 0.08
@export var bob_freq: float = 2.5
@export var pulse_freq: float = 1.8
@export var shoulder_offset: Vector3 = Vector3(-0.6, 1.4, -0.4)

var player: Node3D = null
var camera: Node = null
var _t: float = 0.0

@onready var mesh: MeshInstance3D = $Mesh
@onready var light: OmniLight3D = $Light
var _base_emission: float = 1.0


func _ready() -> void:
    var ps := get_tree().get_nodes_in_group("player")
    if ps.size() > 0:
        player = ps[0]
    # Snag the camera the player is bound to.
    if player and "camera" in player:
        camera = player.camera
    if light:
        _base_emission = light.light_energy


func _process(delta: float) -> void:
    _t += delta

    # Pulse light + mesh emission in unison.
    var pulse: float = 0.85 + 0.15 * sin(_t * pulse_freq * TAU)
    if light:
        light.light_energy = _base_emission * pulse

    if not player or not is_instance_valid(player):
        return

    # Camera-relative shoulder offset so Glim drifts to whichever side
    # of Tux the camera currently sees as "left".
    var cam_yaw: float = 0.0
    if camera and camera.has_method("get_yaw"):
        cam_yaw = camera.get_yaw()
    var fwd: Vector3 = Vector3(-sin(cam_yaw), 0, -cos(cam_yaw))
    var right: Vector3 = Vector3(cos(cam_yaw), 0, -sin(cam_yaw))
    var world_offset: Vector3 = right * shoulder_offset.x \
                              + Vector3(0, shoulder_offset.y, 0) \
                              + fwd * shoulder_offset.z
    var bob: float = sin(_t * bob_freq) * bob_amplitude
    var target: Vector3 = player.global_position + world_offset + Vector3(0, bob, 0)
    global_position = global_position.lerp(target, clamp(delta * follow_smooth, 0.0, 1.0))
