# TNTMap.gd  –  повісити на TileMap, де намальовані TNT‑квадрати
extends TileMap

# ───── налаштування ─────────────────────────────────────────────
@export var GREEN_ID  : int = 14
@export var YELLOW_ID : int = 15
@export var RED_ID    : int = 16
@export var BLACK_ID  : int = 17

@export var LAYER          : int = 0           # шар в TileMap
@export var PLAYER_GROUP   : String = "pl"     # група гравця
@export var RESPAWN_POS    : Vector2 = Vector2.ZERO
@export var RESET_PERIOD   : float = 60.0      # сек

# ───── приватні змінні ──────────────────────────────────────────
var _player      : Node2D = null
var _prev_cell   : Vector2i = Vector2i(-99999, -99999)
var _tnt_ids     : PackedInt32Array = [GREEN_ID, YELLOW_ID, RED_ID, BLACK_ID]

func _ready() -> void:
	_find_player()
	# таймер глобального ресету
	var timer := Timer.new()
	timer.wait_time = RESET_PERIOD
	timer.autostart = true
	timer.one_shot  = false
	add_child(timer)
	#timer.connect("timeout", Callable(self, "_reset_all_tnt"))

func _physics_process(_delta: float) -> void:
	if _player == null or !_player.is_inside_tree():
		_find_player()
		if _player == null:
			return

	var cell := local_to_map(to_local(_player.global_position))
	if cell == _prev_cell:
		return                                    # усе ще стоїть на тій же плитці
	_prev_cell = cell

	_step_on_tnt(cell)

# ────────────────────────────────────────────────────────────────
func _step_on_tnt(cell: Vector2i) -> void:
	var id := get_cell_source_id(LAYER, cell)
	if id not in _tnt_ids:
		return
	var coords := get_cell_atlas_coords(LAYER, cell)
	var alt    := get_cell_alternative_tile(LAYER, cell)
	
	var new_id = GREEN_ID

	match id:
		GREEN_ID:
			new_id = YELLOW_ID
			set_cell(LAYER, cell, YELLOW_ID, coords, alt)
		YELLOW_ID:
			new_id = RED_ID
			set_cell(LAYER, cell, RED_ID, coords, alt)
		RED_ID:
			new_id = BLACK_ID
			set_cell(LAYER, cell, BLACK_ID, coords, alt)
		BLACK_ID:
			# Репортуємо смерть у модель
			JavaScriptBridge.eval("window.msReportDeath('%s');" % _player.get_meta("full_addr"), true)
			# миттєвий локальний відкат (можна прибрати, якщо хочете строго чекати roundReset)
			if _player:
				_player.global_position = RESPAWN_POS
	
	JavaScriptBridge.eval(
	"window.msSendTile('%s', %d, %d, %d);"
	% [_player.get_meta("full_addr"), cell.x, cell.y, new_id], true)

func _is_on_tnt_pos(pos: Vector2) -> bool:
	var cell := local_to_map(to_local(pos))
	var id   := get_cell_source_id(LAYER, cell)
	return id in _tnt_ids
func _reset_all_tnt_silent() -> void:
	for cell in get_used_cells(LAYER):
		var id := get_cell_source_id(LAYER, cell)
		if id in _tnt_ids and id != GREEN_ID:
			var coords := get_cell_atlas_coords(LAYER, cell)
			var alt    := get_cell_alternative_tile(LAYER, cell)
			set_cell(LAYER, cell, GREEN_ID, coords, alt)


# ────────────────────────────────────────────────────────────────
func _reset_all_tnt() -> void:
	for cell in get_used_cells(LAYER):
		var id := get_cell_source_id(LAYER, cell)
		if id in _tnt_ids and id != GREEN_ID:
			var coords := get_cell_atlas_coords(LAYER, cell)
			var alt    := get_cell_alternative_tile(LAYER, cell)
			set_cell(LAYER, cell, GREEN_ID, coords, alt)

# ────────────────────────────────────────────────────────────────
func _find_player() -> void:
	_player = get_tree().get_first_node_in_group(PLAYER_GROUP)
	if _player:
		_player.connect("tree_exited", Callable(self, "_on_player_left"))

func _on_player_left() -> void:
	_player = null


func _apply_remote_tile(cell: Vector2i, id: int) -> void:
	var coords = get_cell_atlas_coords(LAYER, cell)
	var alt    = get_cell_alternative_tile(LAYER, cell)
	if id == GREEN_ID:
		set_cell(LAYER, cell, GREEN_ID, coords, alt)
	else:
		set_cell(LAYER, cell, id, coords, alt)
