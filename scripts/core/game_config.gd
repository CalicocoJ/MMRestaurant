extends Node
## 配置与数据（autoload 名 = Config）。
##
## 【职责】
## 读 data/config.json（数值）、data/menu.json（菜单）、data/layout.json（布局），
## 并对上层提供只读查询。它不持有任何游戏进度。
##
## 【为什么把布局也放进 JSON】
## 文档第一节给了每个物件的精确坐标。把它写死在脚本里，
## 想挪一下垃圾桶都得改代码；放进 JSON，改一行就生效。

const CONFIG_PATH := "res://data/config.json"
const MENU_PATH := "res://data/menu.json"
const LAYOUT_PATH := "res://data/layout.json"
const LEVELS_PATH := "res://data/levels.json"

## 关卡表的兜底：levels.json 缺失/损坏时用它，保证游戏仍然能跑。
## 【为什么必须兜底】关卡是「一局的骨架」—— 没有它就不知道一局多长、
## 要赚多少，游戏会卡在一个没有终点的状态。宁可给一个能跑的第 1 关。
const DEFAULT_LEVELS: Array = [
	{"id": 1, "name": "试营业", "time_limit": 90.0, "target_money": 100},
]

## 兜底：JSON 缺字段时用这些，保证游戏无论如何都能跑。
const DEFAULT_CONFIG := {
	"table_count": 3,
	"patience_waiting_to_order": 28.0,
	"patience_waiting_for_food": 45.0,
	"patience_eating": 12.0,
	"kitchen_cook_time": 3.0,
	"counter_capacity": 1,
	"customer_spawn_check_interval": 1.0,
	"empty_table_delay": 2.0,
	"waiter_speed": 290.0,
	"clean_time": 3.0,
	"max_items_per_customer": 2,
	"hand_capacity": 2,
	"item_count_weights": {"1": 0.5, "2": 0.5},
	"group_size_weights": {"1": 0.7, "2": 0.3},
	"customer_speed": 220.0,
	"stuck_timeout": 2.0,
	# 每桌至少几份主食（0 = 关闭）。哪些算主食看 menu.json 的 main 标记。
	"min_main_per_group": 1,
	"group_order_reroll_max": 20,
	"group_entry_stagger": 36.0,
}

## JSON 里没写 main 标记时，后厨菜算不算主食。
## 默认 true：这样**旧菜单文件**（还没有 main 字段）也能满足「不能只点饮料」，
## 而不是因为漏了一个字段就让整条规则失效。要排除某道菜，在 menu.json 里写 main: false。
const MAIN_BY_DEFAULT := true

var config: Dictionary = {}
var layout: Dictionary = {}

## 有序的餐品定义列表（保持 JSON 顺序，UI 按这个顺序生成按钮）
var kitchen_items: Array[Dictionary] = []
var drink_items: Array[Dictionary] = []

var _by_id: Dictionary = {}
## 加载时发现的问题，测试会读它
var load_errors: PackedStringArray = PackedStringArray()

## 关卡表（按 id 升序）。每关：{id, name, time_limit, target_money}
var levels: Array[Dictionary] = []


func _ready() -> void:
	_rng.randomize()
	config = _deep_merge(DEFAULT_CONFIG.duplicate(true), _read_json(CONFIG_PATH))
	layout = _read_json(LAYOUT_PATH)
	_load_menu()
	_load_levels()
	if load_errors.is_empty():
		print("[Config] 载入完成：后厨 %d 道、饮品 %d 种、桌子 %d 张、关卡 %d 关" % [
			kitchen_items.size(), drink_items.size(), table_count(), levels.size()
		])
	else:
		push_warning("[Config] 载入发现问题：\n" + "\n".join(load_errors))


# ── 关卡表 ─────────────────────────────────────────────────────────

