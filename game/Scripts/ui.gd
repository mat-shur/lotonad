extends CanvasLayer
signal wallet_connected(addr : String)   # ← NEW
signal wallet_disconnected 

@onready var connector                = preload("res://scenes/Connector.tscn")
@onready var rabby_wallet_icon        = preload("res://assets/rabby_s.png")
@onready var metamask_wallet_icon     = preload("res://assets/metamask_s.png")
@onready var connect_wallet_icon      = preload("res://assets/wallet_s.png")

@onready var btn_wallet : Button      = $Wallet
var btn_logout : Button               = null

var connected_wallet : String         = ""
var window = EthersWeb.window

var _auto_loop_active : bool          = false
var _auto_timer       : SceneTreeTimer = null
var _detect_seq: int = 0

# ─────────────────────────────────────────────────────────────
func _ready() -> void:
	btn_wallet.text = "Loading..."
	btn_wallet.disabled = true
	btn_wallet.icon = connect_wallet_icon
	
	_auto_timer = get_tree().create_timer(5.0)
	await _auto_timer.timeout
	
	$Info/reload.visible = true
	btn_wallet.text = "Connect wallet"
	btn_wallet.disabled = false
	
	_auto_try_connect()  # автоспроба

# ДОДАЙТЕ НА ПОЧАТКУ (після static func _norm)
func _finish_auto_loop(success : bool) -> void:
	_auto_loop_active = false
	if _auto_timer:
		_auto_timer.stop()
		_auto_timer = null
	btn_wallet.disabled = false

	if !success:
		_reset_button()     # ← якщо не знайшли гаманець — повний скидон
# ─────────────────────────────────────────────────────────────
#  ✦ Службові
# ─────────────────────────────────────────────────────────────
static func _norm(name : String) -> String:
	var n := name.to_lower().replace(" wallet", "").strip_edges()
	return n


func _reset_button() -> void:
	connected_wallet = ""
	btn_wallet.disabled = false
	btn_wallet.text = "Connect wallet"
	btn_wallet.icon = connect_wallet_icon
	if btn_logout: btn_logout.visible = false

	EthersWeb.set_meta("provider_name", "")
	JavaScriptBridge.eval("localStorage.removeItem('wallet_provider');")
	
	emit_signal("wallet_disconnected") # NEW


func _short_addr(addr : String) -> String:
	return "%s...%s" % [addr.substr(0,6), addr.substr(addr.length()-4,4)]


# ─────────────────────────────────────────────────────────────
#  ❶ Автоспостереження ≤ 5 с
# ─────────────────────────────────────────────────────────────
func _auto_try_connect() -> void:
	var stored := String(
		JavaScriptBridge.eval("localStorage.getItem('wallet_provider')||''")
	)
	var provider_key := _norm(stored)
	if provider_key == "":
		return  # нічого не зберігалось

	_auto_loop_active = true
	btn_wallet.disabled = true
	btn_wallet.text = "Loading..."

	_detect_and_connect(provider_key, 3)	# 5 спроб


func _detect_and_connect(provider_key : String, attempts_left : int) -> void:
	if !_auto_loop_active:
		return

	_detect_seq += 1
	var seq := _detect_seq
	var responded := false

	var cb_detect := JavaScriptBridge.create_callback(func (wallets : Array) -> void:
		# ігноруємо пізні колбеки старих спроб
		if seq != _detect_seq or !_auto_loop_active:
			return

		responded = true

		var match_name := ""
		for w in wallets:
			if _norm(w).begins_with(provider_key):
				match_name = w
				break

		if match_name != "":
			_finish_auto_loop(true)   # ✔︎ знайшли
			_connect_and_wait(match_name, provider_key)
		else:
			if attempts_left > 1:
				_auto_timer = get_tree().create_timer(1.0)
				await _auto_timer.timeout
				if !_auto_loop_active:
					return
				_detect_and_connect(provider_key, attempts_left - 1)
			else:
				_finish_auto_loop(false)  # ✖︎ вичерпали
	)

	# ✅ Безпечна перевірка на наявність walletBridge.detectWallets
	var ok := bool(JavaScriptBridge.eval(
		"typeof window !== 'undefined' && window.walletBridge && typeof window.walletBridge.detectWallets === 'function'"
	))

	if ok:
		# може впасти, якщо JS зламається під час виклику -> для цього є watchdog
		window.walletBridge.detectWallets(cb_detect)
	else:
		responded = true
		if attempts_left > 1:
			_auto_timer = get_tree().create_timer(1.0)
			await _auto_timer.timeout
			if !_auto_loop_active:
				return
			_detect_and_connect(provider_key, attempts_left - 1)
		else:
			_finish_auto_loop(false)
		return

	# 🐶 Watchdog: якщо detectWallets не відповів за 1 c — ретраїмо/закінчуємо
	_auto_timer = get_tree().create_timer(1.0)
	await _auto_timer.timeout
	if !_auto_loop_active or seq != _detect_seq:
		return
	if !responded:
		if attempts_left > 1:
			_detect_and_connect(provider_key, attempts_left - 1)
		else:
			_finish_auto_loop(false)




