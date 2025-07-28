extends Sprite2D


func _on_area_2d_body_entered(body: Node2D) -> void:
	if body.is_in_group("pl"):
		body.global_position = Vector2(0, 0)
		body.play_win()
