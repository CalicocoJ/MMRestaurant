extends RefCounted
class_name RouterResult
## 点击的结果码。
##
## 【为什么单独一个文件，而不是塞在 ClickRouter 里】
## WorldObject（所有可点击物件的接口约定）要用这些返回值，
## 而 ClickRouter 又要遍历那些物件 —— 两边互相引用会形成循环依赖，
## GDScript 的解析器会直接报「找不到成员」。
## 把枚举提到一个谁都不依赖的文件里，循环就断了。
##
## （这个坑很隐蔽：报错信息是「Cannot find member "NOTHING"」，
##  看起来像枚举写错，实际是解析顺序问题。）

enum {
	ACCEPTED,   ## 已下单，服务员开始走过去
	NO_ACTION,  ## 点了但没反应（通常伴随原地飘字）
	FAILED,     ## 动作在到达时被取消（到达时再检查没通过）
	OPENED_UI,  ## 这个动作导致了弹窗
}
