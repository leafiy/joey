# 04 leafiy-ui 通用拖放组件 API

Type: prototype
Status: claimed

## Question

家族首次出现的两项能力要以通用组件进 leafiy-ui(用户拍板,符合其 ADR-0006):

1. **拖入**:视图级 drop 目标(接收 Finder 文件 URL,高亮反馈)+ menubar 图标级 drop(NSStatusItem/MenuBarExtra 接收拖放)。
2. **拖出**:file-promise 拖出源(`NSFilePromiseProvider`)——行内拖出时先承诺文件名,落盘时通过异步回调向调用方索要内容(joey 场景 = 此时才从远端下载)。

问题:这两个组件的 API 长什么样(SwiftUI modifier?回调签名?进度/取消怎么穿过 file promise?),放 LeafiyUI 哪个位置,demo 怎么写。产出 API 草案 + leafiy-ui 内的可编译原型,用户过目定稿。此答案解锁 05 面板 UI。

## Comments

**2026-08-19 原型已就绪,待用户过目**(asset:leafiy-ui 分支 `prototype/drag-drop-components`,commit `7d11c17`):

- API 草案:`docs/drafts/drag-and-drop-api.md`(该分支上)。
- 三个组件(`Sources/LeafiyUI/`):
  - `FileDropTarget.swift` — `leafiyFileDrop(isTargeted:perform:)` + 家族标准高亮 `leafiyDropHighlight(_:)`,薄封装 SwiftUI `onDrop`,仅收 `.fileURL`,主线程整批回调。
  - `MenuBarDropTarget.swift` — `LeafiyMenuBarDropTarget(onDrop:).activate()`;因 `MenuBarExtra` 不暴露 `NSStatusItem`,通过定位本 app 的 status-bar window 在按钮上盖透明 drop 层,1s 轮询在图标模式切换后重挂。
  - `FilePromiseDragSource.swift` — `LeafiyFilePromise(filename:contentType:write:)` + `leafiyFilePromiseDragOut(_:)`;AppKit `NSFilePromiseProvider`,`write` 为 async 回调,落盘时才被调用,携带已 publish 的 `Progress`(Finder 显示进度条,⨯ 取消 → Task 取消)。
- Demo:该分支 template-app 的 Business Page 换成演示页(drop 区、menubar 拖放、即时/慢速 200MB/点击穿透三行 promise 拖出、SwiftUI `.onDrag` 对照行 Variant B、事件日志)。用户自行构建:`cd template-app && ./build-app.sh`。

**待用户验证/拍板的四个问题**(详见草案文末):
1. menubar 挂载在真机 macOS 14/15 是否成立(投递、点击穿透开菜单、模式切换后重挂)。
2. 拖出行的点击是否还能到达下层 `onTapGesture`(demo 第三行);不行则 05 的浏览器行激活方式要改或 API 加 `onTap:`。
3. Variant B(纯 SwiftUI 懒 file representation)若真惰性可用,弃 AppKit 方案。
4. 多选拖出暂缓,joey 需要时再扩。
