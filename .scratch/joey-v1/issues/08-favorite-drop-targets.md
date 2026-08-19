# 08 收藏远程目录与 Icon Drop 新动线

Type: task
Status: resolved
Blocked by: 07

## Question

用户新增需求(2026-08-19),推翻 map「目录收藏属新效力」的 out-of-scope 判定:

1. 设置里可配置**收藏**(Favorite):远程地址(Host Record)+ 远程目录,最多三个。
2. Icon Drop 动线改为:拖文件悬停 menubar 图标时——有收藏 → 弹出收藏落点面板,直接投放到对应主机目录;无收藏 → 弹出主面板(落到 Browser)。原「落到 Active Host 的 Last Browsed Directory」语义废除。

CONTEXT.md 的 Icon Drop 词条与新词 Favorite 随本票更新。

## Answer

**已实现(2026-08-19),随 07 一并等真机验证。**

- **模型**:`Favorite`(hostID + directory,`maxCount = 3`),存 settings.json;`normalized()` 截断超额并清理指向已删主机的收藏。设置新增 **Favorites** 页(host Picker + 目录输入,超三禁用添加)。
- **动线**:`LeafiyMenuBarDropTarget.onDragChanged`(leafiy-ui 新增)驱动——悬停进入图标:有收藏 → `FavoriteTrayController` 用 `LeafiyFloatingPanel` 在图标下方弹 **Favorite Tray**(每收藏一行 drop 目标,拖上即传对应主机目录);无收藏 → 若面板未开则模拟点击 status item 打开 `.window` 面板。悬停离开按宽限时间收起(拖进 Tray 行内会取消收起)。
- **兜底**:文件直接松在图标上(没进 Tray/面板)→ 传第一个收藏;无收藏 → Active Host 的 Last Browsed Directory(与打开的面板当前目录一致)。
- **词汇**:CONTEXT.md 已更新 Icon Drop,新增 Favorite、Favorite Tray。
