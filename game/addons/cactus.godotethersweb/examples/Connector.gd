extends Control

var window = EthersWeb.window

var ui_callback = "{}"   # сюди CanvasLayer підставить свій callback
var wallet_cb = JavaScriptBridge.create_callback(wallet_detected)
var y_shift   : int = 0

var connector_btn = preload("res://addons/cactus.godotethersweb/examples/ConnectorButton.tscn")


func _ready() -> void:
	window.walletBridge.detectWallets(wallet_cb)


static func _norm(name : String) -> String:
	return name.to_lower().replace(" wallet", "").strip_edges()


func wallet_detected(list : Array) -> void:
	for name in list:
		var key := _norm(name)
		if key == "rabby" or key == "metamask":
			_make_button(name, key)


func _make_button(name : String, key : String) -> void:
	var btn = connector_btn.instantiate()
	btn.text = name
	$Backdrop/Buttons.add_child(btn)
	btn.position.y += y_shift
	y_shift += 40
	btn.pressed.connect(_on_wallet_pressed.bind(name, key))


func _on_wallet_pressed(orig_name : String, key : String) -> void:
	# зберігаємо
	var js = "localStorage.setItem('wallet_provider','%s');" % key
	JavaScriptBridge.eval(js)
	EthersWeb.set_meta("provider_name", key)

	window.walletBridge.connectWallet(orig_name)
	EthersWeb.connect_wallet(ui_callback)
	queue_free()
