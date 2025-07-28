extends Area2D

# —————————————————————————————————————————————
# 🔧 Параметри в інспекторі
# —————————————————————————————————————————————
@export var move_vector := Vector2(0, 120)         # вектор зміщення (↓ або ↑ / → або ←)
@export var duration := 2.0                        # час руху в одну сторону (сек)
@export var trans_type := Tween.TRANS_SINE         # тип трансформації
@export var ease_type  := Tween.EASE_IN_OUT        # тип easing
@export var respawn_point_path: NodePath          # точка респавну

# —————————————————————————————————————————————
# внутрішні
# —————————————————————————————————————————————
var _start_pos   := Vector2.ZERO
var _end_pos     := Vector2.ZERO
var _elapsed     := 0.0
var _dir         := 1      #  1 ─ рух від _start_pos до _end_pos;  -1 ─ назад

func _ready() -> void:
	_start_pos = global_position
	_end_pos   = _start_pos + move_vector

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= duration:
		_elapsed -= duration
		_dir *= -1

	# залежно від напрямку задаємо точки інтерполяції
	var initial: Vector2
	var delta_value: Vector2
	if _dir == 1:
		initial     = _start_pos
		delta_value = move_vector               # кінцева – початкова
	else:
		initial     = _end_pos
		delta_value = -move_vector              # йдемо назад

	# інтерполяція з easing
	var offset = Tween.interpolate_value(
		Vector2.ZERO,
		delta_value,
		_elapsed,
		duration,
		trans_type,
		ease_type
	)
	global_position = initial + offset

func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group("local_player"):
		return

	if respawn_point_path != NodePath(""):
		var rp = get_node_or_null(respawn_point_path) as Node2D
		if rp:
			body.global_position = rp.global_position
			return

	body.global_position = Vector2(0, 0)