## 读 data/levels.json。
##
## 【为什么每一条都要校验】关卡数据决定了「一局多长、要赚多少」，
## 一个缺字段或算出 0 的值会让那一关变成「瞬间结束」或「永远过不了」——
## 都是不报错的玩法故障。所以缺字段 / 非法值一律记进 load_errors，
## 并且**丢弃那一条**（而不是留下一个坏关卡）。
func _load_levels() -> void:
	var raw := _read_json(LEVELS_PATH)
	var arr: Variant = raw.get("levels", [])
	if typeof(arr) != TYPE_ARRAY:
		load_errors.append("levels.json 的 levels 不是数组，已退回默认关卡")
		levels = _default_levels()
		return
	var out: Array[Dictionary] = []
	for entry in arr:
		if typeof(entry) != TYPE_DICTIONARY:
			load_errors.append("levels.json 里有不是字典的条目")
			continue
		var id := int(entry.get("id", 0))
		var t := float(entry.get("time_limit", 0.0))
		var target := int(entry.get("target_money", 0))
		if id <= 0:
			load_errors.append("levels.json 有条目缺少合法的 id：%s" % str(entry))
			continue
		if t <= 0.0:
			load_errors.append("第 %d 关的 time_limit 不合法（%s），已忽略这一条" % [id, str(t)])
			continue
		if target <= 0:
			load_errors.append("第 %d 关的 target_money 不合法（%s），已忽略这一条" % [id, str(target)])
			continue
		# 星级门槛（1 星 = target_money，所以只需要读 2/3 星）。
		#
		# 【必须校验严格递增】三档门槛按顺序比较 —— 写反了（比如三星比一星还低）
		# 的后果不是报错，而是**判定结果毫无意义**：玩家赚 60 元可能同时"是三星"
		# 又"没达标"。这种数据错误靠肉眼很难发现，所以加载时就纠正并记录。
		var s2 := int(entry.get("star2_money", target))
		var s3 := int(entry.get("star3_money", s2))
		if s2 <= target:
			load_errors.append("第 %d 关的 star2_money（%d）不大于 1 星门槛（%d），已自动抬到 1 星 + 1"
				% [id, s2, target])
			s2 = target + 1
		if s3 <= s2:
			load_errors.append("第 %d 关的 star3_money（%d）不大于 2 星门槛（%d），已自动抬到 2 星 + 1"
				% [id, s3, s2])
			s3 = s2 + 1
		out.append({
			"id": id,
			"name": String(entry.get("name", "第 %d 关" % id)),
			"time_limit": t,
			"target_money": target,
			"star2_money": s2,
			"star3_money": s3,
		})
	if out.is_empty():
		load_errors.append("levels.json 没有一条可用的关卡，已退回默认关卡")
		levels = _default_levels()
		return
	out.sort_custom(func(a, b): return int(a["id"]) < int(b["id"]))
	levels = out


func _default_levels() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in DEFAULT_LEVELS:
		out.append((e as Dictionary).duplicate())
	return out


func level_count() -> int:
	return levels.size()


## 第 index1 关、第 star 星的门槛金额（star = 1/2/3，越界会夹到合法档）。
##
## 【唯一入口】结算界面的星星、HUD 的门槛提示、判定该给几星，全都读它 ——
## 这样"1 星就是过关线"这条规则只有一处实现（避免某处又去读 target_money
## 而另一处读 star3_money，两边对不上）。
func star_money(index1: int, star: int) -> int:
	var lv := level_at(index1)
	var s := clampi(star, 1, 3)
	match s:
		1: return int(lv.get("target_money", 0))
		2: return int(lv.get("star2_money", lv.get("target_money", 0)))
		_: return int(lv.get("star3_money", lv.get("star2_money", 0)))
	return 0


## 按「第几关（从 1 开始）」取关卡；越界夹到合法范围，永远返回一个可用字典。
## 【为什么不返回 null】调用方（计时、HUD、结算）几乎每帧都要用，
## 让每个调用点判空必然会漏一处 —— 那处就会炸或者显示空白。
func level_at(index1: int) -> Dictionary:
	if levels.is_empty():
		return DEFAULT_LEVELS[0]
	var i := clampi(index1 - 1, 0, levels.size() - 1)
	return levels[i]


# ── 数值快捷读取 ───────────────────────────────────────────────────

func num(key: String) -> float:
	return float(config.get(key, DEFAULT_CONFIG.get(key, 0.0)))


func table_count() -> int:
	return int(config.get("table_count", 3))


# ── 餐品查询 ───────────────────────────────────────────────────────

## 返回 {id,name,price,color,is_drink,is_main,start_level}；未知 id 返回空字典。
func item(id: String) -> Dictionary:
	return _by_id.get(id, {})


## 这道菜从第几关开始出现（menu.json 的 start_level，默认 1）。
func item_start_level(id: String) -> int:
	var it := item(id)
	if it.is_empty():
		return 1
	return maxi(1, int(it.get("start_level", 1)))


## 这道菜在第 level1 关可用吗？
##
## 【为什么菜单需要"按关卡解锁"】已与玩家确认：柠檬水是第 3 关才加的，
## 前两关不该出现。菜单本身是全局的（menu.json 不区分关卡），
## 所以用 start_level 这种**渐进解锁**表达，而不是给每关各写一份菜单 ——
## 后者会让"加一道菜"要改 N 处。
func item_available_at(id: String, level1: int) -> bool:
	return item_start_level(id) <= maxi(1, level1)


