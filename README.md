# 餐厅物语

一个餐厅时间管理小游戏。你扮演服务员，**只用鼠标左键**点场景里的东西：
点客人接单、点后厨下单、点出餐口取餐、走到客人身边上菜、点脏桌收拾。
点完服务员会自己走过去，**到了才动手** —— 跑腿时间就是这个游戏的压力来源。

**Godot 4.7.2**，2D，1280×720，占位美术，一关一局（5 关，每关 3 档星级）。

> 详细功能规格见 **`SPEC.md`**，当前进度与已知问题见 **`PROGRESS.md`**。

---

## 拿到工程后怎么跑

1. 装 **Godot 4.7.x**（标准版即可，不需要 .NET/C# 版）：<https://godotengine.org/download>
2. `git clone <仓库地址>`，或用网页上的 *Download ZIP* 解压
3. 打开 Godot → **Import** → 选中工程根目录的 **`project.godot`**
4. 按 **F5** 运行（主场景是 `scenes/main.tscn`）

> 首次打开时 Godot 会自己生成 `.godot/` 缓存目录（已加进 `.gitignore`，不用管）。

### 跑一遍工程自带的体检

工程里有 30+ 个体检脚本（寻路、碰撞、星级判定、HUD 布局…），都用无头模式跑：

```powershell
# Windows PowerShell：脚本会自己找 Godot（先看 $env:GODOT，再看 PATH，再看常见安装位置）
.\tools\run_tests.ps1

# 找不到 Godot 时，显式指定 console 版 exe：
.\tools\run_tests.ps1 -GodotPath "D:\Godot\Godot_v4.7.2-stable_win64_console.exe"
```

也可以直接用 Godot 命令行跑单个体检（`tools/` 下每个 `.tscn` 就是一个）：

```powershell
godot --headless --path . res://tools/check_level_mode.tscn
```

**注意**：`tools/run_tests.tscn` 那套是开发早期写的，里面有 12 项断言停留在旧设计上
（旧坐标、旧时序），现在一直是 206 通过 / 12 失败的状态；**判断有没有回归请看
`tools/` 下那些专门的体检脚本**，它们都是全绿。详见 `PROGRESS.md` 的「已知问题」。

---

## 目录结构

```
restaurant-v2/
├── project.godot          工程配置（autoload、字体、分辨率）
├── scenes/main.tscn       唯一场景：一个挂脚本的根节点，其余由代码搭
│
├── data/                  ★ 所有可调项，改它不用碰代码
│   ├── config.json            关键数值（耐心、速度、时长、容量、随机性权重）
│   ├── levels.json            关卡表（时长 + 3 档星级门槛）
│   ├── menu.json              菜单（后厨餐品 / 饮品、价格、占位色）
│   └── layout.json            场景布局（每个物件的坐标与尺寸、座位、站位点）
│
├── scripts/
│   ├── core/              配置、对局状态、订单、后厨、点击路由、寻路、餐品外观接口
│   ├── world/             家具：桌子、后厨窗口、饮料机、垃圾桶、门口
│   ├── actors/            服务员、客人
│   ├── level/             主场景搭建、地板、客人生成、座位分配
│   └── ui/                HUD、订单栏、弹窗、飘字、字体
│
├── assets/                字体资源；assets/items/ 放餐品图片（可选，见那里的说明）
├── tools/                 开发与验证工具（体检脚本、截图、数据统计，不影响游戏运行）
│
├── SPEC.md                功能规格（行为的权威描述）
└── PROGRESS.md            当前进度、待办、已知问题
```

## 想改点什么（常见入口）

| 想改 | 改哪里 |
|---|---|
| 难度 / 星级门槛 | `data/levels.json`（`time_limit` + 三个金额） |
| 客人耐心、走路速度、桌子数 | `data/config.json` |
| 菜价 / 加一道菜 | `data/menu.json`（加图片见 `assets/items/README.md`） |
| 家具位置、座位、站位点 | `data/layout.json` |
| 只调数值 | **不用碰代码**，改完存盘重启游戏即可 |
