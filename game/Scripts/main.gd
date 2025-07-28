extends Node

@export var player_scene        : PackedScene
@export var remote_player_scene : PackedScene
@export var ball_scene          : PackedScene   # ← ваша сцена Ball

const UI_LAYER_PATH := "UI"
const INFO_PANEL    := "UI/Info"
const BALL_BASE_POS   := Vector2(76, 140)
var player_instance : Node = null
var own_addr: String = ""
var remote_players  : Dictionary = {}   # addr → Node
const SPAWN_POS       := Vector2(76, 143)
const BALL_CONTAINER_PATH := "UI/Lotoballs/BallsLayer"
const BALL_SPACING    := 75          # відстань між центрами кульок
const MINTING_DURATION := 240      # 10 хвилин у секундах
const DRAW_INTERVAL    := 3       # інтервал між витягуваннями в секундах
const INITIAL_BALL_POS := Vector2(76, 143)  # точка появи нової кульки
var drawn_sequence    := []          # тут повна послідовність із контракту
var _next_to_spawn: int = 0   # наступний “авторитетний” індекс кульки, який треба показати
const DRAW_DELAY      := 2.0          # пауза між анімаціями, сек
const FLIGHT_TIME     := 1.0          # час польоту кульки, сек
var is_game_claimed: bool = false  # Чи нагорода в грі була заклеймена
var BALL_SHIFT_DURATION: float
var BALL_DROP_DURATION: float
var game_start_time = -1
var _bootstrapped: bool = false
var game_id = -1
var ticket_id = -1
var my_numbers = []
var drawn_numbers = []
var game_pool = 0.0
var players_in_game = 0
const TICK_HZ := 0.25        # як часто звіряємось (сек)
var _tick_timer: Timer
const PUBLIC_CLAIM_GRACE := 180        # 3 хвилини після закінчення DRAWING
var claim_deadline_time: int = -1      # Юнікс-час дедлайну публічного клейму
var _is_animating: bool = false
var _pending: Array[int] = []   # індекси кульок, які треба додати

# Якщо хочеш – зроби пул, щоб не лагало на інстансіації
var _ball_pool: Array[Node2D] = []
const POOL_SIZE := 120

var _prev_drawn_count = 0    

enum GameState { NONE, MINTING, DRAWING, WINNER_CLAIMING, PUBLIC_CLAIMING, FINISHED, READY_TO_START }
var game_state: GameState = GameState.NONE
var loading = false

var last_seen: Dictionary = {}        # addr → msec
# скільки мс без heartbeat вважаємо гравця offline
const STALE_TIMEOUT_MS := 60 * 1000   # 60 секунд

const RESYNC_EVERY_MS := 5000

var _resync_timer: Timer
var _spawning: bool = false
var _pending_spawns: int = 0
var player_tries = 0
var tries_to_win = false
var mint_end_time: int = -1  # Час закінчення мінтингу (Unix timestamp, секунди)
var game_end_time: int = -1  # Час закінчення гри (Unix timestamp, секунди)
@onready var game_status_label: Label = $"UI/GameStatus/Game stage"  # Посилання на Label для відображення статусу гри

var _poll_timer: Timer

func _ready() -> void:
	var win = JavaScriptBridge.get_interface("window")
	var ui := get_node("UI")
	ui.connect("wallet_connected", Callable(self, "_on_wallet_connected"))
	ui.connect("wallet_disconnected", Callable(self, "_on_wallet_disconnected"))

	_wire_js_bridge()
	# Підготувати пул (опціонально, але реально зменшує лаги)
	for i in range(POOL_SIZE):
		var b: Node2D = ball_scene.instantiate() as Node2D
		b.visible = false
		_ball_pool.append(b)

	_tick_timer = Timer.new()
	_tick_timer.wait_time = TICK_HZ
	_tick_timer.one_shot = false
	add_child(_tick_timer)
	_tick_timer.timeout.connect(_ticker)
	_tick_timer.start()
	
	_poll_timer = Timer.new()
	_poll_timer.wait_time = 10.0
	_poll_timer.one_shot = false
	_poll_timer.timeout.connect(_start_state_timer_get_game_10_sec)
	add_child(_poll_timer)
	_poll_timer.start()
	
	BALL_SHIFT_DURATION = min(DRAW_INTERVAL * 0.30, 0.35)  # 30% інтервалу, але не більше 0.35с
	BALL_DROP_DURATION  = min(DRAW_INTERVAL * 0.60, 0.7)   # 60% інтервалу, але не більше 0.7с




func _expected_count() -> int:
	if game_start_time <= 0:
		return 0
	var now: int = int(Time.get_unix_time_from_system())
	var mint_end: int = game_start_time + MINTING_DURATION
	if now <= mint_end:
		return 0
	var c: int = int((now - mint_end) / DRAW_INTERVAL) + 1
	return clamp(c, 0, drawn_numbers.size())

var _is_animinating = false
func _ticker() -> void:
	if drawn_numbers.is_empty():
		return

	var now: int = int(Time.get_unix_time_from_system())
	var mint_end: int = game_start_time + MINTING_DURATION
	if game_start_time <= 0 or now <= mint_end:
		return

	# <<< ОЦЕ ГОЛОВНЕ >>>
	if game_state == GameState.DRAWING and !_bootstrapped:
		_bootstrap_balls_if_needed()
		return

	var expected: int = _expected_count()
	var layer: Node2D = get_node(BALL_CONTAINER_PATH) as Node2D
	var current: int = layer.get_child_count()

	while _next_to_spawn < expected:
		_pending.append(_next_to_spawn)
		_next_to_spawn += 1

	if !_is_animating and current > expected:
		_rebuild_layer_to(expected)
		current = expected

	if !_is_animating and _pending.size() > 0:
		_is_animating = true
		await _spawn_queue()
		_is_animating = false





