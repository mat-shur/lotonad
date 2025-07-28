extends Panel

@onready var input: TextEdit = $Input
@onready var messages: VBoxContainer = $Scroll/Messages
@onready var scroll: ScrollContainer = $Scroll


var _wallet_addr: String = ""
var _can_send: bool = false
var _chat_active := false

func _ready() -> void:
	# Підключаємо обробник клавіш саме до TextEdit
	input.connect("gui_input", Callable(self, "_on_input_gui_input"))
	_apply_input_lock()

func set_wallet(addr: String) -> void:
	_wallet_addr = addr
	_can_send = !_wallet_addr.is_empty()
	_apply_input_lock()
	if _can_send:
		input.grab_focus()

func clear_wallet() -> void:
	set_wallet("")  # вимикає ввід


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			if not _chat_active and _can_send:
				_chat_active = true
				_apply_input_lock()
				accept_event() # щоб гравець не зловив цей Enter

func _apply_input_lock() -> void:
	var active := _chat_active and _can_send
	input.editable = active
	input.focus_mode = active if Control.FOCUS_ALL else Control.FOCUS_NONE
	input.mouse_filter = active if Control.MOUSE_FILTER_STOP else Control.MOUSE_FILTER_IGNORE
	if active:
		input.grab_focus()
	else:
		input.release_focus()

func _on_input_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and not _chat_active and _can_send:
		_chat_active = true
		_apply_input_lock()
		accept_event()
		return
	
	if not _can_send:
		accept_event()
		return
	
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			# Shift+Enter — новий рядок
			if event.shift_pressed:
				return

			accept_event()  # не вставляти \n у TextEdit

			var text := input.text.strip_edges()
			if text.is_empty():
				return

			_send_chat(text)
			input.text = ""
			_close_chat()


func _open_chat() -> void:
	if _can_send:
		_chat_active = true
		_apply_input_lock()

func _close_chat() -> void:
	_chat_active = false
	_apply_input_lock()
	
@export var msg_font: FontFile

# ── додай десь у скрипті ──
func _send_chat(text: String) -> void:
	if text.is_empty():
		return
	var prefix = _wallet_addr.is_empty() if "" else _shorten_address(_wallet_addr) + ": "
	var line = prefix + text  # ← ГОТОВИЙ РЯДОК

	if OS.has_feature("web"):
		var J := JSON.new()
		var js_line := J.stringify(line)
		print(js_line, prefix, _wallet_addr)
		JavaScriptBridge.eval("window.msSendChat(%s);" % js_line, true)
	else:
		add_incoming_line(line)  # fallback для desktop

func add_incoming_line(line: String) -> void:
	var lbl := Label.new()
	lbl.text = line
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_override("font", msg_font)
	lbl.add_theme_font_size_override("font_size", 12)
	messages.add_child(lbl)
	await get_tree().process_frame
	scroll.scroll_vertical = scroll.get_v_scroll_bar().max_value

func add_system_line(line: String) -> void:
	var lbl := Label.new()
	lbl.text = line
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# опційно: той самий шрифт і розмір
	lbl.add_theme_font_override("font", msg_font)
	lbl.add_theme_font_size_override("font_size", 12)
	# стиль: золото + чорна обводка
	lbl.add_theme_color_override("font_color", Color(1.0, 0.84, 0.0)) # #FFD700
	lbl.add_theme_constant_override("outline_size", 2)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0))

	messages.add_child(lbl)
	await get_tree().process_frame
	scroll.scroll_vertical = scroll.get_v_scroll_bar().max_value


func _shorten_address(addr: String) -> String:
	var lead := 6 # "0x" + 4 символи → "0x1236..."
	if addr.length() <= lead:
		return addr
	return addr.substr(0, lead) + "..."
