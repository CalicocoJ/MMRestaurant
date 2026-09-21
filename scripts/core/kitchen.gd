extends RefCounted
class_name Kitchen
## 后厨。对应文档第六节与第十六节第 3 条。
##
## 规则（**已按玩家要求改过一版**）：
##   - 一次做一道，按队列顺序。
##   - 每道 kitchen_cook_time 秒。
##   - **后厨不再被出餐口卡住**：出餐口满了也不会把做好的菜丢掉，
##     而是先"预存"在 _cooked 里；出餐口一空出来，立刻补上去（瞬间出现）。
##     玩家看到的是「我下的单后厨全做完了，只是排队等着上架」。
##   - 出餐口容量 = counter_capacity（config.json，默认 2）。
##
## 【为什么要预存，而不是干脆不做出餐口容量】
## 玩家明确要求：**点了单后厨就得一直做，不要等玩家取走才做下一道**。
## 于是"做好的菜"必须有个去处。两种可能：
##   ① 卡住后厨不做（旧行为）→ 玩家下了 3 份，第 3 份永远要等他拿走才出现；
##   ② 照做，做好的先放着，出餐口有空位就补上（现在的做法）。
## 选 ②。它在视觉上完全自洽：出餐口永远优先放满，
## 玩家取走一份 → 空位出现 → 下一份**当帧**补上，看起来就是"一直在那儿"。
##
## 【_cooked 与 queue 的分工】
##   queue   = 还没开始做的（玩家下的单）
##   _cooked = 已经做好、但出餐口没位置放的
##   出餐口   = 玩家能立刻拿走的
## 两者都不隐藏数据：HUD 的「后厨队列」= queue + _cooked 的合计，
## 玩家随时能看到"还有几份在厨房里"。

signal counter_changed(slot: String)

var queue: Array[String] = []
var timer: float = 0.0

## 出餐口当前放着的餐品（数组，长度 <= _counter_capacity）。
##
## 【为什么改成私有 + 信号】
## 原来是公开字段，任何地方一赋值，**视觉就没人管了**：
## 世界里的出餐口方块靠 queue_redraw() 才更新，而那个节点
## 当时只在「鼠标悬停状态变化」时才重绘 —— 于是餐被拿走以后，
## 方块要等玩家鼠标动一下才消失，看起来像卡了半秒。
## 现在写入统一走 _set_counter()，变化必定发信号，订阅者想漏都难。
var _counter: Array[String] = []

## 已做好、等出餐口空位的（见类注释里的分工）
var _cooked: Array[String] = []

var _cook_time := 3.0
var _counter_capacity := 1


func _init(cook_time: float, counter_capacity: int) -> void:
	_cook_time = maxf(0.01, cook_time)
	_counter_capacity = maxi(1, counter_capacity)


func configure(cook_time: float, counter_capacity: int) -> void:
	_cook_time = maxf(0.01, cook_time)
	_counter_capacity = maxi(1, counter_capacity)


# ── 出餐口 ─────────────────────────────────────────────────────────

## 出餐口里的东西（只读副本，可能有多份）
func counter_slots() -> Array[String]:
	return _counter.duplicate()


## 出餐口第一份（兼容旧接口）。
## 【为什么保留它】HUD、测试与几个工具都用它读「出餐口有什么」；
## 单份时它的语义没变，改动的面就小很多。
func counter_slot() -> String:
	return _counter[0] if not _counter.is_empty() else ""


## 唯一写入口：整表替换 + 变化必定发信号。
## 【信号参数是「拼起来的字符串」而不是数组】信号名与参数类型保持和以前一致
## （String），订阅者只是拿它当"变了"的触发，不需要解析内容 ——
## 这样这次改动不用碰订阅方的签名。
func _set_counter(items: Array[String]) -> void:
	if _same_items(_counter, items):
		return
	_counter = items.duplicate()
	counter_changed.emit(counter_name())


static func _same_items(a: Array[String], b: Array[String]) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


# ── 入队 ───────────────────────────────────────────────────────────

## 后厨 UI 点「完成」时调用。按点击顺序追加。
func enqueue(items: Array) -> void:
	var before := queue.size() + _cooked.size()
	for id in items:
		queue.append(String(id))
	if before == 0 and queue.size() > 0:
		# 从「后厨全空闲」变成「有活」：计时从满开始
		timer = _cook_time


## 还有几份在厨房里没上架（= 没开始做的 + 做好等位置的）。
## 【HUD 用它】玩家要能看出"我下的单后厨还剩几份没给我"，
## 所以计数必须包含 _cooked，否则会看到"队列 0"却还不断有菜冒出来。
func pending_count() -> int:
	return queue.size() + _cooked.size()