func _spawn_queue() -> void:
	while _pending.size() > 0:
		var idx: int = _pending.pop_front()
		await _spawn_one(idx)



func _spawn_one(idx: int) -> void:
	$Rocket.fire()

	var layer: Node2D = get_node(BALL_CONTAINER_PATH) as Node2D

	# 1) зсуваємо існуючі
	var shift: Tween = get_tree().create_tween()
	shift.set_parallel(true)
	for child in layer.get_children():
		var n := child as Node2D
		shift.tween_property(
			n, "position:y",
			n.position.y + BALL_SPACING,
			BALL_SHIFT_DURATION
		).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	await shift.finished

	# 2) спавнимо нову
	var b: Node2D = ball_scene.instantiate() as Node2D
	layer.add_child(b)
	b.z_index = 100 + idx
	_apply_ball_style(b, int(drawn_numbers[idx]))
	b.position = Vector2(76, -300)

	# 3) падіння
	var drop: Tween = get_tree().create_tween()
	drop.tween_property(b, "position", BALL_BASE_POS, BALL_DROP_DURATION)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await drop.finished

func _bootstrap_balls_if_needed() -> void:
	if _bootstrapped:
		return
	if game_start_time <= 0:
		return
	# тільки якщо вже DRAWING (мінтинг скінчився)
	var now: int = int(Time.get_unix_time_from_system())
	var mint_end: int = game_start_time + MINTING_DURATION
	if now <= mint_end:
		return

	var expected: int = _expected_count()
	_clear_balls_layer()
	_rebuild_layer_to(expected)

	_next_to_spawn = expected
	_pending.clear()
	_is_animating = false
	_bootstrapped = true

func _get_ball_from_pool() -> Node2D:
	if _ball_pool.size() > 0:
		return _ball_pool.pop_back()
	return ball_scene.instantiate() as Node2D


func _rebuild_layer_to(n: int) -> void:
	_clear_balls_layer()
	var layer: Node2D = get_node(BALL_CONTAINER_PATH) as Node2D
	for i in range(n):
		var index := n - 1 - i
		var num := int(drawn_numbers[index])
		var b := ball_scene.instantiate() as Node2D
		b.global_position = BALL_BASE_POS + Vector2(0, i * BALL_SPACING)
		b.z_index = 100 - i
		_apply_ball_style(b, num)
		layer.add_child(b)


func _authoritative_expected_count() -> int:
	if game_start_time <= 0:
		return 0
	var now: int = int(Time.get_unix_time_from_system())
	var mint_end: int = game_start_time + MINTING_DURATION
	if now <= mint_end:
		return 0
	var count: int = int(floor(float(now - mint_end) / float(DRAW_INTERVAL))) + 1
	return clamp(count, 0, drawn_numbers.size())




func _layer_count_ok(should: int) -> bool:
	var layer: Node2D = get_node(BALL_CONTAINER_PATH) as Node2D
	return layer.get_child_count() == should


#func _resync_tick() -> void:
	#if drawn_numbers.is_empty():
		#return
#
	##var should: int = _authoritative_expected_count()
	#var now: int = int(Time.get_unix_time_from_system())
	#var mint_end: int = game_start_time + MINTING_DURATION
#
	#if now < mint_end:
		#return
#
	#if (!_layer_count_ok(should)) or (should != _prev_drawn_count):
		#_rebuild_layer_to(should)
		#_prev_drawn_count = should
#
	#if should < drawn_numbers.size():
		#var next_time: int = mint_end + should * DRAW_INTERVAL
		#var wait: int = max(0, next_time - now)
		#_schedule_next(float(wait))

