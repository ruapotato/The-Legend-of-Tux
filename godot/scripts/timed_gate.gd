extends Node3D

# Bars that retract when the connected switch fires. After `open_duration`
# seconds the bars slam back down. Visually: drop the gate Y by
# `open_offset` while open.

signal opened()
signal closed()

@export var hit_switch_path: NodePath
@export var open_duration: float = 5.0
@export var open_offset: float = 2.5
@export var anim_time: float = 0.4

@onready var bars: Node3D = $Bars
var _is_open: bool = false
var _close_t: float = 0.0
var _anim_t: float = 0.0
var _start_y: float = 0.0


func _ready() -> void:
    if bars:
        _start_y = bars.position.y
    if hit_switch_path:
        var sw := get_node_or_null(hit_switch_path)
        if sw and sw.has_signal("activated"):
            sw.activated.connect(_on_switch_activated)


func _on_switch_activated() -> void:
    if _is_open:
        return
    _is_open = true
    _close_t = open_duration
    _anim_t = 0.0
    SoundBank.play_3d("gate_open", global_position)
    opened.emit()


func _process(delta: float) -> void:
    if not bars:
        return
    if _is_open:
        _close_t -= delta
        _anim_t = min(_anim_t + delta, anim_time)
        var phase := _anim_t / anim_time
        bars.position.y = _start_y + open_offset * ease(phase, 0.5)
        if _close_t <= 0.0:
            _is_open = false
            _anim_t = 0.0
            SoundBank.play_3d("gate_close", global_position)
            closed.emit()
    else:
        if _anim_t < anim_time:
            _anim_t = min(_anim_t + delta, anim_time)
            var phase := 1.0 - _anim_t / anim_time
            bars.position.y = _start_y + open_offset * ease(phase, 0.5)
        else:
            bars.position.y = _start_y
