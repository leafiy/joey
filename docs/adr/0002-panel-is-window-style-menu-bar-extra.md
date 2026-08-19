# 面板用 window 样式 MenuBarExtra,家族 Menu Tail 收进 Gear Menu

家族标准 `LeafiyMenuBarExtra` 固定 `.menu` 样式,但 joey 的核心动线是「点击图标 → 面板即 Browser」:菜单样式装不下目录列表与拖放;浮动窗方案(保持 `.menu`,由菜单项唤起面板)多一次点击、弱化常驻文件管理器的心智;右键图标出菜单则要下探 NSStatusItem 层,与 `LeafiyMenuBarDropTarget` 的透明覆盖层(Icon Drop 所依赖)纠缠。故 joey 作为 Explicit Exception 直接用 `.window` 样式 MenuBarExtra:左键开面板,家族 Menu Tail(Settings… / 检查更新 / Quit)完整收进面板工具条右侧的 Gear Menu,不裁剪任何家族标准项。

**Consequences**: joey 不套用 `LeafiyFamilyMenu`,Gear Menu 须随家族 Menu Tail 标准同步演进。家族若出第二个面板型应用,应把「window 样式 + Gear Menu」沉淀回 leafiy-ui 而非各自再造。