var my_callback = JavaScriptBridge.create_callback(_on_js_event)
func _wire_js_bridge() -> void:
	JavaScriptBridge.eval("""
		var godotBridge = {
			_cb: null,
			setCallback(cb) { this._cb = cb; },
			join(data)      { this._cb && this._cb(data); },
			move(data)      { this._cb && this._cb(data); },
			left(data)      { this._cb && this._cb(data); },
			test(data)      { this._cb && this._cb(data); },
			heartbeat(data) { this._cb && this._cb(data); }
		};
		(async () => {
			if (!window._msLoadPromise) {
				window._msLoadPromise = new Promise((res, rej) => {
					const s = document.createElement("script");
					s.src = "https://cdn.jsdelivr.net/npm/@multisynq/client@latest/bundled/multisynq-client.min.js";
					s.onload = res; s.onerror = rej;
					document.head.appendChild(s);
				});
			}
			await window._msLoadPromise;

			function makeModel() {
				const TTL_MS = 60_000; // 1 хв без alive
				const GREEN_ID  = 14;  // зелений
	const YELLOW_ID = 15;  // жовтий
	const RED_ID    = 16;  // червоний
	const BLACK_ID  = 17;  // чорний

				class GameModel extends Multisynq.Model {
					init() {
						// addr -> { pos: {x,y}, lastAlive: ts }
						this.players = new Map();
						this.changedTiles = new Map();   // ← НОВЕ

						this.subscribe(this.sessionId, "hello",     d => this.onHello(d));
						this.subscribe(this.sessionId, "move",      d => this.onMove(d));     // НЕ подовжує TTL
						this.subscribe(this.sessionId, "alive",     a => this.onAlive(a));   // ПОДОВЖУЄ TTL
						this.subscribe(this.sessionId, "view-exit", a => this.onViewExit(a));
						this.subscribe(this.sessionId, "chatSend", d => this.onChat(d));
						this.subscribe(this.sessionId, "sysSend", d => this.onSys(d));
						this.subscribe(this.sessionId, "tileUpdate",
			   d => this.onTileUpdateFromClient(d));
			
			this.subscribe(this.sessionId, "death", d => this.onDeath(d));

						this._pruneTimer = setInterval(() => this.prune(), 2000);
			
					}

					destroy() {
						clearInterval(this._pruneTimer);
					}

					prune() {
						const now = Date.now();
						for (const [addr, info] of this.players.entries()) {
							if (now - info.lastAlive > TTL_MS) {
								this.players.delete(addr);
								this.publish(this.sessionId, "left", { addr });
							}
						}
					}

					onHello(d) {
			this.players.set(d.addr, { pos: d.pos || {x:0,y:0}, lastAlive: Date.now() });
			const plain = {};                      // усі позиції гравців
			for (const [a, info] of this.players) plain[a] = info.pos;
			this.publish(this.sessionId, "state", plain);

			const tiles = Object.fromEntries(this.changedTiles);
			this.publish(this.sessionId, "tileState", tiles);   // ← ОТПРАВКА
		}
		onSys(d) {
  try {
	const text = (typeof d === "string") ? d : String(d?.text ?? "");
	if (!text) return;
	this.publish(this.sessionId, "sysBroadcast", { text });
  } catch (_) {}
}
		onTileUpdateFromClient(d) {
	const key = `${d.x},${d.y}`;
	if (d.id === GREEN_ID)
		this.changedTiles.delete(key);
	else
		this.changedTiles.set(key, d.id);

	// Розсилаємо вже на ІНШИЙ канал
	this.publish(this.sessionId, "tileSync", d);
}
onChat(d) {
  try {
	const text = (typeof d === "string") ? d : String(d?.text ?? "");
	if (!text) return;
	this.publish(this.sessionId, "chatBroadcast", { text }); // розсилка готового тексту
  } catch (_) {}
}

onDeath(d) {
	  // Стартуємо новий раунд
	  this.round += 1;
	  this.changedTiles.clear();                      // все знову зелене
	  this.publish(this.sessionId, "roundReset", {
		round: this.round,
		spawn: { x: 0, y: 0 }
	  });
	  this.publish(this.sessionId, "tileState", {});  // синхрон: пусто = всі зелені
	}

					onMove(d) {
	const now = Date.now();
	if (!this.players.has(d.addr)) {
		this.players.set(d.addr, { pos: d.pos, lastAlive: now });
		// Публікуємо повний стан, щоб усі побачили "нового" гравця
		const plain = {};
		for (const [a, info] of this.players.entries()) plain[a] = info.pos;
		this.publish(this.sessionId, "state", plain);
	} else {
		const rec = this.players.get(d.addr);
		rec.pos = d.pos;
		// За бажанням: оновлюйте lastAlive при русі
		// rec.lastAlive = now;
	}
	this.publish(this.sessionId, "moveBroadcast", d);
}

					onAlive(addr) {
						const rec = this.players.get(addr);
						if (rec) rec.lastAlive = Date.now();
					}

					onViewExit(addr) {
						if (this.players.has(addr)) {
							this.players.delete(addr);
							this.publish(this.sessionId, "left", { addr });
						}
					}
				}

				GameModel.register("GameModel");
				return GameModel;
			}

			function makeView() {
				class GameView extends Multisynq.View {
					constructor(model) {
						super(model);
						this.subscribe(this.sessionId, "state",         p => godotBridge.join(JSON.stringify(p)));
						this.subscribe(this.sessionId, "moveBroadcast", d => godotBridge.move(JSON.stringify(d)));
						this.subscribe(this.sessionId, "left",          d => godotBridge.left(JSON.stringify(d.addr)));
						this.subscribe(this.sessionId, "roundReset", r => godotBridge.test(JSON.stringify({ roundReset: r })));
						this.subscribe(this.sessionId, "sysBroadcast",
  m => godotBridge.test(JSON.stringify({ sysText: m.text })));
						this.subscribe(this.sessionId, "chatBroadcast",
  m => godotBridge.test(JSON.stringify({ chatText: m.text })));
						 this.subscribe(this.sessionId, "tileState",
					   t => godotBridge.test(JSON.stringify({tileState:t})));
		this.subscribe(this.sessionId, "tileSync",    // ← новий канал
					   u => godotBridge.test(JSON.stringify({tileUpdate:u})));
					}
				}
				return GameView;
			}
			window.msSendChat = (text) => {
  try {
	if (window.msSession?.view) {
	  window.msSession.view.publish(window.msSession.id, "chatSend", { text });
	}
  } catch (_) {}
};

			window.joinMultisynq = async (addr) => {
				if (window.msSession) return;

				window.__myAddr = addr;

				window.msSession = await Multisynq.Session.join({
					apiKey:   "2arAw5irErcX88LOeWnEWeqnngVJmMxCoEMteu3MEy",
					appId:    "com.example.godot",
					name:     "demo-room-5555",
					password: "1111",
					model:    makeModel(),
					view:     makeView(),
					tps:      30
				});

				window.msSession.view.publish(window.msSession.id, "hello", {
					addr,
					pos: { x: 0, y: 0 }
				});
			};
			
			window.msSendTile = (addr, x, y, id) => {
	if (window.msSession && window.msSession.view) {
		window.msSession.view.publish(window.msSession.id, "tileUpdate", { addr, x, y, id });
	}
};
window.msSendSys = (text) => {
  try {
	if (window.msSession?.view) {
	  window.msSession.view.publish(window.msSession.id, "sysSend", { text });
	}
  } catch (_) {}
};

			// рух — для позиції, НЕ для TTL
			window.msSendMove = (addr, x, y) => {
				try {
					if (window.msSession && window.msSession.view) {
						window.msSession.view.publish(window.msSession.id, "move", {
							addr,
							pos: { x, y }
						});
					}
				} catch (e) { console.error("msSendMove error", e); }
			};
			
			window.msReportDeath = (addr) => {
  try {
	if (window.msSession?.view) {
	  window.msSession.view.publish(window.msSession.id, "death", { addr });
	}
  } catch (_) {}
};
			
			

			// alive — подовжує TTL
			window.msAlive = (addr) => {
				try {
					if (window.msSession && window.msSession.view) {
						window.msSession.view.publish(window.msSession.id, "alive", addr);
					}
				} catch (e) { console.error("msAlive error", e); }
			};

			window.msLeave = (addr) => {
				try {
					if (window.msSession && window.msSession.view) {
						window.msSession.view.publish(window.msSession.id, "view-exit", addr);
						window.msSession.view.publish(window.msSession.id, "left", { addr });
					}
				} catch (e) {}
			};

			window.addEventListener("beforeunload", () => {
				try {
					const addr = window.__myAddr;
					if (addr) window.msLeave(addr);
				} catch(e) {}
			});
		})();
	""", true)

	var bridge = JavaScriptBridge.get_interface("godotBridge")
	bridge.setCallback(my_callback)



