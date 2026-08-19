# 04 leafiy-ui 通用拖放组件 API

Type: prototype
Status: resolved

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

## Answer

**已定稿并合入 leafiy-ui main(commit `400aef5`),决策记 leafiy-ui `docs/adr/0009`。** 三个组件,两轮真机验证全过:

1. **拖入**:`leafiyFileDrop(isTargeted:perform:)` + 家族标准高亮 `leafiyDropHighlight(_:)`——薄封装 SwiftUI `onDrop`,仅 `.fileURL`,主线程整批回调。高亮独立成 modifier,面板整体高亮与文件夹行落点可分开表达(05 直接可用)。
2. **menubar 图标拖入**:`LeafiyMenuBarDropTarget(onDrop:).activate()`——定位本 app status-bar window、按钮上盖透明 drop 层,点击穿透开菜单,1s 轮询在 Dock↔menubar 模式切换后重挂。真机验证:投递、点击、重挂全部成立。
3. **拖出(file promise)**:`LeafiyFilePromise(filename:contentType:write:)` + `leafiyFilePromiseDragOut(_:)`——**引擎定为纯 SwiftUI**:`.onDrag` + 惰性 `NSItemProvider` file representation。真机验证:真惰性(落盘才调 `write`)、Finder 显示进度条、取消干净、与 `onTapGesture` 天然共存。`write` 为 async 回调,收 destination URL + `Progress`(joey 在此从远端下载),取消经 Task cancellation。
   - **知情接受的代价**(用户拍板):先写启动卷临时目录、系统再拷到落点——大文件双份 I/O + 临时空间。
   - **备胎**:AppKit `NSFilePromiseProvider` 直写落点方案已同样验证可用(含 `onTap:` 点击方案),存于 prototype 分支历史 commit `4c4c399`,代价咬手时可切换。
4. **关键教训**:SwiftUI `onTapGesture` 无法与 AppKit 鼠标覆盖层叠加(手势独占鼠标、行拖不动)——这是弃 AppKit 引擎的直接推手之一。
5. **暂缓**:多选拖出(多 dragging item),joey 需要时再扩。

Assets:leafiy-ui 分支 `prototype/drag-drop-components`(API 草案 `docs/drafts/drag-and-drop-api.md` + template-app demo,最终 commit `83cf2c1`)。
