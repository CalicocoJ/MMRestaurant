# 交接摘要（给下一次会话）

> **这份文件是临时的**：给重启后的新会话快速接上进度用。等内容都落进 `README.md` /
> `PROGRESS.md` 之后，**可以直接删掉**。

---

## 一、这个项目现在是什么状态

**「餐厅物语」** —— Godot 4.7.2 的 2D 餐厅时间管理小游戏，鼠标左键操作，
服务员跑腿是压力来源。美术换成 **32×32 像素风（50s diner 素材）**。

### 已经发生的最大变化：**场景改为在编辑器里摆**

| | 早期 | 现在 |
|---|---|---|
| 场景布局 | 代码按 `data/layout.json` 生成 | **在 Godot 编辑器里手摆**（`scenes/main.tscn`） |
| 地板 / 墙 | `floor_art.gd` 代码画色块 | **`TileMapLayer`** |
| 镜头 | 无 | **`Camera2D`** |
| `data/layout.json` | 运行时数据源 | **降级为「设计意图记录 + 测试基准」**，运行时不读 |

**两条摆家具的路径**（按 `World` 下有没有内容自动分流）：

- **编辑器摆放** = 游戏正常运行（你摆的场景）
- **自动生成** = 体检工具用（它们会设 `force_generated_layout = true`，切回 `layout.json`）

---

## 二、已经完成的（都有验证）

| 项 | 状态 |
|---|---|
| Git 环境 + Godot 4.7.2 安装配置 | ✅ 装在 `%LOCALAPPDATA%\Programs\`，`$env:GODOT` 已设 |
| 地板改 TileMap（`level.gd` 的 `_setup_background` / `_resolve_floor_layer`） | ✅ |
| `EntityBase` 加 `setup_from_editor` / `rect_size` / `auto_generate_shapes` | ✅ |
| **尺寸自动跟贴图**（`fit_rect_size_to_sprite`） | ✅ 不用手填 `rect_size` |
| 桌子 / 椅子 / 门口 / 柜台食物 的自绑定入口 | ✅ |
| **椅子拆成独立 `Chair`（`StaticBody2D`）** | ✅ 能自己拥有碰撞盒；座位仍在桌下 |
| `counter_food.gd`（柜台可点食物，`item_id` 下拉） | ✅ 已建、已验证，**但食物节点还没摆** |
| 门口点击默认关闭（`clickable = false`） | ✅ |
| 相机 + 房间尺寸（视图 1280×720，房间约 464×336） | ✅ 你已调好 |
| **文档** | ✅ `README.md` 已改写；**已提交 4 个 commit** |
| MCP：npm 包 `@letsagents/godot-mcp` | ✅ 已装，`godot-mcp` 命令可用 |
| MCP：Godot 插件 `addons/godot-mcp` | ✅ 已启用（`project.godot` 里有 `[editor_plugins]`） |

### 上一轮刚修掉的回归

`Table._build_seat_bodies()` 曾被改成空实现，导致**自动生成路径下椅子不挡人**。
现已改为 `build_seat_bodies()`，由 `setup()` 的 `p_build_seat_bodies` 参数分流：
**编辑器摆放路径不生成**（避免和 Chair 自己的碰撞盒叠两层），**自动生成路径生成**。

---

## 三、**未完成的事（按优先级）**

### 1. MCP —— ✅ **已接通**（2026-10-09）

现在有 40 个 `mcp__godot__*` 工具可直接操作 Godot 编辑器：
`play_scene` / `stop_scene` / `screenshot` / `get_scene_tree` / `inspect_node` /
`set_node_property` / `call_node_method` / `eval` / `simulate_input` /
`get_runtime_errors` / `get_console_output` / `get_diagnostics` / `list_assets` /
`refresh_filesystem` / `reload_scene` / 断点调试全家桶 …

**装法（三件事，缺一不可）**：

1. `npm i -g @letsagents/godot-mcp`（提供 `godot-mcp` 这个 stdio server）
2. Godot 里 **项目设置 → 插件 → 勾 `Godot MCP Bridge`**（它监听 TCP **6510**）
3. `C:\Users\Wjj\.dsh\profiles\web\cordis.patch.yml` 里**用 `insert` 新增**一项：

```yaml
- insert:
    - id: mcp-godot
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: godot
        transport: stdio
        command: godot-mcp