func _despawn_remote(addr: String) -> void:
	if remote_players.has(addr):
		var n: Node = remote_players[addr]
		n.call_deferred("queue_free")   # queue_free інколи краще робити deferred
		remote_players.erase(addr)
	last_seen.erase(addr)

func _on_js_event(args: Array) -> void:
	if args.size() == 0:
		return
	var raw = args[0]
	var js = JSON.new()
	if js.parse(raw) != OK:
		push_error("JS JSON parse error: %s" % js.get_error_message())
		return
	var data = js.get_data()

	# власна адреса
	var me = own_addr

	if typeof(data) == TYPE_STRING:
		if data != own_addr:
			_despawn_remote(data)
		return
	
	if typeof(data) == TYPE_DICTIONARY and data.has("sysText"):
		var line := String(data["sysText"])
		if line != "":
			if "won" in line:
				$UI/Lotocard.rotation_degrees = 90
				_clear_balls_layer()
				get_user_data()
			$UI/Chat.add_system_line(line)
		return
	
	if typeof(data) == TYPE_DICTIONARY and data.has("chatText"):
		var line := String(data["chatText"])
		if line != "":
			$UI/Chat.add_incoming_line(line)
		return
	
	if typeof(data) == TYPE_DICTIONARY and data.has("roundReset"):
		var r     = data["roundReset"]
		var spawn = r.get("spawn", {"x": 0, "y": 0})

		# 1) плитки скидаємо всім (щоб арена почалась заново)
		$Map._reset_all_tnt_silent() 

		# 2) телепорт лише якщо зараз на TNT
		if player_instance and $Map._is_on_tnt_pos(player_instance.global_position):
			player_instance.global_position = Vector2(0, 0)
			JavaScriptBridge.eval("window.msSendMove('%s', %f, %f);" % [own_addr, 0, 0], true)

		# 3) скинути кеш клітинки, щоб не залипнути
		$Map._prev_cell = Vector2i(-99999, -99999)
		return
	
	
	if typeof(data) == TYPE_DICTIONARY and data.has("tileState"):
		var all = data["tileState"]
		for k in all.keys():
			var parts = k.split(",")
			var cell  = Vector2i(int(parts[0]), int(parts[1]))
			var id    = int(all[k])
			$Map._apply_remote_tile(cell, id)
		return

	# TILE UPDATE (одиночна зміна)
	if typeof(data) == TYPE_DICTIONARY and data.has("tileUpdate"):
		var u = data["tileUpdate"]
		var cell = Vector2i(int(u["x"]), int(u["y"]))
		var id   = int(u["id"])
		$Map._apply_remote_tile(cell, id)
		return

	# LEFT як словник { addr: "0x..." }
	if typeof(data) == TYPE_DICTIONARY and data.size() == 1 and data.has("addr"):
		var a = data["addr"]
		if a != own_addr:
			_despawn_remote(a)
		return

	# SLAP-подія
	if typeof(data) == TYPE_DICTIONARY and data.has("slap") and data["slap"] == true:
		var addr = data["addr"]
		if addr != me and remote_players.has(addr):
			remote_players[addr]._start_slap()
		return

	# MOVE-подія { addr, pos }
	if typeof(data) == TYPE_DICTIONARY and data.has("pos") and data.has("addr"):
		var addr = data["addr"]
		if addr != me:
			var p = data["pos"]
			# Якщо гравця немає, створюємо його
			if not remote_players.has(addr):
				_ensure_remote_player(addr, float(p.x), float(p.y))
			else:
				remote_players[addr].target_position = Vector2(p.x, p.y)
			last_seen[addr] = Time.get_ticks_msec()
		return

	# STATE-подія (стартовий дамп)
	if typeof(data) == TYPE_DICTIONARY:
		data.erase(me)
		for addr in data.keys():
			var p = data[addr]
			_ensure_remote_player(addr, float(p.x), float(p.y))
		return

	# HEARTBEAT
	if typeof(data) == TYPE_DICTIONARY and data.has("heartbeat") and data.has("addr"):
		var a = data["addr"]
		if remote_players.has(a):
			last_seen[a] = Time.get_ticks_msec()
		return

# ─────────────────────────────────────────────────────────────
# 2.  Wallet events
# ─────────────────────────────────────────────────────────────
func _on_wallet_connected(addr:String) -> void:
	own_addr = addr
	
	EthersWeb.add_chain("Monad Testnet")
	
	get_node(INFO_PANEL).hide()
	_spawn_local_player(addr)

	if Engine.has_singleton("JavaScriptBridge"):
		JavaScriptBridge.eval("joinMultisynq('%s');" % own_addr, false)
	
	
	loading = true
	$UI/Chat.set_wallet(own_addr)
	_start_state_timer_get_game_10_sec()
	get_user_data()
	


func _on_wallet_disconnected() -> void:
	if player_instance:
		player_instance.queue_free()
		player_instance = null
	for p in remote_players.values():
		p.queue_free()
	remote_players.clear()
	get_tree().reload_current_scene()

