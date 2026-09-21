# 餐品图片放这里

把图片按**餐品 id** 命名丢进这个目录，游戏会自动用它替换占位色块。**代码一行都不用改。**

```
assets/items/burger.png     → 汉堡
assets/items/fries.png      → 薯条
assets/items/cola.png       → 可乐
```

支持的扩展名：`.png`、`.webp`、`.jpg`（按这个顺序查找）。

## 会自动生效的四处

| 位置 | 现在 | 放了图之后 |
|---|---|---|
| 订单票上菜名前的色块 | 红/黄色块 | 小图标 |
| 后厨 UI 的菜品按钮 | 色块 | 小图标 |
| 出餐口里放着的那份餐 | 色块 | 图片 |
| 服务员手上端着的那份餐 | 色块 | 图片 |

**可以一张一张慢慢换** —— 找不到图的餐品自动退回 `data/menu.json` 里的 `color` 色块，
所以中途不会出现空白。

## 建议尺寸

- 出餐口 / 服务员手上：约 **22×22 px**
- 订单票 / 后厨按钮：约 **11~18 px**

同一张图会被缩放到各处。画成**正方形、主体居中**最稳。

## 想换成别的目录或指定具体文件

用 `ItemArt.override`（优先级高于自动查找）：

```gdscript
ItemArt.override = {
    "burger": preload("res://art/my_burger.png"),
}
```

## 新增一道菜

1. 在 `data/menu.json` 的 `kitchen_items` 或 `drink_items` 里加一条（要有唯一 `id`）
2. 把图片按那个 `id` 命名放进本目录

后厨 UI、订单票、饮料机 UI 都会自动多出这一道菜。详见 `README.md`。
