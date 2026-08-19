# 06 Joey 图标

Type: prototype
Status: resolved

## Question

Joey 的 app icon 与 menubar 模板图标(`LeafiyMenuBarIconFile`)长什么样。走家族流程:出几版草案(用 `leafiy-ui/scripts/compile-macos-app-icon.sh` 兼容的源图),menubar 图标须适配 Status-Dot 状态渲染。用户挑选定稿。

## Comments

**2026-08-19 草案已就绪,待用户挑选**(asset:[icon-drafts.html](../assets/icon-drafts.html),浏览器直接打开):

- 本机无图像生成工具,草案以 Canvas 按 ICON_CONTRACT 精确几何绘制:app 1024(squircle 100–923、artwork ≤640)、menubar 640(squircle 63–576、artwork ≤400),白 squircle + 柔和投影对齐 daisy 观感;调色 = 袋鼠橙 `#F08A3C` + 家族蓝 `#3B82F6`。
- 页面内含 18pt 菜单栏实际大小模拟(浅/深菜单栏 × Status-Dot 闲/忙/成/败四态,复刻 LeafiyDesign 几何)和契约参考线开关;挑中后一键导出的两个 PNG 即 `compile-macos-app-icon.sh` 与 `LeafiyMenuBarIconFile` 的合法输入。
- **四个方向**:1 口袋 Pouch(托盘收箭头,直指 Drop 动作)/ 2 几何袋鼠 Joey(吉祥物,袋里探出蓝文件)/ 3 跳跃传输 Hop(文件沿虚线弧跳进文件夹)/ 4 J 字袋 Monogram(J 下钩即口袋 + 入袋箭头)。
- 定稿后落位沿 daisy 模式:仓库根 `joey.png`(1024)+ `Sources/Joey/Resources/Icons/joey.png`(640),`Info.plist` 设 `LeafiyMenuBarIconFile`——归实施票。

**待用户拍板**:选哪个方向(或指定改动:配色、粗细、构图);18pt 下是否够辨识、Status-Dot 右下角是否打架。

## Answer

**已定稿(2026-08-19):图标由用户亲自出图,agent 草案全部落选。** 用户将自行提供两张源图,须满足 ICON_CONTRACT:app 1024×1024(白 squircle 100–923,artwork ≤640 居中)、menubar 640×640(squircle 63–576,artwork ≤400),menubar 图右下角为 Status-Dot 留出余地。落位沿 daisy 模式:仓库根 `joey.png`(1024)+ `Sources/Joey/Resources/Icons/joey.png`(640),`Info.plist` 设 `LeafiyMenuBarIconFile`——接线归实施票;实施票在源图就位前用占位图不阻塞构建。草案板 [icon-drafts.html](../assets/icon-drafts.html) 保留作契约几何与 18pt Status-Dot 模拟的校验工具(可用来预检自绘源图)。