# ─────────────────────────────────────────────────────────────
# 3.  Local player
# ─────────────────────────────────────────────────────────────
func _spawn_local_player(addr:String) -> void:
	if player_instance:
		return
	player_instance = player_scene.instantiate()
	player_instance.set_meta("full_addr", addr)
	player_instance.get_node("Nickname").text = _short(addr)
	player_instance.get_node("Camera2D").enabled = true
	player_instance.add_to_group("local_player")
	player_instance.is_local_player = true
	#player_instance.own_addr = own_addr
	add_child(player_instance)
	player_instance.target_position = player_instance.global_position

# ─────────────────────────────────────────────────────────────
# 4.  Send movement each frame
# ─────────────────────────────────────────────────────────────
var _last_sent_pos   : Vector2 = Vector2.ZERO
var _last_send_time  : int = 0          # мс
var target_position: Vector2 = Vector2.ZERO
# ── оновлений _process() ────────────────────────────
const MIN_INTERVAL_MS := 20             # не частіше 20 р/с
const MIN_MOVE_EPS    := 1.0            # мінімальний зсув у пікселях

const ALIVE_INTERVAL_MS := 5000
var _last_alive_sent := 0

func _process(delta: float) -> void:
	if !OS.has_feature("web") or player_instance == null:
		return

	var now := Time.get_ticks_msec()
	# Пінгуємо TTL
	if own_addr != "" and now - _last_alive_sent >= ALIVE_INTERVAL_MS:
		JavaScriptBridge.eval("msAlive('%s');" % own_addr, false)
		_last_alive_sent = now
	
	var pos : Vector2 = player_instance.global_position


	# 1. чи рухалися достатньо далеко?
	if pos.distance_to(_last_sent_pos) < MIN_MOVE_EPS:
		return

	# 2. чи минула мінімальна пауза?
	if now - _last_send_time < MIN_INTERVAL_MS:
		return

	_last_sent_pos  = pos
	_last_send_time = now

	var addr : String = player_instance.get_node("Nickname").text
	JavaScriptBridge.eval(
		"msSendMove('%s', %f, %f);" % [own_addr, pos.x, pos.y],
		false
	)
	
	for a in remote_players.keys():
		if now - last_seen[a] > STALE_TIMEOUT_MS:
			remote_players[a].queue_free()
			remote_players.erase(a)
			last_seen.erase(a)
	
# ─────────────────────────────────────────────────────────────
# 5.  Called FROM JavaScript (godot.call)
#     — додай ці методи до цього ж скрипта
# ─────────────────────────────────────────────────────────────


# ─────────────────────────────────────────────────────────────
# 6.  Helpers
# ─────────────────────────────────────────────────────────────
func _ensure_remote_player(addr:String, x:float, y:float) -> void:
	if !remote_players.has(addr):
		var p := remote_player_scene.instantiate()
		p.get_node("Nickname").text = _short(addr)
		add_child(p)
		remote_players[addr] = p
	# апдейтимо позицію
	remote_players[addr].target_position = Vector2(x, y)
	# фіксуємо час “alive”
	last_seen[addr] = Time.get_ticks_msec()

func _short(addr:String) -> String:
	return "%s...%s" % [addr.substr(0,6), addr.substr(addr.length() - 4, 4)]

func _self_addr() -> String:
	return player_instance if player_instance.get_node("Nickname").text else  ""


func _self_addr_full() -> String:
	return player_instance if player_instance.get_meta("full_addr") else ""


func _on_buy_area_body_entered(body: Node2D) -> void:
	if game_state != GameState.MINTING and game_state != GameState.READY_TO_START:
		return 
	
	if ticket_id != -1:
		return
		
	if body != player_instance:
		return
		
	var data        = EthersWeb.get_calldata(Contract.lotonad, "mintTicket", [ own_addr ])
	var bnm_contract = Contract.lotonad_contract

	# === If mintTicket is payable, include the price in wei ===
	# e.g. 0.01 ETH = 10^16 wei
	var price = "0.1"

	# You can also override gas if estimateGas still fails:
	var gas_limit = 3_000_000
	
	var callback_args = {
		"token_name": "minted",
	}
	var callback = EthersWeb.create_callback(self, "buy_completed", callback_args)
	

	EthersWeb.send_transaction(
		"Monad Testnet",
		bnm_contract,
		data,
		price,        # <–– msg.value
		gas_limit,     # <–– optional gas override
		callback
	)

func buy_completed(data) -> void:
	loading = true
	
	var msg := "%s minted a card" % _short(own_addr)
	if OS.has_feature("web"):
		var J := JSON.new()
		var js_line := J.stringify(msg)
		JavaScriptBridge.eval("window.msSendSys(%s);" % js_line, true)
	else:
		$UI/Chat.add_system_line(msg)
		
	await get_tree().create_timer(5).timeout
	get_user_data()


func get_user_data():
	$UI/Lotocard.rotation_degrees = 90
	
	var network = "Monad Testnet"

	var callback = EthersWeb.create_callback(self, "got_game_id")
	var data = EthersWeb.get_calldata(Contract.lotonad, "currentGameId", [])
	
	EthersWeb.read_from_contract(network, Contract.lotonad_contract, data, callback)
	

func got_game_id(callback):
	if has_error(callback):
		return
	
	game_id = int(callback["result"][0])
	$UI/Lotocard.set_game_id(game_id)
	
	var network = "Monad Testnet"

	var callback1 = EthersWeb.create_callback(self, "got_ticket")
	var data = EthersWeb.get_calldata(Contract.lotonad, "getPlayerTokenInGame", [own_addr, game_id])
	
	EthersWeb.read_from_contract(network, Contract.lotonad_contract, data, callback1)


