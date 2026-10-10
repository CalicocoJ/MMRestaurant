extends Resource
class_name GuestSkinPool
## 客人皮肤池：一份资源里放好几套 `GuestSkin`，生成客人时随机抽一套。
##
## 【为什么不直接在 level.gd 上开一个 Array】
## 皮肤池是**内容**，不是关卡逻辑。做成资源的好处：
##   - 可以存成 `.tres`（`assets/guests/skin_pool.tres`），**不进 main.tscn**，
##     改皮肤不用碰场景文件，也不会让场景 diff 变脏；
##   - 换一套池子（第 1 关只有两种客人、第 3 关多几种）只要换一个引用；
##   - 以后做「不同关卡不同客群」时，池子天然是可切换的单位。
##
## 【怎么造】文件系统面板右键 → 新建 → 资源 → 搜 `GuestSkinPool`
## → 在检查器里往 `skins` 数组里加元素、把每份 GuestSkin 的 .tres 拖进去。

## 池子里所有的皮肤。按顺序放；抽取是**均匀随机**的。
##
## 【为什么允许留空】留空 → `pick()` 返回 null → 客人退回「代码画的灰圆」
## （旧行为）。这样 tools/ 下那批体检脚本加载同一个 main.tscn 时不会挂。
@export var skins: Array[GuestSkin] = []

## 每套皮肤的权重（和 `skins` 一一对应，留空 = 全部等权）。
##
## 【为什么用平行数组而不是给 GuestSkin 加 weight 字段】
## 同一个皮肤在不同关卡可能权重不同（第 5 关"小孩"变多），权重属于**池子**
## 的配置而不是皮肤本身的属性。平行数组是这里最省事的做法：
## 长度不够 / 留空时按等权处理，不会因为少填一个数就崩。
@export var weights: Array[float] = []


## 抽一套皮肤。池子为空时返回 null。
##
## 【怎么用】`spawner` 造客人时调它，把结果交给 Guest 挂上贴图。
## 返回 null 的各种情况（池子为空、元素是 null、资源损坏）都归到
## 「退回灰圆」这一条路上，不报错 —— 内容缺失不该让游戏起不来。
func pick(rng: RandomNumberGenerator = null) -> GuestSkin:
	var pool: Array[GuestSkin] = []
	var w: Array[float] = []
	for i in skins.size():
		var s: GuestSkin = skins[i]
		if s == null or not s.is_valid():
			# 没配 SpriteFrames 的皮肤直接跳过：挂上去就是个隐形客人，
			# 比"退回灰圆"更难发现。
			continue
		pool.append(s)
		w.append(weights[i] if i < weights.size() else 1.0)
	if pool.is_empty():
		return null

	var total := 0.0
	for v in w:
		total += maxf(0.0, v)
	# 权重全是 0（或没配）→ 退回等权，否则会永远只抽到第一个
	if total <= 0.0:
		return pool[_rand_index(pool.size(), rng)]
	var roll := _randf(rng) * total
	var acc := 0.0
	for i in pool.size():
		acc += maxf(0.0, w[i])
		if roll <= acc:
			return pool[i]
	return pool[pool.size() - 1]


## 池子里有效的皮肤数（体检 / 调试用）
func valid_count() -> int:
	var n := 0
	for s in skins:
		if s != null and s.is_valid():
			n += 1
	return n


func _rand_index(n: int, rng: RandomNumberGenerator) -> int:
	if rng != null:
		return rng.randi() % n
	return randi() % n


func _randf(rng: RandomNumberGenerator) -> float:
	if rng != null:
		return rng.randf()
	return randf()
