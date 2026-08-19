# Vendor

`libssh.xcframework` 放这里,由 `./build-libssh.sh` 在 mac 上构建(本仓库不提交构建中间物,`_work/` 已 gitignore)。构建产物本身建议在验证通过后提交,克隆者即可直接 `swift build`。

- 选型、打包路线、LGPL-2.1 合规与完整构建清单:见 [docs/research/ssh-c-library-packaging.md](../docs/research/ssh-c-library-packaging.md)(ticket 01 的答案)。
- 结构:单一 `macos-arm64_x86_64` slice —— fat `libssh.dylib`(静态吸收 libcrypto,install name `@rpath/libssh.dylib`)+ headers + `module.modulemap`(模块名 `CLibssh`)。
- 升级 libssh:改脚本顶部版本号重跑,并保留对应源码 tarball(LGPL 源码提供义务)。
