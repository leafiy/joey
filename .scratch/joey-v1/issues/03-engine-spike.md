# 03 SSH 引擎 spike(可跑通的最小验证)

Type: prototype
Status: open
Blocked by: 01

## Question

按 01 的选型,在 joey 仓库里搭最小 spike(可以是临时 executable target),证明所选 C 栈在 macOS 14 arm64 上真的满足核心路径:连接 + 密码认证 + 密钥认证(ed25519)+ 列目录(>100 条不截断)+ 上传/下载各一个大文件(≥500MB)带字节级进度回调 + 干净取消。agent 写代码,用户构建运行并回报结果。通过后该 spike 的 API 形状即 `SSHEngine` 的雏形;不通过则回到 01 换路线。
