extends Node
## 营收分布统计（**分析工具，不改任何玩法**）。
##
## 用法：
##   godot --headless --path <project> res://tools/stat_revenue.tscn
##
## 【它回答什么问题】玩家提出：客人点什么菜是随机的 ——
## 「两个人点 4 个汉堡」一桌就能达标，而「两杯饮料」几乎不赚钱，
## 导致每局成绩不稳、调难度没准头。
## 这个工具把「一桌能赚多少」的真实分布算出来，让调难度有数据可依，
## 而不是继续靠估算（本项目已经因为估算错过好几次）。
##
## 【为什么同时给"单桌"和"整局"两个分布】
##   单桌分布 = 随机性的来源（方差在这里）
##   整局分布 = 玩家真正体验到的结果（多桌求和，方差被平均掉一部分）
## 只看单桌会高估"不稳定"，只看整局又看不出根因。

const SIM_RUNS := 4000        ## 模拟局数
const SIM_ROUNDS := 1         ## 每局只算一关（时长由关卡表决定）

var _pass := 0
var _fail := 0


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	print("")
	print("════════ 营收分布统计（第 3 关菜单）════════")
	print("  菜单单价：%s" % _menu_line(3))

	# 固定种子：结论可复现（换种子可以看稳定性，见最后一段）
	Config.set_seed(20260930)

	_stat_orders()
	_stat_per_table()
	_stat_per_run()
	_stat_luck_effect()

	print("══════════════════════════════════════════")
	print("结果：%d 通过 / %d 失败" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _menu_line(level: int) -> String:
	var parts := PackedStringArray()
	for id in Config.pool_at(level):
		parts.append("%s %d元" % [Config.item_name(id), Config.item_price(id)])
	return " / ".join(parts)


# ── 1. 一桌的订单构成 ──────────────────────────────────────────────

func _stat_orders() -> void:
	print("")
	print("[1] 一桌客人的订单构成（每桌各摇一次，%d 桌）" % SIM_RUNS)
	var group_counts := {1: 0, 2: 0}
	var item_counts := {1: 0, 2: 0, 3: 0, 4: 0}
	var total_items := 0
	for i in SIM_RUNS:
		var size := Config.roll_group_size()
		group_counts[size] = int(group_counts.get(size, 0)) + 1
		for o in Config.roll_group_orders(size):
			var n: int = (o as Array).size()
			item_counts[n] = int(item_counts.get(n, 0)) + 1
			total_items += n
	print("    来客人数：1 人 %d 桌（%.0f%%）/ 2 人 %d 桌（%.0f%%）" % [
		group_counts[1], 100.0 * float(group_counts[1]) / float(SIM_RUNS),
		group_counts[2], 100.0 * float(group_counts[2]) / float(SIM_RUNS)])
	var line := PackedStringArray()
	for k in [1, 2, 3, 4]:
		line.append("点%d样 %d" % [k, int(item_counts.get(k, 0))])
	print("    每人点几样：%s" % " / ".join(line))
	var avg_items := float(total_items) / float(SIM_RUNS)
	print("    平均每桌点 %.2f 样（含重复）" % avg_items)
	ok(avg_items > 1.0 and avg_items < 4.0, "平均每桌点样数在合理范围（%.2f）" % avg_items)


# ── 2. 单桌营收分布（方差的根因）────────────────────────────────────

func _stat_per_table() -> void:
	print("")
	print("[2] **单桌**营收分布（方差的根因）")
	var values := _sample_tables(SIM_RUNS)
	values.sort()
	var mean := _mean(values)
	var sd := _stddev(values, mean)
	print("    平均 %.1f 元 / 标准差 %.1f 元 / 最低 %d 元 / 最高 %d 元" % [
		mean, sd, int(values[0]), int(values[values.size() - 1])])
	print("    分位数：P10 %.0f / P25 %.0f / P50 %.0f / P75 %.0f / P90 %.0f" % [
		_pct(values, 0.10), _pct(values, 0.25), _pct(values, 0.50),
		_pct(values, 0.75), _pct(values, 0.90)])
	# 最差的一类桌：整桌只点饮料（钱极少）
	var drink_only := 0
	var under10 := 0
	for v in values:
		if v <= 10:
			under10 += 1
	print("    营收 ≤10 元的桌：%d / %d（%.0f%%）" % [
		under10, values.size(), 100.0 * float(under10) / float(values.size())])
	ok(mean > 0.0, "单桌平均营收 > 0")
	ok(sd > 0.0, "单桌营收有波动（标准差 %.1f）" % sd)
	print("    【读法】标准差 ≈ %.0f 元、最高/最低 = %d/%d —— 这就是"每次测不稳"的来源" % [
		sd, int(values[0]), int(values[values.size() - 1])])


# ── 3. 整局营收分布（玩家真实体验）─────────────────────────────────

func _stat_per_run() -> void:
	print("")
	print("[3] **整局**营收分布（一局 = 一关的时间，%d 局）" % SIM_RUNS)
	for level in [1, 3]:
		var lv := Config.level_at(level)
		var limit := float(lv.get("time_limit", 90.0))
		var target := int(lv.get("target_money", 0))
		# 一局能接多少桌：按「每组约占桌 (用餐 10s + 收拾/间隔)」粗算
		# 【注意】这是**只算订单金额上限**的估算，不含玩家跑腿/气走，所以偏乐观
		var sec_per_group := 10.0 + 4.0
		var groups := int(limit / sec_per_group)
		var runs := _sample_runs(groups, SIM_RUNS)
		runs.sort()
		var mean := _mean(runs)
		var sd := _stddev(runs, mean)
		var pass_count := 0
		for v in runs:
			if int(v) >= target:
				pass_count += 1
		print("    L%d（%ds，目标 %d 元，按最多 %d 组估算）：" % [
			level, int(limit), target, groups])
		print("      平均 %.0f 元 / 标准差 %.0f 元 / P10 %.0f / P90 %.0f" % [
			mean, sd, _pct(runs, 0.10), _pct(runs, 0.90)])
		print("      **按此估算的达标率 %.0f%%**（运气好/坏差 %.0f 元）" % [
			100.0 * float(pass_count) / float(runs.size()),
			_pct(runs, 0.90) - _pct(runs, 0.10)])
		ok(groups > 0, "L%d 能来至少一组" % level)


# ── 4. "运气"到底影响多大：同样的操作水平，成绩能差多少 ─────────────

func _stat_luck_effect() -> void:
	print("")
	print("[4] 只看运气：**同样接 8 桌**，营收能差多少")
	var settled := 0.0
	var p10 := 0.0
	var p90 := 0.0
	for i in 3:
		var total := 0.0
		var totals: Array[float] = []
		for k in SIM_RUNS:
			var s := 0.0
			for g in 8:
				s += float(_sample_tables_cache())
			totals.append(s)
		totals.sort()
		var mean := _mean(totals)
		if i == 0:
			settled = mean
			p10 = _pct(totals, 0.10)
			p90 = _pct(totals, 0.90)
		print("    第 %d 次抽样：平均 %.0f 元 / P10 %.0f / P90 %.0f（极差 %.0f 元）" % [
			i + 1, mean, _pct(totals, 0.10), _pct(totals, 0.90),
			_pct(totals, 0.90) - _pct(totals, 0.10)])
	print("    【读法】接同样多的桌，只因为"客人点了什么"，成绩就能差 %.0f 元（约 %.0f%%）" % [
		p90 - p10, 100.0 * (p90 - p10) / maxf(1.0, settled)])


# ── 采样 ───────────────────────────────────────────────────────────

func _sample_tables(n: int) -> Array[float]:
	var out: Array[float] = []
	for i in n:
		out.append(_one_table_value())
	return out


func _one_table_value() -> float:
	var size := Config.roll_group_size()
	var total := 0
	for o in Config.roll_group_orders(size):
		total += Config.total_price(o)
	return float(total)


## 单桌采样结果缓存（第 4 节要反复用，避免重复摇）
var _cache: Array[float] = []
var _cache_at := 0

func _sample_tables_cache() -> float:
	if _cache.is_empty():
		_cache = _sample_tables(20000)
		_cache_at = 0
	var v := _cache[_cache_at % _cache.size()]
	_cache_at += 1
	return v


func _sample_runs(groups: int, n: int) -> Array[float]:
	var out: Array[float] = []
	for i in n:
		var s := 0.0
		for g in groups:
			s += _one_table_value()
		out.append(s)
	return out


# ── 统计小工具 ─────────────────────────────────────────────────────

func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += float(v)
	return s / float(a.size())


func _stddev(a: Array, mean: float) -> float:
	if a.size() < 2:
		return 0.0
	var s := 0.0
	for v in a:
		var d := float(v) - mean
		s += d * d
	return sqrt(s / float(a.size()))


## 分位数（a 必须已排序）
func _pct(a: Array, p: float) -> float:
	if a.is_empty():
		return 0.0
	var idx := clampi(int(floor(p * float(a.size()))), 0, a.size() - 1)
	return float(a[idx])


func ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("    PASS  %s" % what)
	else:
		_fail += 1
		print("    FAIL  %s" % what)
