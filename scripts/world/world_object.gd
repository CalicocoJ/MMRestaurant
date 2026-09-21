extends StaticBody2D
class_name WorldObject
## 场景里可点击物件的接口约定。
##
## 【为什么基类是 StaticBody2D 而不是 Node2D】
## 家具要挡住服务员，所以碰撞是它的天生属性。
## 而且「服务员能走到哪」完全由碰撞盒决定 —— 一旦基类不是物理体，
## 每个子类都得自己补 collision_layer，迟早漏一个，
## 表现为「某个家具走不过去」，非常难查。
##
## 任何被 ClickRouter 找到的节点，只要实现下面这几个方法就能被点击。
##
## 【三件事分开，是为了让点击判定不出错】
##   1. click_rect()    —— 鼠标碰到它算不算点到它（宽松：整个家具的矩形）
##   2. accepts_click() —— 现在点它应不应该有反应（严格：比如空手时点垃圾桶没反应）
##   3. interact()      —— 让服务员走过去，到达后执行动作
##
## 如果只用一个判定，就会出现「点在家具边缘但那里没东西可做」这类
## 含糊情况；分开以后，家具会稳定地吃掉自己范围内的点击，
## 空地点击不会被家具抢走。
##
## 【客人为什么优先】
## 客人坐在桌子右侧、身体和桌子矩形有重叠。鼠标落在重叠区时，
## 必须优先把点击给客人（文档：点客人接单/上菜），而不是给桌子。
## 所以 ClickRouter 先单独找客人，找不到才去找家具。

var kind: int = Constants.Kind.GROUND
var display_label: String = ""


## 玩家点的矩形（局部坐标）。默认 0 尺寸 = 不可点击。
func click_rect() -> Rect2:
	return Rect2()


## 现在这点点击应不应该有反应
func accepts_click() -> bool:
	return false


## 让服务员过来做事。返回一个结果码供 ClickRouter 决定后续。
func interact(_router: Node) -> int:
	return RouterResult.NO_ACTION


## 玩家该站在哪（世界坐标）。默认返回全局原点。
##
## 【注意】这是**可选的兼容入口**：只有「碰到就触发」之外还要指定精确站位，
## 或者需要给测试一个参考点时才用。
## 桌子和客人已经改成「碰触即到达」，不再依赖它算出来的那个点。
func walk_to() -> Vector2:
	return global_position


# ── 「碰到就触发」用的几何信息 ─────────────────────────────────────
##
## 【为什么要这三个方法】
## 玩家反馈：点桌子时服务员必须先绕到桌子正下方某个固定点，很蠢。
## 改成「身体贴上桌子就触发」以后，到达判定不再看某个坐标，
## 而是问目标物件两个问题：
##   1. 离我最近的「可碰位置」在哪？（touch_point）
##   2. 我这会儿碰到你了吗？（touches_from）
## 默认实现是「一个点 + 半径」，适合客人这种不是物理物体的目标；
## 家具则覆盖成「碰撞盒」，于是从哪一侧贴上都能触发。

## 离给定位置最近的可碰点（世界坐标）
func touch_point(_from: Vector2) -> Vector2:
	return global_position


## 从 from 出发、半径 radius 的圆，现在碰到这个物件了吗
func touches_from(from: Vector2, radius: float) -> bool:
	return from.distance_to(global_position) <= touch_radius() + radius


## 默认的可碰半径（不是物理体的物件用这个）
func touch_radius() -> float:
	return 0.0


## 可碰判定用的矩形（世界坐标）。返回 size 为 0 表示「本物件用点+半径」。
##
## 【为什么要有这个接口】桌子的**碰撞盒**和**可碰区域**故意不一样：
##   碰撞盒 = 桌面下部 3/4  —— 喂给寻路网格，动它会牵动一堆已验证的行为
##                            （座位可达性、服务员不压桌面…）
##   可碰区 = 整个桌面       —— 「碰到桌子」应该按眼睛看到的桌面算，
##                            否则站在椅子旁边会被误判成碰到桌子
## 所以桌子覆盖本方法返回完整桌面，寻路那边完全不受影响。
func touch_box() -> Rect2:
	return Rect2(global_position, Vector2.ZERO)


## 服务员碰上来之后，还应该**再退开多少**像素站定。
##
## 【为什么需要这个概念】
## 「碰到就算到」有两个互相拉扯的要求：
##   上限：可碰半径必须够大，否则服务员贴着椅子却判定不到「已到达」
##         （客人坐实体椅子上，最大只能走到离客人约 46px 处）
##   下限：停下来时不能和对方身体重叠
##         （不重叠要求 ≥ 客人半径 + 服务员半径 = 31px）
## 所以只要让服务员**贴着上限站定**，两个要求就不冲突了 ——
## 这个「退开量」就是把落点往外推到上限的那个偏移。
##
## 默认 0：家具不需要（它们的碰撞盒本身就让服务员停在外面）。
func standoff() -> float:
	return 0.0


## 命中测试：鼠标是否落在这个物件上
func hit_test(world_point: Vector2) -> bool:
	var r := click_rect()
	if r.size == Vector2.ZERO:
		return false
	return r.has_point(to_local(world_point))


## 在上方飘一条字（世界坐标 → 屏幕坐标）
func float_text(text: String, color: Color = Constants.COLOR_TEXT) -> void:
	Stickers.push_world(global_position, text, color)