func got_ticket(callback):
	if has_error(callback):
		return
	
	if callback["result"][0] == "115792089237316195423570985008687907853269984665640564039457584007913129639935":
		ticket_id = -1
		got_ticket_numbers({})
	else:
		ticket_id = int(callback["result"][0])
		
		var network = "Monad Testnet"
		var callback1 = EthersWeb.create_callback(self, "got_ticket_numbers")
		var data = EthersWeb.get_calldata(Contract.lotonad, "getTokenNumbers", [ticket_id])
		
		EthersWeb.read_from_contract(network, Contract.lotonad_contract, data, callback1)
	
	loading = false


func got_ticket_numbers(callback):
	if has_error(callback):
		return
	
	if ticket_id != -1:
		# 1. Забираємо і сортуємо
		my_numbers.clear()
		for number in callback["result"][0]:
			my_numbers.append(int(number))
		my_numbers.sort()  # [1,2,3,…]

		# 2. Згенерити сид із чисел (детерміністичний)
		var seed := 0
		for num in my_numbers:
			seed = (seed * 31 + num) % 2147483647

		# 3. Налаштувати RNG
		var rng := RandomNumberGenerator.new()
		rng.seed = seed  # статичний сид

		# 4. Підготувати список слотів 0…14 (відповідає нодам "1"… "15")
		var slots := []
		for i in range(15):
			slots.append(i)
		# Fisher–Yates shuffle
		for i in range(slots.size() - 1, 0, -1):
			var j = rng.randi_range(0, i)
			var c = slots[i]
			slots[i] = slots[j] 
			slots[j] = c

		# 5. Призначити відсортовані числа першим N слотам
		var assignment := {}
		for idx in range(my_numbers.size()):
			assignment[ slots[idx] ] = my_numbers[idx]

		# 6. Оновити Label‑вузли: якщо є в assignment — показати число, інакше — пусто
		for i in range(15):
			var ctrl = $UI/Lotocard.get_node(str(i + 1))
			if ctrl is Label:
				if assignment.has(i):
					ctrl.text = str( assignment[i] )
					ctrl.visible = true
				else:
					ctrl.text = ""
					ctrl.visible = false
			else:
				push_warning("Node '%s' не є Label‑вузлом" % str(i + 1))
		
		var tween = get_tree().create_tween()
		var offset = tween.tween_property(
			$UI/Lotocard,
			"rotation",
			0,
			2,
		)
	
	var network = "Monad Testnet"

	var callback1 = EthersWeb.create_callback(self, "got_game_start_time")
	var data = EthersWeb.get_calldata(Contract.lotonad, "gameStartTime", [game_id])
	
	EthersWeb.read_from_contract(network, Contract.lotonad_contract, data, callback1)


func got_game_start_time(callback):
	if has_error(callback):
		return
	
	game_start_time = int(callback["result"][0])
	
	# Обчислюємо час закінчення мінтингу та гри
	mint_end_time = game_start_time + MINTING_DURATION  # 10 хвилин
	var max_draws = 99  # Максимальна кількість чисел у грі
	game_end_time = mint_end_time + max_draws * DRAW_INTERVAL  # Час закінчення гри
	claim_deadline_time = game_end_time + PUBLIC_CLAIM_GRACE
	
	# Визначаємо початковий стан гри
	_update_game_status()
	
	# Перевіряємо статус гри (чи заклеймена нагорода)
	var network = "Monad Testnet"
	var callback_status = EthersWeb.create_callback(self, "got_game_status")
	var data = EthersWeb.get_calldata(Contract.lotonad, "getGameStatus", [game_id])
	EthersWeb.read_from_contract(network, Contract.lotonad_contract, data, callback_status)
	
	# Запускаємо перевірку стану через таймер
	_start_state_timer()
	
	var callback_drawn = EthersWeb.create_callback(self, "got_drawn_numbers")
	var data_drawn = EthersWeb.get_calldata(Contract.lotonad, "getDrawnNumbers", [game_id, 99])
	EthersWeb.read_from_contract(network, Contract.lotonad_contract, data_drawn, callback_drawn)


func got_game_status(callback):
	if has_error(callback):
		return
	
	# Результат: [isFinished, winnerTokenId]
	var is_finished = callback["result"][0]
	var winner_token_id = int(callback["result"][1])
	
	is_game_claimed = is_finished
	
	# Оновлюємо статус гри
	_update_game_status()

func _start_state_timer() -> void:
	
	# Перевіряємо стан кожну секунду
	var timer = get_tree().create_timer(1.0)
	timer.connect("timeout", Callable(self, "_check_game_state"))


# REPLACE
func _check_game_state() -> void:
	var now := int(Time.get_unix_time_from_system())
	
	if not is_game_claimed and game_start_time == 0:
		game_state = GameState.READY_TO_START
		_update_game_status()
	elif now < mint_end_time:
		if game_state != GameState.MINTING:
			game_state = GameState.MINTING
			_update_game_status()
	else:
		# Мінтинг закінчився
		if now < game_end_time:
			# Іде витягування
			if game_state != GameState.DRAWING:
				game_state = GameState.DRAWING
				_update_game_status()
				# скидання/бутстрап візуалу під DRAWING
				_bootstrapped = false
				_next_to_spawn = 0
				_pending.clear()
				_is_animating = false
				_bootstrap_balls_if_needed()
		else:
			# Витягування завершено
			if is_game_claimed:
				game_state = GameState.FINISHED
				_update_game_status()
			else:
				# 3 хв тільки для власника тікета
				if now < claim_deadline_time:
					if game_state != GameState.WINNER_CLAIMING:
						game_state = GameState.WINNER_CLAIMING
						_update_game_status()
				else:
					# Після дедлайну — публічний клейм (будь‑хто)
					if game_state != GameState.PUBLIC_CLAIMING:
						game_state = GameState.PUBLIC_CLAIMING
						_update_game_status()
	_update_game_status()
	_start_state_timer()



