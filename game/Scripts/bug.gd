extends Label


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton \
		and event.button_index == MouseButton.MOUSE_BUTTON_LEFT \
		and event.pressed:
		get_tree().reload_current_scene()