## 第 level1 关能用的饮品列表（顺序 = menu.json 顺序，饮料机按钮照它生成）
func drink_items_at(level1: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for it in drink_items:
		if item_available_at(String(it["id"]), level1):
			out.append(it)
	return out


## 第 level1 关能用的全部餐品 id（客人点单的抽取池）
func pool_at(level1: int) -> Array[String]:
	var out: Array[String] = []
	for it in kitchen_items:
		if item_available_at(String(it["id"]), level1):
			out.append(String(it["id"]))
	for it in drink_items:
		if item_available_at(String(it["id"]), level1):
			out.append(String(it["id"]))
	return out


## 这道菜算「主食」吗 —— 直接读它自己的 is_main，未知 id 一律按非主食处理。
func item_is_main(id: String) -> bool:
	var it := item(id)
	if it.is_empty():
		return false
	return bool(it.get("is_main", false))


## 菜单里所有主食的 id（后厨菜里带 main 标记的那些）
func main_item_ids() -> Array[String]:
	var out: Array[String] = []
	for it in kitchen_items:
		if bool(it.get("is_main", false)):
			out.append(String(it["id"]))
	return out


func item_name(id: String) -> String:
	var it := item(id)
	return String(it.get("name", id))


func item_price(id: String) -> int:
	var it := item(id)
	return int(it.get("price", 0))


func item_color(id: String) -> Color:
	var it := item(id)
	return Color(String(it.get("color", "888888")))


func has_item(id: String) -> bool:
	return _by_id.has(id)


## 订单总价
func total_price(ids: Array) -> int:
	var sum := 0
	for id in ids:
		sum += item_price(String(id))
	return sum


# ── 点单随机（文档：1~2 样，允许重复）──────────────────────────────

## 生成一张订单：随机条数 → 每次从**本关可用**的全菜单（后厨 + 饮品）随机取一道。
## 允许重复，例如 ["burger", "burger"] 或 ["burger", "cola"]。
##
## 【为什么按 Game.level_index 过滤】菜单里有 start_level 解锁的菜
## （柠檬水从第 3 关才有）。不按关卡过滤的话，前两关的客人也会点它 ——
## 而饮料机里根本没有这个按钮，玩家就永远上不了这份菜。
func roll_order() -> Array[String]:
	var pool := pool_at(Game.level_index)
	if pool.is_empty():
		return []

	var n := _roll_item_count()
	var out: Array[String] = []
	for i in n:
		out.append(pool[_rng.randi_range(0, pool.size() - 1)])
	return out


var _rng := RandomNumberGenerator.new()


# ── 整组点单（「不能只点饮料」这条规则在这里）────────────────────────
##
## 【规则】每「桌」至少点 `min_main_per_group` 份主食（默认 1，0 = 关闭）。
## 已与用户确认两件事：
##   1. 按**整桌合计**算，不是按人 —— 一组两人允许「一人汉堡、另一人只喝可乐」；
##   2. 采用**重摇**而不是「把饮料改成主食」：按原规则摇 1~2 样，
##      整桌主食不够就把**整组**重新摇一遍（不是只补摇某一位）。
##
## 【为什么必须整组一起摇，而不是各摇各的再补】
## 成员分开摇、事后补摇某一位，会让「谁被迫点主食」永远落在同一个人身上
## （比如总是最后入座的那位），客人之间的机会就不平等了。
## 整组一起摇 → 不满足就整组重来，每个人被抽中的概率一致。
##
## 【为什么放在 Config 而不是 Table】
## 这是「客人怎么点单」的规则，和菜单数据（哪些是主食）绑在一起；
## Table 只管「这张桌点了什么」。放这里也方便单测。

## 摇一整组的订单。返回与 group_size 等长的数组，每项是那位客人的菜。
func roll_group_orders(group_size: int) -> Array:
	var n := maxi(1, group_size)
	var out: Array = []
	var need := maxi(0, int(config.get("min_main_per_group", 1)))
	# 菜单里一道主食都没有 → 这条规则无解，直接按普通规则摇（不重摇、不死循环）
	if need > 0 and main_item_ids().is_empty():
		for i in n:
			out.append(roll_order())
		return out

	var attempts := maxi(1, int(config.get("group_order_reroll_max", 20)))
	for attempt in attempts:
		out.clear()
		var mains := 0
		for i in n:
			var order := roll_order()
			out.append(order)
			for id in order:
				if item_is_main(String(id)):
					mains += 1
		if mains >= need:
			return out

	# 摇满上限还没满足（概率极低）→ 补救：
	# 给前 need 位客人各塞一份主食，保证「不能只点饮料」这条规则永远成立。
	# 换掉他们单里的最后一样（而不是整单替换），尽量保留原本点的东西。
	var pool := main_item_ids()
	if not pool.is_empty() and need > 0:
		for i in mini(need, out.size()):
			var order: Array = out[i]
			var main_id := pool[_rng.randi_range(0, pool.size() - 1)]
			if order.is_empty():
				order.append(main_id)
			else:
				order[order.size() - 1] = main_id
	push_warning("[Config] 整组主食重摇 %d 次仍未满足，已直接补一份主食" % attempts)
	return out


func _roll_item_count() -> int:
	var lo := 1
	var hi := clampi(int(config.get("max_items_per_customer", 2)), 1, 8)
	var weights: Dictionary = config.get("item_count_weights", {})
	var total := 0.0
	for k in weights:
		var n := int(k)
		if n >= lo and n <= hi:
			total += maxf(0.0, float(weights[k]))
	if total <= 0.0:
		return hi
	var pick := _rng.randf() * total
	var acc := 0.0
	for k in weights:
		var n := int(k)
		if n < lo or n > hi:
			continue
		acc += maxf(0.0, float(weights[k]))
		if pick <= acc:
			return n
	return hi


func set_seed(s: int) -> void:
	_rng.seed = s


## 掷「这一组来几位客人」（1~2 人，70% / 30%，已与用户确认）。
## 权重在 config.json 的 group_size_weights 里，改难度不用碰代码。
## 上限受"餐厅最大座位数"约束：超过一张桌的座位数就不可能整组同桌。
func roll_group_size() -> int:
	var max_seats := 1
	for entry in layout.get("tables", []):
		var seats: Variant = entry.get("seats", [])
		if typeof(seats) == TYPE_ARRAY:
			max_seats = maxi(max_seats, (seats as Array).size())

	var weights: Dictionary = config.get("group_size_weights", {})
	var cands: Array = []
	var total := 0.0
	for k in weights:
		var n := int(k)
		if n >= 1 and n <= max_seats and float(weights[k]) > 0.0:
			cands.append({"n": n, "w": float(weights[k])})
			total += float(weights[k])
	if cands.is_empty() or total <= 0.0:
		return 1
	var pick := _rng.randf() * total
	var acc := 0.0
	for c in cands:
		acc += float(c["w"])
		if pick <= acc:
			return int(c["n"])
	return int(cands[cands.size() - 1]["n"])


# ── 内部 ───────────────────────────────────────────────────────────

func _load_menu() -> void:
	var raw := _read_json(MENU_PATH)
	var sections: Array[String] = ["kitchen_items", "drink_items"]
	for key: String in sections:
		var is_drink := key == "drink_items"
		for entry in raw.get(key, []):
			if typeof(entry) != TYPE_DICTIONARY or not entry.has("id"):
				load_errors.append("menu.json 的 %s 里有缺 id 的条目" % key)
				continue
			var id := String(entry["id"])
			if _by_id.has(id):
				load_errors.append("menu.json 里 id 重复：%s" % id)
				continue
			var def := {
				"id": id,
				"name": String(entry.get("name", id)),
				"price": int(entry.get("price", 0)),
				"color": String(entry.get("color", "888888")),
				"is_drink": is_drink,
				# 主食标记只对后厨菜有意义（饮品是饮料，不是主食）。
				# 缺字段时退回 MAIN_BY_DEFAULT，理由见那个常量的说明。
				"is_main": (false if is_drink
					else bool(entry.get("main", MAIN_BY_DEFAULT))),
				# 从第几关开始出现（默认 1 = 一开始就有）
				"start_level": maxi(1, int(entry.get("start_level", 1))),
			}
			_by_id[id] = def
			if is_drink:
				drink_items.append(def)
			else:
				kitchen_items.append(def)

	if _by_id.is_empty():
		load_errors.append("menu.json 一道菜都没有")


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		load_errors.append("缺少文件：" + path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		load_errors.append("JSON 解析失败：" + path)
		return {}
	var out: Dictionary = parsed
	# 丢掉 _ 开头的注释键
	for k in out.keys():
		if String(k).begins_with("_"):
			out.erase(k)
	return out


## 让 JSON 里缺的字段退回默认值（递归）
func _deep_merge(base: Dictionary, over: Dictionary) -> Dictionary:
	for k in over:
		var v: Variant = over[k]
		if typeof(v) == TYPE_DICTIONARY and base.has(k) and typeof(base[k]) == TYPE_DICTIONARY:
			base[k] = _deep_merge(base[k], v)
		else:
			base[k] = v
	return base
