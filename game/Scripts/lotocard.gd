extends Panel

@export var star_texture: Texture2D
var selected_numbers: Array[int] = []

const SAVE_PATH := "user://lotocard.cfg"
const SAVE_SEC  := "lotocard"          # базова назва секції
const SAVE_KEY  := "selected_numbers"

var current_game_id: int = -1

func _ready() -> void:
	# Підключаємо gui_input, передаючи ctrl як зв’язаний аргумент через bind()
	for i in range(1, 15 + 1):
		var node_name = str(i)
		if has_node(node_name):
			var ctrl = get_node(node_name)
			if ctrl is Label:
				ctrl.connect("gui_input", Callable(self, "_on_gui_input").bind(ctrl))
			else:
				push_warning("Node '%s' не є Control‑вузлом" % node_name)
		else:
			push_warning("Не знайдено ноду з ім’ям '%s'" % node_name)
	# УВАГА: не завантажуємо автоматично — чекаємо виклику _load_selected_numbers(game_id) з батька

func _exit_tree() -> void:
	_save_selected_numbers()

func set_game_id(game_id: int) -> void:
	_load_selected_numbers(game_id)

func _on_gui_input(event: InputEvent, ctrl: Label) -> void:
	if event is InputEventMouseButton \
		and event.button_index == MouseButton.MOUSE_BUTTON_LEFT \
		and event.pressed:
		var txt = ctrl.text
		if txt == "":
			return

		var num = int(ctrl.name)
		if selected_numbers.has(num):
			selected_numbers.erase(num)
			_remove_star(ctrl)
		else:
			selected_numbers.append(num)
			_spawn_star(ctrl)

		_save_selected_numbers()  # зберігаємо одразу після зміни
		event.handled = true

func _spawn_star(ctrl: Control) -> void:
	if ctrl.get_node_or_null("Star"):
		return
	var star = Sprite2D.new()
	star.name = "Star"
	star.texture = star_texture
	star.scale = Vector2(0.05, 0.05)
	star.position = Vector2(30, 20)
	ctrl.add_child(star)

func _remove_star(ctrl: Control) -> void:
	var star = ctrl.get_node_or_null("Star")
	if star:
		star.queue_free()

func _refresh_stars() -> void:
	for i in range(1, 15 + 1):
		var node_name = str(i)
		if not has_node(node_name):
			continue
		var ctrl = get_node(node_name)
		if ctrl is Label:
			if selected_numbers.has(i):
				_spawn_star(ctrl)
			else:
				_remove_star(ctrl)

func get_selected_numbers() -> Array[int]:
	return selected_numbers.duplicate()

# ──────────────── persistence ────────────────

func _section_for_game(id: int) -> String:
	# окрема секція на кожну гру, наприклад: "lotocard_123"
	return "%s_%d" % [SAVE_SEC, id]

func _save_selected_numbers() -> void:
	if current_game_id < 0:
		return
	var cfg := ConfigFile.new()
	# Завантажуємо існуючий файл, щоб не стерти інші ігри
	cfg.load(SAVE_PATH)  # ігноруємо код помилки, якщо файл ще не існує
	cfg.set_value(_section_for_game(current_game_id), SAVE_KEY, selected_numbers)
	var err = cfg.save(SAVE_PATH)
	if err != OK:
		push_warning("Не вдалося зберегти вибір: %s" % err)

func _load_selected_numbers(game_id: int) -> void:
	current_game_id = game_id
	selected_numbers.clear()

	var cfg := ConfigFile.new()
	var err = cfg.load(SAVE_PATH)
	if err == OK:
		var arr: Array = cfg.get_value(_section_for_game(current_game_id), SAVE_KEY, [])
		for v in arr:
			selected_numbers.append(int(v))
	else:
		selected_numbers.clear()

	_refresh_stars()
