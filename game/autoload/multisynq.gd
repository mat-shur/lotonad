extends Node
# Autoload – підтягує Multisynq SDK і прокладає міст JS ↔ Godot.

func _ready() -> void:
	print("ready")
	if not OS.has_feature("web"):
		return

	# 1️⃣ Inject JS
	JavaScriptBridge.eval(JS_CODE, false)


const JS_CODE := """
// 1️⃣ Створюємо глобальний міст відразу:
var godotBridge = {
	_cb: null,
	setCallback(cb) { this._cb = cb; },
	join(data) { this._cb && this._cb(data); },
	move(data) { this._cb && this._cb(data); },
	left(data) { this._cb && this._cb(data); },
	test(data) { this._cb && this._cb(data); }  // для локального тесту
};

// 2️⃣ Підвантажуємо SDK і налаштовуємо Model/View:
(async () => {
	if (!window._msLoadPromise) {
		window._msLoadPromise = new Promise((res, rej) => {
			var s = document.createElement("script");
			s.src = "https://cdn.jsdelivr.net/npm/@multisynq/client@latest/bundled/multisynq-client.min.js";
			s.onload = res; s.onerror = rej;
			document.head.appendChild(s);
		});
	}
	await window._msLoadPromise;

	function makeModel() {
		class GameModel extends Multisynq.Model {
			init() {
				this.players = {};
				this.subscribe(this.sessionId, "hello",   this.onHello);
				this.subscribe(this.sessionId, "move",    this.onMove);
				this.subscribe(this.sessionId, "view-exit", this.onViewExit);
			}
			onHello(d) {
				this.players[d.addr] = d.pos;
				this.publish(this.sessionId, "state", this.players);
			}
			onMove(d) {
				this.players[d.addr] = d.pos;
				this.publish(this.sessionId, "moveBroadcast", d);
			}
			onViewExit(vid) {
				this.publish(this.sessionId, "left", { addr: vid });
				delete this.players[vid];
			}
		}
		GameModel.register("GameModel");
		return GameModel;
	}

	function makeView() {
		class GameView extends Multisynq.View {
			constructor(model) {
				super(model);
				this.subscribe(this.sessionId, "state",
					p => godotBridge.join(JSON.stringify(p))
				);
				this.subscribe(this.sessionId, "moveBroadcast",
					d => godotBridge.move(JSON.stringify(d))
				);
				this.subscribe(this.sessionId, "left",
					d => godotBridge.left(JSON.stringify(d.addr))
				);
			}
		}
		return GameView;
	}

	window.joinMultisynq = async (addr) => {
		if (window.msSession) return;
		window.msSession = await Multisynq.Session.join({
			apiKey:   "2Tnvfwm6vHS8a8JeQErWurpdB2CoVLyzK0uCp9DcGo",
			appId:    "com.example.godot",
			name:     "demo-room-1",
			password: "1111",
			model:    makeModel(),
			view:     makeView(),
			tps:      30,
		});
		window.msSession.view.publish(
			window.msSession.id, "hello",
			{ addr: addr, pos: { x:0, y:0 } }
		);
	};

	window.msSendMove = (addr, x, y) => {
		if (!window.msSession) return;
		window.msSession.view.publish(
			window.msSession.id, "move",
			{ addr: addr, pos: { x:x, y:y } }
		);
	};
})();
"""