func _start_state_timer_get_game_10_sec() -> void:
	var network = "Monad Testnet"
	var cb = EthersWeb.create_callback(self, "_got_snapshot")
	# ABI: getGameSnapshot(address)
	var data = EthersWeb.get_calldata(Contract.lotonad, "getGameSnapshot", [own_addr])
	EthersWeb.read_from_contract(network, Contract.lotonad_contract, data, cb)


func _got_snapshot(cb) -> void:
	if has_error(cb):
		return

	var r = cb["result"]
	
	print(r)

	# 1) Парсимо
	
	game_id = int(r[0])
	$UI/Lotocard.set_game_id(game_id)
	game_start_time = int(r[1])

	mint_end_time = game_start_time + MINTING_DURATION  # 10 хвилин

	var max_draws = 99  # Максимальна кількість чисел у грі

	game_end_time = mint_end_time + max_draws * DRAW_INTERVAL  # Час закінчення гри
	claim_deadline_time = game_end_time + PUBLIC_CLAIM_GRACE

	is_game_claimed = bool(r[6])

	game_pool = int(r[9])

	players_in_game = int(r[10])

	player_tries = int(r[11])

	_update_game_status()


func _update_game_status() -> void:
	var now = int(Time.get_unix_time_from_system())
	var text = ""
	
	$Bank/Tries.text = str(player_tries) + "/3 tries"
	$Bank/Pool.text = "%0.4f MON" % (float(game_pool) / 1e18)
	$UI/GameStatus/Players.text = "Players minted: " + str(players_in_game)
	
	match game_state:
		GameState.READY_TO_START:
			$"UI/GameStatus/Game stage".text = "Game stage: Minting Phase"
			$"UI/GameStatus/Time left".text = ""
			$UI/GameStatus/Info.text = "Info: Buy your ticket!"
		GameState.MINTING:
			# Триває період мінтингу
			var time_left = mint_end_time - now
			var minutes = time_left / 60
			var seconds = time_left % 60
			$"UI/GameStatus/Game stage".text = "Game stage: Minting Phase"
			$"UI/GameStatus/Time left".text = "Time left: %02d:%02d" % [minutes, seconds]
			$UI/GameStatus/Info.text = "Info: Buy your ticket!"
		GameState.DRAWING:
			# Триває період витягування чисел
			var draws_done = (get_node(BALL_CONTAINER_PATH) as Node2D).get_child_count()
			var draws_total = 99
			var time_left = game_end_time - now
			var minutes = time_left / 60
			var seconds = time_left % 60
			$"UI/GameStatus/Game stage".text = "Game stage: Drawing Phase"
			$"UI/GameStatus/Time left".text = "Time left: %02d:%02d" % [minutes, seconds]
			$UI/GameStatus/Info.text = "Draws: %d/%d" % [draws_done, draws_total]
		GameState.WINNER_CLAIMING:
			var time_left = max(0, claim_deadline_time - now)
			var minutes = time_left / 60
			var seconds = time_left % 60
			$"UI/GameStatus/Game stage".text = "Game stage: Winner Claiming"
			$"UI/GameStatus/Time left".text = "Owner-only claim: %02d:%02d" % [minutes, seconds]
			$UI/GameStatus/Info.text = "Only the ticket owner can claim now."
		GameState.PUBLIC_CLAIMING:
			$"UI/GameStatus/Game stage".text = "Game stage: Public Claiming"
			$"UI/GameStatus/Time left".text = ""
			$UI/GameStatus/Info.text = "Someone forget to claim prize, so anyone can claim the prize!"
		GameState.FINISHED:
			if not is_game_claimed and game_start_time == 0:
				$"UI/GameStatus/Game stage".text = "Game stage: Game Finished!\n"
				$"UI/GameStatus/Time left".text = ""
				$UI/GameStatus/Info.text = "You can purchase a new ticket."
			else:
				$"UI/GameStatus/Game stage".text = "Game stage: Game Finished!\n"
				$"UI/GameStatus/Time left".text = ""
				$UI/GameStatus/Info.text = "Wait till someone claim win."
		_:
			$UI/GameStatus/Info.text = "Waiting for game data..."

	
	


func got_drawn_numbers(callback):
	if has_error(callback):
		return

	# 1) Збираємо й сортуємо номери
	if ticket_id != -1:
		drawn_numbers.clear()
		for number in callback["result"][0]:
			drawn_numbers.append(int(number))
		
		#_clear_balls_layer()
		_bootstrap_balls_if_needed()


func _start_draw_sequence() -> void:
	# поточний UNIX‑час у секундах
	var now = int(Time.get_unix_time_from_system())

	# обраховуємо, коли закінчується період мінтингу
	var mint_end = game_start_time + MINTING_DURATION

	# 1) Якщо ще триває мінтинг — запускаємо таймер на кінець мінтингу
	if now < mint_end:
		#_schedule_next(mint_end - now)
		return
	# 2) Інакше — скільки «законних» витягів уже мало статися?
	var count = int(floor((now - mint_end) / DRAW_INTERVAL)) + 1
	count = clamp(count, 0, drawn_numbers.size())

	# 3) Миттєво спавнимо всі «вже витягнуті»
	_place_initial_balls(count)
	_prev_drawn_count = count

	# 4) І, якщо залишилися ще числа — запускаємо таймер на наступний витяг
	if _prev_drawn_count < drawn_numbers.size():
		var next_time = mint_end + _prev_drawn_count * DRAW_INTERVAL
		#_schedule_next(next_time - now)


func _place_initial_balls(count: int) -> void:
	var layer = get_node(BALL_CONTAINER_PATH) as Node2D
	for i in range(count):
		var index = count - 1 - i  # ← розгортаємо порядок
		var num = drawn_numbers[index]
		var b = ball_scene.instantiate() as Node2D
		b.global_position = BALL_BASE_POS + Vector2(0, i * BALL_SPACING)
		b.z_index = 100 - i
		_apply_ball_style(b, num)
		layer.add_child(b)