```

然后**重启 DSH**（MCP 工具在启动时连接，不热加载）。

#### ⚠️ 踩过的两个坑（别再犯）

**坑 1：`cordis.patch.yml` 的语法 ≠ 条目数组。**

那个文件是「**patch 列表**」，每个条目的含义是：

| 写法 | 含义 |
|---|---|
| `insert: [rows]` | **新增** rows ← **加插件必须用这个** |
| 只有 `id` 不带 `insert` | **修改**已存在的那个 id（`config` 是**整体替换**，不深合并） |
| 指向不存在的 id | **只警告并跳过** |

我第一版直接写了 `- id: mcp-godot` + `name`，结果启动时报：

```
dsh: [...cordis.patch.yml] patch: entry "mcp-godot" not found
```

**而且它是被静默跳过的——DSH 照常起来，只是插件完全没生效**，所以很容易误判成"环境/沙箱问题"。

**诊断命令**（权威判据，改完配置先跑它）：

```powershell
npx @deepseek-ai/dsh --profile web --dump-config
# 看有没有 "patch: ... not found" 警告；没有警告且能搜到 mcp-godot 才算对
```

**坑 2：`Get-Process` / `Get-NetTCPConnection` 在这个沙箱里看不到宿主进程和监听端口**，
但 **TCP 连接（如 `127.0.0.1:6510`）是通的**。排查别依赖前两个命令，直接用 TCP 连接测。

**另外**：MCP over stdio 要求 harness 能 spawn 子进程并接管其管道。
我实测**受沙箱限制的命令 `spawnSync` 会返回 EPERM**——但 harness 自身显然不受此限制
（否则这些工具不会出现）。所以这条限制只影响**我**发起的命令，不影响 MCP。

### 2. 摆柜台 + 食物（`counter_food.gd` 已就绪）

结构（详情见 `README.md` 的「柜台与食物」）：

```
Level
├── Counter   (StaticBody2D，不挂脚本)  ← 只管挡人；Layer=1(world) Mask=2(waiter)
│   ├── Sprite2D
│   └── CollisionShape2D
└── World
    └── Food1 (StaticBody2D) → counter_food.gd   ← 可点、不挡人
        └── Sprite2D
