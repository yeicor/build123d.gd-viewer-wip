extends Node3D

@export var clone_scene: PackedScene
@export var count_per_tick: int = 10

@export var x_range: float = 1.0
@export var z_range: float = 0.6
@export var randomness: float = 0.05 # 0 = perfect grid, 1 = fully random within cell

func _on_spawn_timer_timeout() -> void:
	var cols: int = int(ceil(sqrt(float(count_per_tick))))
	var rows: int = int(ceil(float(count_per_tick) / float(cols)))

	var cell_x: float = x_range / float(max(cols, 1))
	var cell_z: float = z_range / float(max(rows, 1))

	for i: int in range(count_per_tick):
		var col: int = i % cols
		var row: int = i / cols

		var x: float = (float(col) / float(max(cols - 1, 1)) - 0.5) * x_range
		var z: float = (float(row) / float(max(rows - 1, 1)) - 0.5) * z_range

		# Add controlled jitter inside each grid cell
		x += (randf() - 0.5) * cell_x * randomness
		z += (randf() - 0.5) * cell_z * randomness

		var scene: Node3D = clone_scene.instantiate()
		scene.position = Vector3(x, 0.0, z)
		add_child(scene)