func _stop_auto_loop() -> void:
	_auto_loop_active = false
	if _auto_timer: _auto_timer.stop()
	btn_wallet.disabled = false
	if connected_wallet == "":
		btn_wallet.text = "Connect wallet"
		btn_wallet.icon = connect_wallet_icon


# ─────────────────────────────────────────────────────────────
#  ❷ Конект (виклик + очікування callback)
# ─────────────────────────────────────────────────────────────
func _connect_and_wait(orig_name : String, provider_key : String) -> void:
	EthersWeb.set_meta("provider_name", provider_key)
	window.walletBridge.connectWallet(orig_name)

	var cb = EthersWeb.create_callback(self, "got_account_list")
	EthersWeb.connect_wallet(cb)


# ─────────────────────────────────────────────────────────────
#  ❸ Натиснули на кнопку
# ─────────────────────────────────────────────────────────────
func _on_wallet_pressed() -> void:
	if connected_wallet == "":
		_open_connector()
	else:
		btn_logout.visible = !btn_logout.visible


func _open_connector() -> void:
	var cb = EthersWeb.create_callback(self, "got_account_list")
	var new_connector = connector.instantiate()
	new_connector.ui_callback = cb
	add_child(new_connector)


# ─────────────────────────────────────────────────────────────
#  ❹ Callback після connect / error
# ─────────────────────────────────────────────────────────────
func got_account_list(cb : Dictionary) -> void:
	print("got_account_list called with: ", cb)
	
	if "error_code" in cb:
		push_warning("Wallet error: %s" % cb["error_message"])
		_reset_button()
		return
		

	connected_wallet    = cb["result"][0]
	btn_wallet.disabled = false
	btn_wallet.text     = _short_addr(connected_wallet)

	var provider := String(EthersWeb.get_meta("provider_name",""))
	print("got_account_list called with: ", provider)
	_apply_icon(provider)
	_make_logout_button()
	
	emit_signal("wallet_connected", connected_wallet)   # ← NEW


func _apply_icon(provider_key : String) -> void:
	if provider_key.find("rabby") != -1:
		btn_wallet.icon = rabby_wallet_icon
	elif provider_key.find("meta") != -1:
		btn_wallet.icon = metamask_wallet_icon
	else:
		btn_wallet.icon = connect_wallet_icon


# ─────────────────────────────────────────────────────────────
#  ❺ Logout‑кнопка
# ─────────────────────────────────────────────────────────────
func _make_logout_button() -> void:
	if btn_logout:
		btn_logout.visible = false
		return

	btn_logout       = Button.new()
	btn_logout.text  = "Logout"
	btn_logout.size  = btn_wallet.size 
	btn_logout.position = btn_wallet.position + Vector2(0,75)
	btn_logout.visible = false
	btn_logout.pressed.connect(_on_logout_pressed)

	var p = btn_wallet.get_parent()
	p.add_child(btn_logout)
	p.move_child(btn_logout, p.get_children().find(btn_wallet)+1)


func _on_logout_pressed() -> void:
	_reset_button()
