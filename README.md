# 餐厅物语

一个餐厅时间管理小游戏。你扮演服务员，**只用鼠标左键**点场景里的东西：
点客人接单、去柜台取餐、走到客人身边上菜、点脏桌收拾。
点完服务员会自己走过去，**到了才动手** —— 跑腿时间就是这个游戏的压力来源。

**Godot 4.7.2**，2D，一关一局（5 关，每关 3 档星级）。
美术为 **32×32 像素风**（50s diner 素材，对齐到 16×16 网格）。

> 详细功能规格见 **`SPEC.md`**，当前进度与已知问题见 **`PROGRESS.md`**。

---

## ⚠️ 先读这一条：场景是「在编辑器里摆的」

这个工程和早期版本有个**根本区别**：

| | 早期 | 现在 |
|---|---|---|
| 场景布局 | 全部由代码按 `data/layout.json` **生成** | **在 Godot 编辑器里手动摆放** |
| 家具 | 代码 `StaticBody2D.new()` 现造 | **场景里的节点**，挂在 `World` 下 |
| 地板/墙 | `floor_art.gd` 用代码画色块 | **`TileMapLayer`** |
| 镜头 | 无（整屏可见） | **`Camera2D`**（自己框定显示区域） |

**`data/layout.json` 仍然保留，但已降级为「设计意图记录 + 测试基准」**，运行时不再读取它。

### 两条摆家具的路径

代码同时支持两种模式，**按 `World` 下有没有内容自动分流**：

| 模式 | 触发条件 | 行为 | 用在哪 |
|---|---|---|---|
| **编辑器摆放** | `World` 下有子节点 | **只采纳你摆的，一件都不生成** | **游戏正常运行** |
| **自动生成** | `force_generated_layout = true` | 清空后按 `layout.json` 全量生成 | **体检工具**（断言写的是旧坐标） |

> ⚠️ **编辑器摆放模式下，代码不会给你补任何东西。**
> `World` 里缺桌子、缺门口，它就是不生成 —— **门口尤其关键**：
> `Door.setup()` 负责登记客人的出生点和离场点，没摆门口，客人会从硬编码的
> 旧坐标冒出来（且**不报错**）。这是**刻意**的设计：场景由你完全掌控，
> 代码不再往里塞东西。
>
> 工具脚本实例化 `main.tscn` 之后会设 `force_generated_layout = true`，
> 把自己摆的家具整个让开、切回生成模式 —— 这样**设计场景和体检才能长期共存**。

---

## 拿到工程后怎么跑

1. 装 **Godot 4.7.x**（标准版即可，不需要 .NET/C# 版）：<https://godotengine.org/download>
2. `git clone` 本仓库，或用网页上的 *Download ZIP* 解压
3. 打开 Godot → **Import** → 选中工程根目录的 **`project.godot`**
4. 按 **F5** 运行（主场景是 `scenes/main.tscn`）

> 首次打开时 Godot 会自己生成 `.godot/` 缓存目录（已加进 `.gitignore`，不用管）。

### 跑一遍工程自带的体检

工程里有 40+ 个体检脚本（寻路、碰撞、座位可达性、场景结构…），都用无头模式跑。
**推荐直接用 Godot 命令行**（`run_tests.ps1` 在本机可能被执行策略拦住）：

```powershell
# 需要 $env:GODOT 指向 console 版 exe（windowed 版不往 stdout 打印）
& $env:GODOT --headless --path . res://tools/run_tests.tscn

# 跑单个体检（tools/ 下每个 .tscn 就是一个）
& $env:GODOT --headless --path . res://tools/check_routes.tscn
```

**⚠️ 判断有没有回归时，别只看 `run_tests.tscn`。** 那套是开发早期写的，
里面积了十几项**停留在旧坐标/旧时序**上的断言，而且**驱动物理帧的用例有超时随机性**
（同一份代码连跑两次失败项可能不同）。**更可靠的是 `tools/` 下那些专门的体检脚本。**

### 两个开发期的自查工具

```powershell
# 读当前设计场景：节点树、地板范围、碰撞形状、贴图与碰撞盒是否错位
& $env:GODOT --headless --path . --script res://tools/report_scene.gd

# 检查柜台上的一份食物节点是否正常（下拉候选值、接口、是否挡人）
& $env:GODOT --headless --path . --script res://tools/check_counter_food.gd
```

