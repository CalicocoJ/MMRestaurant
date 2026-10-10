extends Resource
class_name GuestSkin
## 一套客人「外表」的数据包。
##
## 【为什么不直接挂 SpriteFrames】以后客人会需要更多跟外表绑定的东西：
##   - 碰撞盒大小（胖客人 / 小孩体型不同）
##   - 头像（订单票上想显示是谁点的）
##   - 说话音效 / 走路脚步声
##   - 出现权重（小孩少见、上班族常见）
## 这些都属于「皮肤」而不是「客人逻辑」。有一个资源类做落点，
## 以后加字段只要在这里加一行 `@export`，**已有的 .tres 不用返工**。
##
## 【怎么造一份】文件系统面板右键 → 新建 → 资源 → 搜 `GuestSkin` → 保存为
## `.tres`，然后在检查器里把 SpriteFrames 拖进 `sprite_frames`。
##
## 【⚠️ SpriteFrames 不能靠"共用动画名"省事】
## 帧数据（AtlasTexture 的区域）是内嵌在各自的 .tres / .tscn 里的：
## 4 套皮肤 = 4 份独立的帧数据。所以「不同角色」必须各自一份 SpriteFrames。

## 这套皮肤用哪份帧动画（8 个动画名的约定见 guest.gd）。
@export var sprite_frames: SpriteFrames = null

## 皮肤名，**仅供调试输出**。
##
## 【为什么说明白"仅供调试"】客人头顶**故意不显示任何文字**
## （只显示耐心环和 ! 号，菜名在左侧订单票上）—— 见 customer_manager.gd
## 和 guest.gd 里的说明。所以这个名字现在只会出现在日志/调试工具里，
## 别指望界面上能看到它。
@export var display_name: String = ""


## 这套皮肤能不能用（帧一份都没有的皮肤挂上去就是个隐形客人）
func is_valid() -> bool:
	return sprite_frames != null
