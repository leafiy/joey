# 01 SSH C 库选型与 SwiftPM 打包

Type: research
Status: resolved

## Question

已定走 libssh 系 C 栈(joey ADR-0001),但具体选哪个、怎么打包未定。回答:

1. **libssh vs libssh2**:对 joey 的需求集(SFTP 上传/下载带进度回调、ls、mkdir、rename、delete;密码 + ed25519/RSA/ECDSA 密钥认证,密钥可带口令;known_hosts 式主机密钥校验)哪个覆盖更好?mft 项目(mplpl/mft,libssh 0.11 + OpenSSL 3.3 的 xcframework)可否直接采用或借鉴其构建方式?
2. **打包方式**:SwiftPM 下如何集成——自建 xcframework 作 `binaryTarget`,还是 C 源码作 SwiftPM C target 从源编译?crypto 后端怎么选(OpenSSL/mbedTLS/系统)?通用二进制(arm64+x86_64)怎么产出?给出用户可执行的构建步骤清单(本机不允许执行构建)。
3. **许可证**:libssh 是 LGPL-2.1——动态链接义务对 Developer ID 直发+公证的 .app 意味着什么,合规做法是什么?libssh2(BSD-3)无此负担但功能差距多大?
4. **公证**:所选方案在 hardened runtime + notarytool 下有无已知坑。

产出:明确推荐(库 + 打包路线 + 许可证合规做法)+ 用户构建步骤,写入 `docs/research/ssh-c-library-packaging.md`。此答案解锁 03 引擎 spike。

## Answer

详见 [docs/research/ssh-c-library-packaging.md](../../../docs/research/ssh-c-library-packaging.md)。要点:

1. **选 libssh(0.12.2),不选 libssh2**:libssh 原生覆盖全部需求——OpenSSH 格式带口令密钥(含 ed25519,全 crypto 后端)、`ssh_session_is_known_server` 枚举式 known_hosts、ssh-agent、0.11+ 的 SFTP AIO 流水线,维护活跃。libssh2 虽是 BSD-3,但 ed25519/OpenSSH 密钥仅限 OpenSSL 后端、known_hosts API 繁琐、更新缓慢(最新 1.11.1,2024-10)。
2. **打包**:静态 OpenSSL(libcrypto)链入单个 `libssh.dylib` → 本地 xcframework 作 SwiftPM `binaryTarget`(SE-0272 支持本地路径)+ 薄 Swift wrapper target;dylib 随 .app 进 `Contents/Frameworks/` 动态分发。mft 只借鉴其 Swift API 形状,不采用其打包(仅预编译静态库、无构建脚本,静态链还会触发 LGPL 重链接义务)。
3. **LGPL-2.1 合规**:走 §6(b) 动态链接——bundle 附 LGPL 全文 + 显著声明、托管对应 libssh 源码、EULA 允许逆向调试;主程序加 `com.apple.security.cs.disable-library-validation` entitlement(否则 hardened runtime 拒载用户替换的 dylib,违背 6(b)(2);公证不拒此 entitlement)。
4. **公证**:无已知硬坑;文档含用户可执行的完整构建/签名清单。**头号风险**:CMake 单次产出双架构时特性探测只跑宿主架构——异常则退回按架构分编 + `lipo`。另注意两库都没有内建进度回调,需自分块读写循环——spike 03 必须验证 500MB 传输 + 进度 + 取消。
