extends SceneTree
## 诊断：theme 里的系统字体到底为什么加载不了。
## 用法： godot --headless --path <project> --script res://tools/check_font.gd

const THEME_PATH := "res://assets/ui_font.tres"


func _initialize() -> void:
	print("--- 1) 直接构造 SystemFont ---")
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "SimHei"])
	print("SystemFont ok, names=", sf.font_names)
	print("  get_string_size('汉堡') = ", sf.get_string_size("汉堡", HORIZONTAL_ALIGNMENT_LEFT, -1, 16))

	print("--- 3) load theme 资源 ---")
	var res := ResourceLoader.load(THEME_PATH)
	print("loaded = ", res, "  type=", (res.get_class() if res != null else "<null>"))
	if res is Theme:
		var th: Theme = res
		print("  default_font = ", th.default_font)
		print("  default_font_size = ", th.default_font_size)

	print("--- 4) 项目 theme ---")
	var pt := ThemeDB.get_project_theme()
	print("ThemeDB.get_project_theme() = ", pt)
	if pt != null:
		print("  default_font = ", pt.default_font)

	print("--- 5) fallback font 有没有汉字 ---")
	var fb := ThemeDB.fallback_font
	if fb == null:
		print("no fallback font")
	else:
		print("fallback get_string_size('汉') = ",
			fb.get_string_size("汉", HORIZONTAL_ALIGNMENT_LEFT, -1, 16))
		print("fallback get_string_size('A') = ",
			fb.get_string_size("A", HORIZONTAL_ALIGNMENT_LEFT, -1, 16))

	quit(0)