## 还没开始做的份数（保留旧语义，测试与工具在用）
func queue_count() -> int:
	return queue.size()


# ── 每帧推进 ───────────────────────────────────────────────────────

func update(delta: float) -> void:
	# 【先把等着上架的补上去】这一步和"做菜"分开：
	# 补位是**瞬间**的（玩家取走一份，空位当帧就被填满），
	# 不该受 cook_time 影响，也不该等到下一帧才生效。
	_refill_counter()

	if queue.is_empty():
		return
	# 【只有「预存区也满了」才停】不能因为"出餐口满了"就停 —— 那正是要改掉的行为。
	# 现在出餐口满了只是「做好的菜先停在 _cooked」；
	# 只有当 _cooked 都堆到 _counter_capacity 这么多时，才真的没地方放、暂停做菜。
	if _storage_full():
		return

	timer -= delta
	if timer <= 0.0:
		# 这一道做好了：先进「预存」；出餐口正好有空位的话，
		# _refill_counter 会立刻把它摆上去（同一个 update 内完成，玩家看不到中间态）。
		_cooked.append(queue.pop_front())
		_refill_counter()
		# 【下一道要从头开始做，所以计时重置为完整的 _cook_time】
		#
		# 这里连续踩过两个坑，两次都是"改测试而不是改逻辑"的后果：
		#   ① 原写法 `_cook_time if not queue.is_empty() else 0.0`
		#      —— 摆出**第一份**时队列非空，于是白白多等一个完整周期；
		#   ② 我改成 `timer = 0.0` 想修 ①，结果**下一帧立刻又出一份**：
		#      因为 update 的第一件事就是判断 `timer <= 0`，0 直接成立。
		#      表现就是玩家看到的「一起下单的菜同时做好、同时出现」。
		# 正确语义：**一道一道做，每道都要完整的 3 秒**。
		timer = _cook_time if not queue.is_empty() else 0.0


## 预存区（已做好但没上架的）是不是也放不下了。
##
## 【为什么用 _counter_capacity 当上限】它表示"出餐口一次能摆几份"。
## 玩家取走一份之后，最多也只会有"出餐口容量"那么多份等着补位，
## 所以预存区用同一个数当上限就够了，且能防住无限堆积
## （否则玩家一直不来取，后厨会把整个队列做完、全堆在内存里）。
func _storage_full() -> bool:
	return _cooked.size() >= _counter_capacity


## 把「做好等位置的」按容量补进出餐口（瞬间完成）
func _refill_counter() -> void:
	if _cooked.is_empty():
		return
	var items := _counter.duplicate()
	var changed := false
	while not _cooked.is_empty() and items.size() < _counter_capacity:
		items.append(_cooked.pop_front())
		changed = true
	if changed:
		_set_counter(items)


func _counter_full() -> bool:
	return _counter.size() >= _counter_capacity


# ── 取餐 ───────────────────────────────────────────────────────────

func counter_is_empty() -> bool:
	return _counter.is_empty()


## 取出餐口**一份**（按顺序取第一个）。返回餐品 id，没得取返回 ""。
##
## 【取走后必须立刻补位】见 _refill_counter 的说明：
## 原来这里不补位，只靠 update() 开头那一次 ——
## 结果「玩家把出餐口清空后，预存区那份永远上不了架」（实测卡死：
## queue 空、pending 1、timer 冻在 3.0，第 2 道菜再也不出现）。
## 补位放在这里，同时也是玩家要的观感：**一取走，下一份瞬间出现**。
func take_from_counter() -> String:
	if _counter.is_empty():
		return ""
	var id: String = _counter[0]
	var items := _counter.duplicate()
	items.remove_at(0)
	_set_counter(items)
	_refill_counter()
	return id


func counter_name() -> String:
	if _counter.is_empty():
		return "空"
	var names := PackedStringArray()
	for id in _counter:
		names.append(Config.item_name(id))
	return " + ".join(names)


# ── 调试 / 测试 ────────────────────────────────────────────────────

## 一次性推完整个后厨（只在测试里用，避免真的等好几秒）
func fast_forward(seconds: float) -> void:
	var guard := 0
	while seconds > 0.0 and guard < 10000:
		guard += 1
		var step := minf(seconds, 0.05)
		update(step)
		seconds -= step


func snapshot() -> Dictionary:
	return {
		"queue": queue.duplicate(),
		"timer": timer,
		"counter_slot": counter_slot(),
	}
