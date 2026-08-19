# SSH 引擎用薄 Swift 封装 + libssh 系 C 栈

joey 的核心是「绝不能丢文件」的 SFTP 传输与流畅目录浏览。三条路线里选了 C 栈(libssh 或 libssh2,由预研定):纯 Swift 的 Citadel 在核心路径上有硬伤(目录列表 100 条截断、流式读取慢且有正确性问题、无 ECDSA、无 ssh-agent、底层挂在过时的 swift-nio-ssh fork);系统 `/usr/bin/ssh`/`sftp` 子进程做不了密码认证、进度靠解析 stdout、浏览器响应差。所有严肃的 macOS 传输应用(Transmit、QSpace、旧 ForkLift)走的都是 C 栈。代价:打破家族零外部依赖惯例(此为有意为之),需自行处理打包与(libssh 时)LGPL 合规。rsync 仍是系统二进制,其 ssh 命令行由同一份 Host Record 生成,避免双链路配置分裂。

**Consequences**: 家族若再有 SSH 需求,应复用 joey 沉淀的封装而非再引一套。Citadel 到 1.0 且回归上游 swift-nio-ssh 后可重评。
