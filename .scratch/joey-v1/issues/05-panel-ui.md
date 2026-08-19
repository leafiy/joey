# 05 面板 UI 定稿

Type: prototype
Status: claimed
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