func _apply_ball_style(b: Node2D, num: int) -> void:
	# колір за seed=number
	var rng = RandomNumberGenerator.new()
	rng.seed = num
	b.self_modulate = Color(rng.randf(), rng.randf(), rng.randf())
	# текст
	var lbl = b.get_node("Label")
	if lbl:
		lbl.text = str(num)


func _schedule_next(wait_sec: float) -> void:
	# якщо negative — миттєво
	wait_sec = max(wait_sec, 0)
	#get_tree().create_timer(wait_sec).connect("timeout", Callable(self, "_on_draw_timer"))


#func _on_draw_timer() -> void:
	##var expected: int = _authoritative_expected_count()
	#var to_spawn: int = expected - _prev_drawn_count
	#if to_spawn <= 0:
		#return
#
	#_pending_spawns += to_spawn
	#if not _spawning:
		#_spawning = true
		##await _spawn_pending()
		#_spawning = false



func _spawn_pending() -> void:
	while _pending_spawns > 0 and _prev_drawn_count < drawn_numbers.size():
		# 1) постріл
		$Rocket.fire()

		# 2) чекаємо 2 сек перед кулькою (як і було)
		await get_tree().create_timer(2.0).timeout

		# 3) спавнимо одну кульку акуратно
		#await _spawn_ball_animated(_prev_drawn_count)

		_prev_drawn_count += 1
		_pending_spawns -= 1

		# Якщо за цей час пройшов ще один інтервал, _resync_tick додасть у _pending_spawns ще задач





func _clear_balls_layer() -> void:
	var layer = get_node(BALL_CONTAINER_PATH) as Node2D
	for child in layer.get_children():
		child.queue_free()
	_prev_drawn_count = 0


func _spawn_ball_animated(idx: int) -> void:
	var layer = get_node(BALL_CONTAINER_PATH) as Node2D

	# 1) зсуваємо існуючі вниз ПАРАЛЕЛЬНО, але чекаємо завершення саме твіна
	var shift_tween = get_tree().create_tween()
	shift_tween.set_parallel(true)
	for child in layer.get_children():
		var from_y = child.position.y
		var to_y   = from_y + BALL_SPACING
		shift_tween.tween_property(child, "position:y", to_y, BALL_SHIFT_DURATION)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	await shift_tween.finished  # <── замість таймера!

	# 2) нова куля
	var b = ball_scene.instantiate() as Node2D
	layer.add_child(b)
	b.z_index = 100 + idx
	_apply_ball_style(b, int(drawn_numbers[idx]))
	b.position = Vector2(76, -300)

	# 3) падіння
	var drop_tween = get_tree().create_tween()
	drop_tween.tween_property(b, "position", BALL_BASE_POS, BALL_DROP_DURATION)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await drop_tween.finished




func has_error(callback):
	if "error_code" in callback.keys():
		var txt = "Error " + str(callback["error_code"]) + ": " + callback["error_message"]
		print(txt)
		return true


func _on_claim_entered(body: Node2D) -> void:
	if body != player_instance:
		return
	
	# У публічному клеймі — ігноруємо спроби та відсутність тікета
	var is_public := (game_state == GameState.PUBLIC_CLAIMING)
	if not is_public:
		# Не публічний режим: обмеження спроб і наявність тікета обов'язкові
		if player_tries >= 3:
			return
		if ticket_id == -1:
			return
	
	# Обираємо, що слати в контракт: 0 — для публічного клейму
	var token_to_claim = 0 if is_public else ticket_id
	print("dasdsad", token_to_claim)
	
	var data        = EthersWeb.get_calldata(Contract.lotonad, "claimWin", [ token_to_claim ])
	var bnm_contract = Contract.lotonad_contract
	var gas_limit = 3_000_000
	
	var callback_args = { "token_name": "minted" }
	var callback = EthersWeb.create_callback(self, "claim_completed", callback_args)
	
	EthersWeb.send_transaction(
		"Monad Testnet",
		bnm_contract,
		data,
		0,
		gas_limit,
		callback
	)

func claim_completed(data) -> void:
	loading = true
	
	var msg := "%s tries to claim win" % _short(own_addr)
	if OS.has_feature("web"):
		var J := JSON.new()
		var js_line := J.stringify(msg)
		JavaScriptBridge.eval("window.msSendSys(%s);" % js_line, true)
	else:
		$UI/Chat.add_system_line(msg)
	
	await get_tree().create_timer(8).timeout
	
	var network = "Monad Testnet"
		
	var callback = EthersWeb.create_callback(self, "check_win")
	var dat2a = EthersWeb.get_calldata(Contract.lotonad, "currentGameId", [])
	
	EthersWeb.read_from_contract(network, Contract.lotonad_contract, dat2a, callback)



func check_win(callback):
	if has_error(callback):
		return
	
	if game_id != int(callback["result"][0]):
		var msg := "%s won" % _short(own_addr)
		if OS.has_feature("web"):
			var J := JSON.new()
			var js_line := J.stringify(msg)
			JavaScriptBridge.eval("window.msSendSys(%s);" % js_line, true)
		else:
			$UI/Chat.add_system_line(msg)
		
		var network = "Monad Testnet"
		var callback_status = EthersWeb.create_callback(self, "got_game_status")
		var data1 = EthersWeb.get_calldata(Contract.lotonad, "getGameStatus", [game_id])
		EthersWeb.read_from_contract(network, Contract.lotonad_contract, data1, callback_status)
		
		await get_tree().create_timer(5).timeout
		get_user_data()
	else:
		var msg := "%s lose attempt" % _short(own_addr)
		if OS.has_feature("web"):
			var J := JSON.new()
			var js_line := J.stringify(msg)
			JavaScriptBridge.eval("window.msSendSys(%s);" % js_line, true)
		else:
			$UI/Chat.add_system_line(msg)
	
	