---

## 目录结构

```
MMRestaurant/
├── project.godot          工程配置（autoload、字体、视口 1280×720）
├── scenes/main.tscn       ★ 唯一场景 = 你的关卡。地板 / 柜台 / 家具 / 相机都在这里
│
├── data/                  ★ 数值与菜单（改它不用碰代码）
│   ├── config.json            关键数值（耐心、速度、时长、容量、随机性权重）
│   ├── levels.json            关卡表（时长 + 3 档星级门槛）
│   ├── menu.json              菜单（id / 名称 / 价格 / 占位色 / 起始关卡）
│   └── layout.json            旧布局坐标（**已不参与运行**，仅作参考与测试基准）
│
├── scripts/
│   ├── core/              配置、对局状态、订单、后厨队列、点击路由、寻路、餐品外观
│   ├── world/             家具脚本：桌子 / 椅子 / 柜台食物 / 后厨窗口 / 饮料机 / 垃圾桶 / 门口
│   ├── actors/            服务员、客人
│   ├── level/             主场景接线、客人生成、座位分配
│   ├── ui/                HUD、订单栏、弹窗、飘字、字体
│   └── tools/             开发期参考工具（非运行时代码）
│
├── assets/                字体、像素素材（tileset / 家具 / 门 / 食物）
│   └── items/             餐品图标（按 id 命名丢进来自动生效，见那里的 README）
├── addons/godot-mcp/      Godot MCP Bridge 插件（给 AI 提供运行时反馈，可选）
├── tools/                 开发与验证工具（体检脚本、截图、场景报告）
│
├── SPEC.md                功能规格（行为的权威描述）
└── PROGRESS.md            当前进度、待办、已知问题
```

---

## 在场景里摆东西的约定（**违反会静默失效**）

这套逻辑靠「遍历 `World` 的子节点 + 检查方法」工作，所以有几条硬约定：

| # | 约定 | 违反的后果 |
|---|---|---|
| 1 | **可点物件必须是 `World` 的*直接*子节点** | 点不到、不挡人、寻路也不理它，**且不报错** |
| 2 | 每类家具要挂对应脚本（`table.gd` / `chair.gd` / `counter_food.gd` …） | 同上 |
| 3 | **椅子是 `Table` 的子节点** | 座位不存在、客人无处可坐 |
| 4 | 装饰物（地板、柜台本体）**不要放进 `World`** | 会被当成可点物件参与遍历（虽然一般会被跳过） |
| 5 | 贴图 `Sprite2D` 取消勾选 `Centered` | 贴图会和碰撞盒/点击范围差半个身位 |
| 6 | 家具的 `Collision Layer` = `world`(1)、`Mask` = `waiter`(2) | 服务员撞不到它 → **直接穿过去** |

### 关于碰撞盒：两种做法，二选一

| 做法 | 怎么用 | 适合 |
|---|---|---|
| **代码自动生成** | 留 `Auto Generate Shapes` 勾选，碰撞盒按贴图比例算 | 先跑起来、不纠结细节 |
| **自己摆** | 关掉 `Auto Generate Shapes`，加 `CollisionShape2D` 自己摆 | **精确控制**（推荐） |

> 即使你忘了关开关，只要身上已经有碰撞形状，代码也会当成「你已经摆了」而不重复生成。
>
> **柜台的阻挡由柜台自己的 `StaticBody2D` + `CollisionShape2D` 负责；
> 柜台上的食物节点不挡人**（碰撞盒留空），两者分工。

### 柜台与食物

```
Level
├── Floor          (TileMapLayer)     地板 / 墙
├── Counter        (StaticBody2D)     柜台本体：不挂脚本，只管挡人
│   ├── Sprite2D
│   └── CollisionShape2D
├── World          (Node2D)
│   ├── Table1     (StaticBody2D) → table.gd
│   │   ├── Sprite2D
│   │   ├── Chair1 (StaticBody2D) → chair.gd  （有精灵/缩放/碰撞形状）
│   │   └── Chair2 ...
│   ├── Food1      (StaticBody2D) → counter_food.gd   ← 可点、不挡人
│   │   └── Sprite2D
│   └── Door1      (StaticBody2D) → door.gd
└── Camera2D                           框定显示区域
```

