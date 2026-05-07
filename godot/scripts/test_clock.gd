extends SceneTree

# Standalone verifier for tux_anim.clock_dir(). For each (hour, depth)
# pair, applies the resulting Euler to a fresh Basis, multiplies the
# wing rest direction (-Y in arm-local) through it, then maps through
# the rig's 180° Y flip, and compares to the expected body-space
# direction.
#
# Run from repo root:
#   ./Godot_v4.5.1-stable_linux.x86_64 --path godot --headless -s res://scripts/test_clock.gd

const TuxAnim = preload("res://scripts/tux_anim.gd")

const EPS: float = 0.005


func _init() -> void:
    print("=== clock_dir verification ===")
    print("Convention: 12=up, 3=Tux's right, 6=down, 9=Tux's left.")
    print("Depth: -1 = behind, 0 = frontal plane, +1 = forward.\n")

    var cases: Array = [
        # [hour, depth, expected body wing-direction, label]
        [12.0,  0.0, Vector3(0,  1, 0),                "12 o'clock = up"],
        [ 3.0,  0.0, Vector3(1,  0, 0),                "3 o'clock = Tux's right"],
        [ 6.0,  0.0, Vector3(0, -1, 0),                "6 o'clock = down"],
        [ 9.0,  0.0, Vector3(-1, 0, 0),                "9 o'clock = Tux's left"],
        [12.0,  1.0, Vector3(0,  0, -1),               "12 + depth=+1 = forward"],
        [12.0, -1.0, Vector3(0,  0,  1),               "12 + depth=-1 = backward"],
        [ 7.0,  0.0, Vector3(-0.5, -0.86603, 0),       "7 o'clock = down-left"],
        [ 1.0,  0.0, Vector3( 0.5,  0.86603, 0),       "1 o'clock = up-right"],
        # 4.5 hours × 30° = 135°. sin(135°)=0.707, cos(135°)=-0.707.
        [ 4.5,  0.0, Vector3( 0.70711, -0.70711, 0),   "4:30 = lower-right"],
        [10.5,  0.0, Vector3(-0.70711,  0.70711, 0),   "10:30 = upper-left"],
        [ 9.0,  0.5, Vector3(-0.86603, 0, -0.5),       "9 + half-forward"],
        [ 6.0,  0.5, Vector3(0, -0.86603, -0.5),       "6 + half-forward"],
    ]

    var n_pass: int = 0
    var n_fail: int = 0
    var failed_lines: Array = []

    for tc in cases:
        var hour: float = tc[0]
        var depth: float = tc[1]
        var expected: Vector3 = tc[2]
        var label: String = tc[3]

        # 1) Ask the helper for the Euler.
        var euler: Vector3 = TuxAnim.clock_dir(hour, depth)
        # 2) Convert to a Basis the same way Node3D would.
        var b: Basis = Basis.from_euler(euler)
        # 3) Rotate the wing's rest direction through it.
        var wing_arm_parent: Vector3 = b * Vector3(0, -1, 0)
        # 4) Apply the rig's 180° Y flip.
        var wing_body: Vector3 = Vector3(-wing_arm_parent.x, wing_arm_parent.y, -wing_arm_parent.z)

        var diff: float = wing_body.distance_to(expected)
        var ok: bool = diff < EPS
        var status: String = "PASS" if ok else "FAIL"
        if ok:
            n_pass += 1
        else:
            n_fail += 1
            failed_lines.append("  %s expected %s got %s (diff %.4f)" % [label, _v(expected), _v(wing_body), diff])

        print("[%s] %s" % [status, label])
        print("       euler = %s" % _v(euler))
        print("       wing  = %s   (expected %s)" % [_v(wing_body), _v(expected)])

    print("")
    print("%d passed, %d failed" % [n_pass, n_fail])
    if n_fail > 0:
        print("\n--- Failures ---")
        for l in failed_lines:
            print(l)
    quit()


static func _v(v: Vector3) -> String:
    return "(%+.3f, %+.3f, %+.3f)" % [v.x, v.y, v.z]