```

每个食物要设：`item_id`（下拉）、`walk_offset`（站哪取餐）、`start_level`、
关掉 `Draw Placeholder`。

> ⚠️ **柜台上必须摆齐本关菜单里的每一道菜** —— 客人从"本关可用餐品"随机点单，
> **少摆一样那桌就永远上不了菜**（客人等到气走），而且**不报错**。

### 3. **厨房玩法改造（下一个大块，还没开始）**

已和你确认的方案：

| 项 | 决定 |
|---|---|
| 制作过程 | **去掉**（没有"等 3 秒做菜"） |
| 点餐铃 | **删掉** |
| 客人点单 | 客人自己点，**菜单 = 柜台商品**，玩家接单后直接去柜台取 |
| 接单 | **保留**（点客人 → 出票 → 订单栏/共享票/`delivered` 匹配全不动） |
| 拿错食物 | **扔垃圾桶**（垃圾桶保留） |
| 钱 | 送到桌上、客人用餐离开才结算（**逻辑不变**） |
| 饮料机 | 保留，**本轮不动** |

**要动的代码**：`kitchen_window.gd`（去掉铃铛与出餐口逻辑）、`kitchen_popup.gd`（停用）、
`ui_manager.gd`（去掉弹窗接线）、HUD（去掉"后厨队列"）、`kitchen.gd`（多半废弃）。

**建议顺序**：先让你摆好柜台+食物、验证"点食物→走过去→进手上"这条链路通了，
**再动厨房那一大块** —— 免得两件事混在一起出问题定位不了。

### 4. 墙的碰撞

`Floor` 的 `collision_enabled = false`（正确，地板不该挡人）。
**但墙现在大概率不挡人 → 服务员会走出房间。** 按需处理（单独一层 TileMapLayer 开碰撞，
或在 `World` 下摆几个不可见的碰撞体）。

### 5. 其它待办（你说自己处理 / 以后再说）

- **订单栏 UI**：现在在左侧很挡视线，你要自己改
- **饮料机**：需要大改，以后再说
- **角色贴图**：你说会找 4 方向 + 走路动画。**接入时需要我改代码**——
  现在服务员和客人都是代码画的圆，全工程搜 `rotation` / `flip_h` **零匹配**，
  没有任何"按朝向选图"的机制。

---

## 四、已知问题 / 坑

### 测试套件

- **`tools/run_tests.tscn` 不是可靠判据**：里面积了十几项**停留在旧坐标/旧时序**上的断言；
  而且**驱动物理帧的用例有超时随机性**（同一份代码连跑两次失败项可能不同）。
  最近稳定状态约 **191 通过 / 18 失败**。
- **更可靠的是 `tools/` 下专门的体检脚本**，以及这两个自查工具：

```powershell
# 读当前设计场景：节点树、地板范围、碰撞形状、贴图与碰撞盒是否错位
& $env:GODOT --headless --path . --script res://tools/report_scene.gd
# 检查柜台食物节点
& $env:GODOT --headless --path . --script res://tools/check_counter_food.gd
```

- **`scan: 11/48 条路线失败`（座位可达性）**：**已确认由当前场景决定，与代码改动无关**
  （用原始脚本跑同一场景，结果一样是 11/48）。

### 环境坑（踩过的）

| 坑 | 说明 |
|---|---|
| **沙箱阻断 HTTPS** | 所有 HTTPS 在普通命令下报 `SEC_E_NO_CREDENTIALS`；要用网络得提权 |
| **`pwsh` 不存在** | 本机是 **Windows PowerShell 5.1**，用 `powershell.exe` |
| **`Set-Content` 默认 GBK** | 用 PowerShell 批量改 `.gd` 文件会**弄坏中文**（踩过一次，31 个文件）。必须用 `[System.IO.File]::WriteAllText($p, $s, (New-Object System.Text.UTF8Encoding($false)))` |
| **`run_tests.ps1` 被执行策略拦** | `CurrentUser: RemoteSigned`。直接调 Godot 更省事 |
| **`Get-Content` 默认按 GBK 读** | 看 UTF-8 中文会乱码，那是**显示问题**不是文件损坏 |
| **`@tool` 脚本的 `_ready` 在编辑器也跑** | 有副作用的（如 `Door` 的静态坐标登记）别设成 `@tool` |
| **`_get_property_list` 里读 autoload 不可靠** | autoload 的 `_ready` 可能还没跑 → 下拉是空的。**直接读 JSON 文件** |

### 设计约定（违反会静默失效）

1. **可点物件必须是 `World` 的*直接*子节点**
2. 每类家具挂对应脚本
3. **椅子是 `Table` 的子节点**
4. 装饰物（地板、柜台本体）**不进 `World`**
5. 贴图 `Sprite2D` **取消 `Centered`**（否则贴图和碰撞盒差半个身位）
6. 家具碰撞 **Layer = `world`(1)、Mask = `waiter`(2)**（反了服务员就直接穿过去）

---

## 五、下一会话开场建议

1. 先跑一次 `report_scene.gd` 看当前场景结构（确认上一轮的改动都在）
2. 如果 MCP 已接上 → 用 `mcp__godot__*` 工具操作 Godot，不用再靠"改文件 + 重启"
3. 如果没有 MCP → 继续按"你给我数据、我改代码；我改代码、你在编辑器操作"的分工

**协作边界（你明确要求过的）**：
- **你**：`scenes/*.tscn`、`project.godot`、素材导入设置、编辑器里的任何操作
- **我**：`scripts/**.gd`、`tools/**.gd` 代码文件
- **改前先问**：数据文件（`data/*.json`）、以及**你 profile 里的 DSH 配置**
