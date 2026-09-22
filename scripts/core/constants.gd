extends RefCounted
class_name Constants
## 全局常量。
##
## 【为什么单开一个文件】
## 颜色、图层、UI 文案这些字符串散落在各处最容易写出错别字
## （"burger" 打成 "buger" 编译器不会报错，但游戏会静默失灵）。
## 集中到这里，写错立刻报错。


# ── 餐品 ID ────────────────────────────────────────────────────────
const BURGER := "burger"
const FRIES := "fries"
const CHICKEN := "chicken"
const COLA := "cola"


# ── 客人状态 ───────────────────────────────────────────────────────
## 客人状态机。与文档第四节一一对应。
enum State {
	WALKING_IN,       ## 从门口走向桌子（不可点击）
	WAITING_TO_ORDER, ## 已坐下，等玩家来接单（可点击，28s）
	ORDER_TAKEN,      ## 已接单，等上菜（可点击，45s）
	ORDERED,          ## 后厨 UI 点「完成」后（可点击，继续 45s）
	EATING,           ## 订单全部上齐（不可点击，12s）
	LEAVING,          ## 吃完走向门口（不可点击）
	ANGRY_LEAVING,    ## 耐心归零走向门口（不可点击）
}


# ── 物件种类（ClickRouter 辨别点到了什么）─────────────────────────
enum Kind {
	GROUND,   ## 空地
	TABLE,    ## 桌子（干净空桌 / 脏桌 / 有客）
	COUNTER,  ## 后厨出餐口
	DRINK,    ## 饮料机
	TRASH,    ## 垃圾桶
	DOOR,     ## 门口
	CUSTOMER, ## 客人
}


# ── 颜色（占位美术）──────────────────────────────────────────────
const COLOR_BG := Color("1d232b")
const COLOR_FLOOR := Color("2a323d")
const COLOR_WALL := Color("39424f")

const COLOR_TABLE_CLEAN := Color("b98a52")
const COLOR_TABLE_DIRTY := Color("6d5a45")
const COLOR_TABLE_BUSY := Color("8a6a42")

## 椅子：空着一眼能看出来（玩家要能看出哪桌还有位子）
const COLOR_CHAIR_FREE := Color("9aa7b4")
const COLOR_CHAIR_TAKEN := Color("7a6a55")
const COLOR_CHAIR_BACK := Color("5a6672")
const COLOR_COUNTER := Color("4a5568")
const COLOR_DRINK_MACHINE := Color("4a6b8a")
const COLOR_TRASH := Color("5a5f66")
const COLOR_DOOR := Color("7a6a4a")

const COLOR_WAITER := Color("e8e8e8")
const COLOR_CUSTOMER := Color("7fc7e8")
const COLOR_CUSTOMER_ANGRY := Color("e8776b")
const COLOR_CUSTOMER_EATING := Color("8fd98f")

const COLOR_TEXT := Color("f0f0f0")
const COLOR_TEXT_DIM := Color("9aa3ad")
const COLOR_PATIENCE_BG := Color("3a3a3a")
const COLOR_PATIENCE_FG := Color("ffffff")
const COLOR_STRIKE := Color("ff5a5a")
const COLOR_MONEY := Color("ffd766")
const COLOR_BUBBLE_BG := Color(0.1, 0.1, 0.12, 0.88)
const COLOR_BUBBLE_BORDER := Color(1, 1, 1, 0.35)

const COLOR_PROGRESS_BG := Color(0.1, 0.1, 0.1, 0.8)
const COLOR_PROGRESS_FG := Color("6fd98f")


# ── UI 文案 ────────────────────────────────────────────────────────
## 飘字文案。
## 前四句来自文档第十四节；MSG_HAND_EMPTY 在文档里只写给了垃圾桶，
## 这里复用为「空手点已接单的客人」的提示 ——
## 那种情况下说「这不是他要的菜」会让人误以为是菜点错了。
const MSG_PICK_DISH_FIRST := "请先点菜"
## 【文案改过一次】原来是「这不是他要的菜」。玩家反馈这句话是**从客人视角**说的，
## 而点击的主体是「这桌」；改成从桌子视角说，听感更顺，也和「这桌是空的」成一套。
## 【什么时候会出现它】桌边有人、但**没有人**还缺你手上这几样 ——
## 包括「客人已经吃上了」和「他点的不是这一样」两种情况。
const MSG_WRONG_DISH := "这桌没点这个菜"
## 点了一张**一个客人都没有**的干净空桌。
## 【和 MSG_WRONG_DISH 必须分清楚】这两句话问的是不同的问题：
## 前者是「桌上没有人」，后者是「有人但不要这个」。
## 判断顺序写反就会在空桌上说出「没点这个菜」（玩家实测报过）。
const MSG_TABLE_EMPTY := "这桌是空的"
const MSG_HAND_FULL := "手上已有餐品"
const MSG_HAND_EMPTY := "手上没有餐品"
const MSG_COUNTER_EMPTY := "出餐口没有餐"
const MSG_UNREACHABLE := "过不去"

## 手上已经拿满（2 份）时的提示。玩家指定的文案。
const MSG_HANDS_FULL := "你拿不下其他东西了"

const MSG_EATING := "用餐中"

## 点了柜台大矩形里**既不是出餐口、也不是点餐铃**的地方。
## 【为什么要有这句】2026 玩家要求「只有点餐铃才弹点餐窗」，于是柜台其余部分
## 不再有任何反应 —— 那种"点了完全没动静"最容易被当成 bug，所以飘一句说明。
const MSG_COUNTER_HINT := "点餐铃点单，出餐口取餐"

## 飘字最多同时存在几条（文档第十四节）
const MAX_STICKERS := 5


# ── 开始界面文案 ───────────────────────────────────────────────────
##
## 【为什么这三句放这里】
## 与飘字文案同一个理由：界面文字集中一处，改文案不用翻脚本，
## 也不会出现「同一个名字在标题和 HUD 里写法不一样」。
##
## 【与 HUD 标题的关系】
## 游戏名只出现在开始界面（大字）。HUD 左上角原来的「餐厅物语」
## 小标题行已删除 —— 标题画面已经说过一次，HUD 再写一遍是噪音，
## 而且删掉后订单栏能整体上移 16px。
const START_TITLE := "麦麦快餐店"
## 开始界面的副标题（玩家指定的文案）。
## 【改过一次】原来写的是「成为麦麦快餐店的一名服务员，享受牛马人生吧！」
## —— 玩家要求改成现在这句。
## 只改这一处即可：开始界面与 check_start 的断言都引用这个常量，
## 不会有「界面改了、断言还在比对旧文案」这种不一致。
const START_SUBTITLE := "成为麦麦快餐店的服务员，燃烧你的牛马之魂吧！"
const START_BUTTON := "开始游戏"

## 标题颜色：复用「钱」的金黄色 —— 深色底上最跳的一档。
const COLOR_START_TITLE := COLOR_MONEY


# ── 共享缓存 ───────────────────────────────────────────────────────
##
## 【为什么字体缓存放这里，而不是放 UiFont 自己身上】
## 每个 `class_name` 脚本都会注册成一个独立的 GDScript 对象，
## 静态变量挂在那个对象实例上；不同调用点经过不同解析路径时
## 可能拿到不同实例，于是「只建一次」失效。
## 挂在一个确定是单例的类上（Constants 谁都用、且只有一份），行为才唯一。

static var _font_cache: Variant = null


static func font_cache_get() -> Variant:
	return _font_cache


static func font_cache_set(f: Variant) -> void:
	_font_cache = f
