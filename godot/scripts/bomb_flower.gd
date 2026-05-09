extends Node3D

# Bomb-flower prop. A growable plant the player can pick a live bomb
# from. Walk into the prompt area, press interact, and a real bomb
# scene is spawned and handed off to the player as a carry-target —
# identical to the rock pickup flow. The plant darkens and disappears
# for ~6 seconds while it regrows.
#
# The picked bomb is just an instance of bomb.tscn — its 2.5 s fuse
# starts on spawn, so if the player hangs onto it too long the bomb
# detonates in their face. Throwing logic lives on the player; this
# script is concerned only with picking and regrowing.

const BombScene := preload("res://scenes/bomb.tscn")

const REGROW_TIME: float = 6.0
const CARRY_OFFSET: Vector3 = Vector3(0, 1.6, -0.1)

@onready var visual: Node3D = $Visual
@onready var prompt_area: Area3D = $PromptArea
@onready var hint: Label3D = $Hint

var _player_inside: bool = false
var _player: Node3D = null
var _picked: bool = false
var _regrow_timer: float = 0.0


func _ready() -> void:
    add_to_group("bomb_flower")
    prompt_area.body_entered.connect(_on_prompt_enter)
    prompt_area.body_exited.connect(_on_prompt_exit)
    if hint:
        hint.visible = false


func _process(delta: float) -> void:
    if _picked:
        _regrow_timer -= delta
        if _regrow_timer <= 0.0:
            _picked = false
            if visual:
                visual.visible = true
            if _player_inside and hint:
                hint.visible = true


func _unhandled_input(event: InputEvent) -> void:
    if _picked or not _player_inside or _player == null:
        return
    if event.is_action_pressed("interact") and not Dialog.is_active():
        get_viewport().set_input_as_handled()
        _pick(_player)


func _on_prompt_enter(body: Node) -> void:
    if not body.is_in_group("player"):
        return
    _player = body
    _player_inside = true
    if hint and not _picked:
        hint.visible = true


func _on_prompt_exit(body: Node) -> void:
    if not body.is_in_group("player"):
        return
    if body == _player:
        _player_inside = false
        if hint:
            hint.visible = false


func _pick(by: Node3D) -> void:
    if _picked:
        return
    _picked = true
    _regrow_timer = REGROW_TIME
    if visual:
        visual.visible = false
    if hint:
        hint.visible = false
    var bomb: RigidBody3D = BombScene.instantiate()
    var scene_root: Node = get_tree().current_scene
    if scene_root == null:
        return
    scene_root.add_child(bomb)
    bomb.global_position = global_position + Vector3(0, 1.0, 0)
    if by.has_method("attach_carried_bomb"):
        by.attach_carried_bomb(bomb)
    else:
        # Fallback: launch the bomb gently upward so it isn't lost in
        # the flower's collider. The fuse will tick down normally.
        bomb.linear_velocity = Vector3(0, 3.0, 0)
