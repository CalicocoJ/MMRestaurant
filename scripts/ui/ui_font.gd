extends RefCounted
class_name UiFont
## 全局字体。
##
## 【为什么不能直接用 ThemeDB 里那个 fallback 字体】
## Godot 默认字体**不含汉字**，中文会渲染成方块 □□□。
## 所以必须显式指向一个系统 CJK 字体。
##
## 【为什么不用 ThemeDB.get_project_theme()】
## 实测在 `--script` / 无窗口模式下它返回 null，
## 于是所有调用点都会静默退回默认字体 —— 表现为「编辑器里中文好好的，
## 跑起来全是方块」。静默降级是最难查的一类 bug，所以这里不依赖它：
## 直接自己构造 SystemFont。
##
## 【为什么用 global class 的静态变量做缓存】
## 把缓存放在 Constants 上、而不是 UiFont 自己身上，是踩过坑的结果：
## 每个 `class_name` 脚本都会注册成一个独立的 GDScript 对象，
## 静态变量挂在**那个对象实例**上。不同调用点经过不同的解析路径时，
## 可能拿到两个不同的脚本实例，于是「只建一次」失效，
## 甚至报出莫名其妙的 `Nonexistent function 'get_font' in base 'GDScript'`。
## 挂在一个确定是单例的类上，行为就唯一了。


## 拿到能显示中文的字体。第一次调用时构造，之后复用。
static func get_font() -> Font:
	# 优先用工程主题里配的字体（assets/ui_font.tres），保持一致
	var cached: Variant = Constants.font_cache_get()
	if cached != null:
		return cached

	var f: Font = null
	var theme_res: Variant = load("res://assets/ui_font.tres")
	if theme_res is Theme:
		var t: Theme = theme_res
		if t.default_font != null:
			f = t.default_font

	if f == null:
		# 兜底：自己按名字找系统中文字体
		var sf := SystemFont.new()
		sf.font_names = PackedStringArray([
			"Microsoft YaHei UI",
			"Microsoft YaHei",
			"SimHei",
			"SimSun",
			"Noto Sans CJK SC",
			"Source Han Sans SC",
			"sans-serif",
		])
		f = sf

	Constants.font_cache_set(f)
	return f
