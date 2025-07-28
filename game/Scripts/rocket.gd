extends Sprite2D

# посилання на дочірні ноди
@onready var part_node: CPUParticles2D = $CPUParticles2D
@onready var ball_node: Sprite2D         = $Sprite2D
@onready var audio_node: AudioStreamPlayer2D = $AudioStreamPlayer2D

func _ready() -> void:
	# спочатку ховаємо кулю, щоб не було видно до пострілу
	ball_node.visible = false

func fire() -> void:
	# 1) вмикаємо частинки
	part_node.restart()
	audio_node.play()

	# 2) показуємо кулю і ставимо на початкову позицію
	ball_node.position = Vector2(-9.545, -419.992)
	ball_node.visible = true

	# 3) робимо «постріл»: Tween-ом рухаємо кулю вгору
	var target_y = -2500  # кінцева Y‑координата (регулюй під свій екран)
	var flight_time = 0.75  # тривалість польоту в секундах

	var tween = get_tree().create_tween()
	tween.tween_property(
		ball_node, "position",
		Vector2(ball_node.position.x, target_y),
		flight_time
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	
	# опційно: після завершення анімації ховаємо кулю і зупиняємо частинки
	tween.connect("finished", Callable(self, "_on_shot_finished"))

func _on_shot_finished() -> void:
	part_node.emitting = false
	ball_node.visible    = false
