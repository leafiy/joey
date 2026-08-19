# 05 面板 UI 定稿

Type: prototype
Status: resolved
Blocked by: 04

## Question

menubar 面板的具体样子:Active Host 切换器放哪(顶部下拉?),面包屑 + 单列列表布局,拖入时的落点高亮(整面板 vs 文件夹行),Error Banner 形态,删除(带确认)/重命名/新建文件夹三个操作的入口(右键菜单?行内按钮?),空状态与未配置主机状态。按家族 Standard Components(LeafiyCard/EmptyStateView/ControlBar 等)出可编译原型,用户过目定稿。

## Comments

**2026-08-19 原型已就绪,待用户过目**(asset:leafiy-ui 分支 `prototype/joey-panel-ui`,commit `abf76fa`):

- 沿用 04 的方式:template-app Business Page 换成原型页,360×520 模拟面板,底部浮动条 ←/→(或方向键)切三个变体,分段控件切 Browse / Error / Empty / No Host 四种状态。构建:切到该分支后 `cd template-app && ./build-app.sh`。
- 拖放是真的(leafiyFileDrop / leafiyDropHighlight,从 Finder 拖文件即见高亮);文件行可用 stub file promise 拖出;删除走 confirmationDialog、新建/重命名走带输入框的 alert;所有动作以 toast 报告"joey 会做什么"。
- **三个变体(结构性差异,可拼装)**:
  - **A — Toolbar + context menus**:顶部工具条(Active Host 下拉 + 新建文件夹按钮),下方面包屑行,Error Banner 为列表上方红色横条;操作入口 = 行右键菜单;整列表 + 文件夹行双层落点高亮。
  - **B — Back button + hover actions**:紧凑标题行(‹ 返回 + 当前目录名下拉出完整路径),Active Host 放底部 FooterBar;行 hover 显示重命名/删除按钮;列表下方常驻虚线"Drop files to upload"条作为整目录落点,文件夹行单独高亮;Error Banner 为悬浮卡片盖在列表顶部。
  - **C — Selection + control bar**:顶部 LeafiyCard(Host 选择器 + 路径行),行单击选中,底部 ControlBar 按选中态启用 New Folder / Rename / Delete;仅整面板一个落点高亮(不做行级);Error Banner 为红色圆角卡片。

**待用户拍板**:
1. 选哪个变体为基底,或指定拼装("要 A 的面包屑 + B 的 hover 按钮"这类反馈最有用)。
2. 落点高亮:整面板、文件夹行、还是 B 的专用 drop 条?
3. Error Banner 三种形态(内嵌横条 / 悬浮卡 / 卡片)选一。
4. 文件操作入口:右键菜单(A)/ hover 按钮(B)/ 选中 + 底部栏(C)。
5. Active Host 位置:顶部(A/C)还是底部 Footer(B)。

## Answer

**已定稿**(原型真机验证通过后,剩余问题口头拍板,2026-08-19):骨架 = **变体 A**,逐轴确认如下——

1. **Active Host** = 顶部工具条左侧下拉(定名 **Host Switcher**,见 CONTEXT.md),列全部 Host Record + Configure Hosts… 入口。
2. **导航** = 独立面包屑行:点任意段跳转、深路径横向滚动;不加返回按钮(点父段即返回);**双击**进入文件夹(与拖出/未来多选共存已验证)。
3. **落点高亮** = 双层:文件夹行精确落点 + 列表空白 = 当前目录,与 Panel Drop 词义一一对应;用家族 `leafiyDropHighlight`。不采用 B 的常驻 drop 条。
4. **Error Banner** = 内嵌红色横条(⚠ 图标 + 单行概要 + ⨯ 关闭),位于面包屑与列表之间,推开内容不悬浮。
5. **文件操作入口** = 仅行右键菜单(Rename… / Delete… / New Folder…);新建文件夹另有工具条 `folder.badge.plus` 按钮;无 hover 按钮、无选中态、无底部 ControlBar。
6. **排序** = 文件夹在前、按名称;dotfiles 始终显示,v1 不做开关。
7. **尺寸** = 固定 360×520,不可调。
8. **呈现机制** = MenuBarExtra `.window` 样式,左键图标直接开面板;家族 Menu Tail 收进工具条右侧 **Gear Menu**——对家族 `.menu` 标准的 Explicit Exception,记 **joey ADR-0002**。
9. **对话框与状态** = 删除走 confirmationDialog、新建/重命名走带输入框 alert;空目录 = EmptyStateView(「Drop files here to upload」),未配置主机 = EmptyStateView + Open Settings… 按钮,均照原型。

Assets:leafiy-ui 分支 `prototype/joey-panel-ui`(commit `abf76fa`)——A 为定稿基底,落选的 B/C 变体与状态模拟器留在该分支作 primary source。新词 Host Switcher / Gear Menu 已入 CONTEXT.md;呈现机制决策见 `docs/adr/0002`。
