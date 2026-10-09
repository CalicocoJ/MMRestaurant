extends SceneTree
## 验证 Sprite2D 的 region_rect 在不同贴图类型下的行为。
##
## 目的：确认「一张大图 + 每个 Sprite2D 各自设 region_rect 切小块」这个方案是否成立。
## 成立的话，就能一张共享大图切所有食物，既不用每种食物建一个资源，
## 也不会出现「改一个 Region 全都变」的共享污染。


func _initialize() -> void:
	var tex: Variant = load("res://assets/50sdiner_set_withshadow.png")
	if tex == null:
		print("✗ 大图加载失败")
		quit(1)
		return
	print("大图类型 = %s   尺寸 = %s" % [tex.get_class(), str((tex as Texture2D).get_size())])

	# --- 情形 A：贴图是普通 Texture2D，Sprite2D 直接切 ---
	var sp_a := Sprite2D.new()
	sp_a.texture = tex
	print("\n[A] 贴图 = %s" % ("AtlasTexture" if sp_a.texture is AtlasTexture else "普通 Texture2D"))
	print("    region_enabled 默认 = %s" % str(sp_a.region_enabled))
	sp_a.region_enabled = true
	sp_a.region_rect = Rect2(240, 416, 16, 15)
	print("    设 region_enabled=true, region_rect=(240,416,16,15)")
	print("    读回 region_rect = %s" % str(sp_a.region_rect))
	print("    → %s" % ("✓ 可以切！" if sp_a.region_rect == Rect2(240, 416, 16, 15) else "✗ 被拒绝"))

	# --- 情形 B：贴图是 AtlasTexture（不设它自己的 region，即整图） ---
	var at := AtlasTexture.new()
	at.atlas = tex
	print("\n[B] AtlasTexture 不设 region 时 get_size() = %s" % str(at.get_size()))
	var sp_b := Sprite2D.new()
	sp_b.texture = at
	sp_b.region_enabled = true
	sp_b.region_rect = Rect2(240, 416, 16, 15)
	print("    设 region_rect=(240,416,16,15)  读回 = %s" % str(sp_b.region_rect))
	print("    → %s" % ("✓ 可以切" if sp_b.region_rect == Rect2(240, 416, 16, 15) else "✗ 被拒绝"))

	# --- 情形 C：AtlasTexture 只圈住底部那一排（Region 小于整图） ---
	var at2 := AtlasTexture.new()
	at2.atlas = tex
	at2.region = Rect2(0, 400, 448, 48)
	print("\n[C] AtlasTexture.region=(0,400,448,48)，get_size()=%s" % str(at2.get_size()))
	var sp_c := Sprite2D.new()
	sp_c.texture = at2
	sp_c.region_enabled = true
	sp_c.region_rect = Rect2(240, 16, 16, 15)   # 相对该 region 的局部坐标
	print("    设 region_rect=(240,16,16,15)  读回 = %s" % str(sp_c.region_rect))

	print("\n=== 结论 ===")
	print("若 [A] 是 ✓，就可以：一张大图（或指向整图的 AtlasTexture）共享给所有食物，")
	print("每个 Sprite2D 各自设 region_enabled + region_rect 来切——互不影响。")

	sp_a.free(); sp_b.free(); sp_c.free()
	quit(0)
