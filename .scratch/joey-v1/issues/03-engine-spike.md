# 03 SSH 引擎 spike(可跑通的最小验证)

Type: prototype
Status: claimed
Blocked by: 01

## Question

按 01 的选型,在 joey 仓库里搭最小 spike(可以是临时 executable target),证明所选 C 栈在 macOS 14 arm64 上真的满足核心路径:连接 + 密码认证 + 密钥认证(ed25519)+ 列目录(>100 条不截断)+ 上传/下载各一个大文件(≥500MB)带字节级进度回调 + 干净取消。agent 写代码,用户构建运行并回报结果。通过后该 spike 的 API 形状即 `SSHEngine` 的雏形;不通过则回到 01 换路线。

## Comments

**2026-08-19 / agent** — spike 代码已落仓,等用户构建运行:

- `Vendor/build-libssh.sh`:按 01 号研究清单产出 `Vendor/libssh.xcframework`(OpenSSL 静态 libcrypto + libssh 0.12.2 fat dylib,install name `@rpath/libssh.dylib`,改 id 后 ad-hoc 重签)。前置:Xcode CLT + cmake + curl。
- `Package.swift` + `Sources/JoeySpike/`:`joey-spike` CLI。`SpikeEngine.swift` 即 `SSHEngine` 雏形——connect(含 known_hosts 校验)/password+key 认证/listDirectory/upload/download/removeFile,进度回调返回 `false` 即干净取消(抛 `cancelled`,会话保持可用)。传输是同步分块循环(默认 128KB,按服务器 `sftp_limits()` 收缩);若回报吞吐不足,已知备选是 `sftp_aio_*` 流水线。

运行清单(在 mac 上):

1. `./Vendor/build-libssh.sh`(下载完成后会立即打印两个 tarball 的 SHA-256,对照官网核验)
2. `swift build`
3. 全量验证(密码 + ed25519 密钥都给上,两种认证一次跑完):
   `JOEY_PW=<密码> .build/debug/joey-spike check --host <h> --user <u> --password-env JOEY_PW --key ~/.ssh/id_ed25519 --accept-unknown`
   - 密钥带口令加 `--ask-key-passphrase`;
   - `--list-dir` 默认 `/usr/bin`(需 >100 条目),`--remote-dir` 默认 `/tmp`(需可写);
   - 500MB 测试文件自动生成于本地 tmp;`check` 内含上传、下载各一次自动取消测试(默认 64MB 处),Ctrl-C 亦可随时手动验证取消;只给一种认证方式时结果会标注 PASS with skips。
4. 回报:各步 PASS/FAIL、上传/下载 MB/s、cancel 毫秒数、有无异常输出。全 PASS 即 resolve 本票;传输速度不理想也请注明(决定要不要上 AIO)。
