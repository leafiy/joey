# 04 leafiy-ui 通用拖放组件 API

Type: prototype
Status: open

## Question

家族首次出现的两项能力要以通用组件进 leafiy-ui(用户拍板,符合其 ADR-0006):

1. **拖入**:视图级 drop 目标(接收 Finder 文件 URL,高亮反馈)+ menubar 图标级 drop(NSStatusItem/MenuBarExtra 接收拖放)。
2. **拖出**:file-promise 拖出源(`NSFilePromiseProvider`)——行内拖出时先承诺文件名,落盘时通过异步回调向调用方索要内容(joey 场景 = 此时才从远端下载)。

问题:这两个组件的 API 长什么样(SwiftUI modifier?回调签名?进度/取消怎么穿过 file promise?),放 LeafiyUI 哪个位置,demo 怎么写。产出 API 草案 + leafiy-ui 内的可编译原型,用户过目定稿。此答案解锁 05 面板 UI。
