# joey

常驻 menubar 的 SSH/SFTP 远程文件管理器(leafiy 家族,开发中)。

当前状态:ticket 03 引擎 spike——`joey-spike` 可执行目标验证 libssh 栈。构建:

```sh
./Vendor/build-libssh.sh   # 一次性:产出 Vendor/libssh.xcframework
swift build
.build/debug/joey-spike --help
```

词汇表见 `CONTEXT.md`,工程决策见 `docs/adr/`,预研见 `docs/research/`。