**`counter_food.gd` 的 `item_id` 是下拉选择**（候选值来自 `data/menu.json`），
所以加新菜不会拼错 id。

> ⚠️ **柜台上必须摆齐本关菜单里的每一道菜。** 客人是从「本关可用的全部餐品」
> 随机点单的，**少摆一样，点到它的那桌就永远上不了菜**（客人一直等、最后气走），
> 而且**不报任何错**。
>
> 有个自查工具专门查这件事：
> ```powershell
> & $env:GODOT --headless --path . --script res://tools/check_counter_food.gd
> ```
> 它会逐份报 `item_id` 是否合法、运行时可见性、贴图与点击范围是否对齐，
> 最后比对「柜台上的菜」和「本关菜单池」。

---

## 占位美术：什么时候该关 `draw_placeholder`

家具的**占位色块**（代码画的矩形/色块）由各脚本的 `draw_placeholder` 控制。
**贴图挂好之后必须关掉**，否则色块和贴图叠画、画面发脏。

**这个毛病在编辑器里看不出来** —— `_draw()` 在编辑器走的是"参考线"分支
（那是有意保留的，用来摆场景时看碰撞盒/站位点），**只有 F5 才暴露**。
所以很容易误判成"代码又生成了什么东西"。

**现在的规则**（两道保险）：

| 保险 | 说明 |
|---|---|
| **默认 `false`** | `table.gd` / `chair.gd` / `door.gd` / `counter_food.gd` 的默认值都是关 |
| **有贴图就自动关** | `EntityBase.auto_disable_placeholder_if_sprite()`：只要节点直接挂了**有贴图的** `Sprite2D`，就在 `setup_from_editor()` 里自动关掉 |

还没有贴图时，手动勾上 `draw_placeholder` 就能看到色块。

### 贴图必须和节点原点对齐（否则点击范围错位）

**点击范围（`click_rect`）以节点原点为基准**，所以：

- **贴图左上角必须落在节点原点上** → `Sprite2D` 的 `Centered` **取消**、`Position` **归零**
- 否则会出现「**你点看到的图标没反应，点别处的空地反而触发了它**」

**实测过的两个 Godot 细节**（别凭直觉）：

| 细节 | 结论 |
|---|---|
| `Sprite2D` 的 `Offset` 和 `Region` | **互不相干**，不需要互相抵消。看着跑偏几乎总是因为 `Centered` 还勾着 |
| `Sprite2D.get_rect()` | **不含 `scale`**。`Centered=false` 时「贴图左上角 = 节点原点」，缩放只让视觉变大、`rect_size` 不变 |
| 缩放 > 1 的后果 | 视觉比点击范围大一点（所见比可点大，能接受）。要精确对齐就得让贴图和 `rect_size` 一起缩放 |

自查脚本：`res://tools/probe_sprite_rect.gd`（量 `get_rect()` 的缩放语义）、
`res://tools/dump_runtime_tree.gd`（导出运行时节点树 + 逐节点检查占位开关）。

---

## 想改点什么（常见入口）

| 想改 | 改哪里 |
|---|---|
| 难度 / 星级门槛 | `data/levels.json`（`time_limit` + 三个金额） |
| 客人耐心、走路速度、手上容量 | `data/config.json` |
| 菜价 / 加一道菜 | `data/menu.json`（加图片见 `assets/items/README.md`） |
| 一道菜从第几关出现 | `data/menu.json` 的 `start_level`，或食物节点的 `start_level` |
| 家具位置 / 房间大小 / 镜头 | **在 Godot 编辑器里摆**（`scenes/main.tscn`） |
| 只调数值 | **不用碰代码**，改完存盘重启游戏即可 |

---

## 致谢 / 第三方

- **Godot MCP Bridge**（`addons/godot-mcp/`），作者 letsagents (LuoHan)，MIT。
  它给 AI 助手提供 Godot 的运行时反馈（错误、场景树、节点属性、截图）。
  属于**开发辅助**，不参与游戏运行；删掉它游戏照样跑。
  上游：<https://github.com/letsagents/godot-mcp>
