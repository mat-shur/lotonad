extends Line2D

@export var speed: float = 5     # швидкість руху градієнта
@export var alpha: float = 0.8      # прозорість

var gradient_data: Gradient
var offset: float = 0.0

func _ready():
	gradient_data = Gradient.new()

	# Задати кольори фіолет → помаранч → фіолет
	gradient_data.colors = PackedColorArray([
		Color(0.8, 0.6, 1.0, alpha),   # фіолетовий
		Color(1.0, 0.75, 0.5, alpha),  # помаранчевий
		Color(0.8, 0.6, 1.0, alpha)    # знову фіолетовий
	])

	gradient_data.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	self.gradient = gradient_data   # встановлюємо в Line2D

func _process(delta: float) -> void:
	offset += delta * speed
	while offset >= 1.0:
		offset -= 1.0

	var new_offsets: Array[float] = []
	var new_colors: Array[Color] = []

	for i in gradient_data.offsets.size():
		var raw_offset: float = gradient_data.offsets[i] + offset
		var shifted: float = fmod(raw_offset, 1.0)
		new_offsets.append(shifted)
		new_colors.append(gradient_data.colors[i])

	# Сортуємо за зміщеними offset-ами
	var sorted := []
	for i in new_offsets.size():
		sorted.append({ "o": new_offsets[i], "c": new_colors[i] })
	sorted.sort_custom(func(a, b): return a["o"] < b["o"])

	# Оновлюємо градієнт
	var final_offsets := PackedFloat32Array()
	var final_colors := PackedColorArray()
	for item in sorted:
		final_offsets.append(item["o"])
		final_colors.append(item["c"])

	gradient_data.offsets = final_offsets
	gradient_data.colors = final_colors
	self.gradient = gradient_data
