extends CharacterBody2D

# ───────── Публічні параметри ────────────────────────────────────────────────
@export var is_local_player: bool = false          # тільки цей обробляє інпут
@export var speed: float           = 200.0
@export var slap_knockback: float  = 750.0        # сила відштовхування
@export var slap_active_time: float = 0.5       # cкільки сек. хітбокс увімкнено
@export var slap_sound_delay: float = 0.5         # звук після старту анімації

# ───────── Вузли ─────────────────────────────────────────────────────────────
@onready var sprite: AnimatedSprite2D   = $AnimatedSprite2D
@onready var slap_area: Area2D          = $SlapArea
@onready var audio_slap: AudioStreamPlayer2D = $SlapSound    # свій шлях

# ───────── Стан ──────────────────────────────────────────────────────────────
var _last_dir: String = "front"
var _is_slapping: bool = false
var _prev_pos: Vector2
const KNOCKBACK_TIME := 0.2 
const REMOTE_DEADZONE: float = 2.0  # пікселів
var _remote_is_moving: bool = false
# підпис на кінець анімації
func _ready() -> void:
	sprite.animation_finished.connect(_on_anim_finished)
	target_position = global_position

# ───────── Головний цикл ─────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if not is_local_player:
		_update_remote(delta)
		return
		
	# віддалені персонажі рухаються через синхронізацію мережі, інпут ігноруємо
	if not is_local_player:
		move_and_slide()
		return

	if _is_slapping:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	if Input.is_action_just_pressed("attack"):
		_start_slap()
		return

	var dir := Vector2(
		Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
		Input.get_action_strength("ui_down")  - Input.get_action_strength("ui_up")
	)

	if dir != Vector2.ZERO:
		dir = dir.normalized()
		velocity = dir * speed
		_play_move_anim(dir)
	else:
		velocity = Vector2.ZERO
		_play_idle_anim()

	move_and_slide()
var target_position: Vector2 = Vector2.ZERO

const TELEPORT_THRESHOLD: float = 200.0   # наприклад, 200 пкс

func _update_remote(delta: float) -> void:
	var offset = target_position - global_position
	var dist   = offset.length()

	# —– якщо занадто далеко — телепортуємось
	if dist > TELEPORT_THRESHOLD:
		global_position = target_position
		if _remote_is_moving:
			_remote_is_moving = false
			_play_idle_anim()
		return

	# —– інакше: плавний рух як раніше
	if dist > REMOTE_DEADZONE:
		var dir = offset.normalized()
		global_position += dir * speed * delta
		if not _remote_is_moving:
			_remote_is_moving = true
			_play_move_anim(dir)
	else:
		if _remote_is_moving:
			_remote_is_moving = false
			global_position = target_position
			_play_idle_anim()


# ───────── Удар ───────────────────────────────────────────────────────────────
func _start_slap() -> void:
	if not is_local_player:
		return
	_is_slapping = true
	velocity = Vector2.ZERO
	sprite.play("%s_slap" % _last_dir)
	get_tree().create_timer(0.4).timeout.connect(_do_slap_effects)
	
func _do_slap_effects() -> void:
	if not is_local_player:
		return
	
	_activate_slap_hitbox()
	audio_slap.play()

	# вимкнути хітбокс після slap_active_time (0.15 с за замовчуванням)
	get_tree().create_timer(slap_active_time).timeout.connect(
		func(): slap_area.monitoring = false
	)

func _activate_slap_hitbox() -> void:
	# 🧹 Видалити попередній хітбокс (якщо був)
	for child in slap_area.get_children():
		child.queue_free()

	# 🧱 Створити новий
	var shape := RectangleShape2D.new()
	var shape_node := CollisionShape2D.new()
	shape_node.shape = shape
	slap_area.add_child(shape_node)

	var hit_distance := 8.0
	match _last_dir:
		"left":
			slap_area.position = Vector2(-hit_distance, 0)
			shape.size = Vector2(24, 16)
		"right":
			slap_area.position = Vector2(hit_distance, 0)
			shape.size = Vector2(24, 16)
		"back":
			slap_area.position = Vector2(0, -hit_distance)
			shape.size = Vector2(16, 24)
		_:
			slap_area.position = Vector2(0, hit_distance)
			shape.size = Vector2(16, 24)

	slap_area.rotation = 0
	slap_area.monitoring = true




func _on_anim_finished() -> void:
	if not is_local_player:
		return

	if _is_slapping and sprite.animation.ends_with("_slap"):
		_is_slapping = false
		_play_idle_anim()

		# 🔥 ВИДАЛИТИ хітбокс після анімації
		for child in slap_area.get_children():
			child.queue_free()
		slap_area.monitoring = false


# ───────── Обробка влучання ───────────────────────────────────────────────────
func _on_slap_area_body_entered(body: Node2D) -> void:
	if body == self:
		return
	if body is CharacterBody2D:
		var other := body as CharacterBody2D
		var push_dir: Vector2 = (other.global_position - global_position).normalized()
		other.velocity = push_dir * slap_knockback
	
		# ► скинути відштовхування через 0.1 с
		get_tree().create_timer(KNOCKBACK_TIME).timeout.connect(
			func():
				if other and is_instance_valid(other):
					other.velocity = Vector2.ZERO
		)


# ───────── Допоміжні функції ─────────────────────────────────────────────────
func _dir_vector(name: String) -> Vector2:
	match name:
		"left":  return Vector2.LEFT
		"right": return Vector2.RIGHT
		"back":  return Vector2.UP        # back = «вгору» у топ‑дауні
		_:
			return Vector2.DOWN           # front = «вниз»

func _play_move_anim(dir: Vector2) -> void:
	if abs(dir.x) > abs(dir.y):
		if dir.x > 0:
			sprite.play("right_move")
			_last_dir = "right"
		else:
			sprite.play("left_move")
			_last_dir = "left"
	else:
		if dir.y > 0:
			sprite.play("front_move")
			_last_dir = "front"
		else:
			sprite.play("back_move")
			_last_dir = "back"

func _play_idle_anim() -> void:
	sprite.play("%s_idle" % _last_dir)


func play_win() -> void:
	$race_winner.restart()
