# SSH C 库选型与 SwiftPM 打包(解 issue 01)

日期:2026-08-19。核实自一手来源:libssh.org / api.libssh.org、libssh2.org 及其 GitHub 源码、mplpl/mft 仓库、SwiftPM SE-0272 与 Apple 文档、LGPL-2.1 原文与 FSF FAQ、Apple 公证文档。

## 结论(推荐)

**选 libssh(当前稳定 0.12.2),crypto 后端用静态 OpenSSL(仅 libcrypto)链入 `libssh.dylib`,以本地 xcframework 作 SwiftPM `binaryTarget` 集成,动态库随 .app 的 `Contents/Frameworks/` 分发;LGPL-2.1 走 §6(b) 动态链接合规路线,并加 `com.apple.security.cs.disable-library-validation` entitlement。**

## 1. libssh vs libssh2

**libssh 0.12.x 原生覆盖 joey 全部需求**;libssh2 虽是 BSD-3,但功能与维护面均落后:

| 需求 | libssh 0.12.2 | libssh2 1.11.1 |
|---|---|---|
| SFTP 基本操作 | `sftp_opendir/readdir/mkdir/rename/unlink` 全有 | 有,等价 |
| 传输进度 | 无回调;自分块循环 `sftp_read/write` 上报;0.11+ 另有流水线 AIO(`sftp_aio_begin_read/write` + `sftp_limits()`)提吞吐 | 同样无回调;`libssh2_sftp_write` 需处理部分写,历史吞吐更差 |
| OpenSSH 格式私钥 + 口令(ed25519/RSA/ECDSA) | `ssh_pki_import_privkey_file` 全后端支持,含 PKCS#11 | **仅 OpenSSL/LibreSSL 后端**支持;mbedTLS 后端无 ed25519、RSA 只认 PEM(见 `src/mbedtls.c`) |
| known_hosts | `ssh_session_is_known_server` 返回 `SSH_KNOWN_HOSTS_OK/CHANGED/…` 枚举 + `ssh_session_update_known_hosts`,UX 直给 | `libssh2_knownhost_*` 可用但更繁琐 |
| ssh-agent | `ssh_userauth_agent` | `libssh2_agent_*` |
| 维护 | 0.12.2(2026-07-28),安全响应活跃 | 最新仍是 1.11.1(2024-10),近两年无 release |

来源:https://api.libssh.org/stable/group__libssh__sftp.html 、group__libssh__pki.html 、group__libssh__session.html 、group__libssh__auth.html;https://github.com/libssh2/libssh2/releases;https://raw.githubusercontent.com/libssh2/libssh2/master/src/mbedtls.c;https://www.libssh.org/

**mft(mplpl/mft)**:是 LGPL-2.1 的 Swift SFTP 封装框架(非 GUI),bundle 的是**预编译静态** `libssh.a` 0.11.0 + OpenSSL 3.3.1(`libssh/lib_macos/`、`openssl/lib_macos/`,universal)。它的 `build.sh` 只打包自身 xcframework,**仓库里没有 libssh/OpenSSL 的编译脚本**,静态库不可溯源,且静态链接 libssh 会触发 LGPL §6 重链接义务——mft 自身 LGPL 所以无碍,joey 闭源不能照抄。可借鉴其 `MFTSftpConnection.swift` 的 API 形状(进度回调、断点续传),不采用其打包方式。来源:https://github.com/mplpl/mft (README.md、build.sh)。

## 2. 打包路线

- **`binaryTarget(name:path:)` 指向仓库内 `.xcframework` 目录**(SE-0272 明确支持本地路径、免 checksum、免 zip),xcframework 含 `macos-arm64_x86_64` 一个 slice:fat dylib + headers + `module.modulemap`。binaryTarget 不能有依赖,用一个薄 wrapper target 暴露 C API。来源:https://github.com/swiftlang/swift-evolution/blob/main/proposals/0272-swiftpm-binary-dependencies.md 、https://developer.apple.com/documentation/xcode/distributing-binary-frameworks-as-swift-packages
- 否决「C 源码作 SwiftPM target」:libssh 的 `config.h` 由 CMake 特性探测生成,手工冻结不可维护。否决 `systemLibrary` + Homebrew:库不进 bundle、签名不是我们的,分发必挂。
- **crypto 后端**:macOS 无 OpenSSL 头文件,须自建。选**静态 universal libcrypto(Apache-2.0)链进 libssh.dylib**——对外只有一个 dylib,LGPL 只及 libssh;libssh COPYING 自带 OpenSSL 链接例外。mbedTLS 后端是最薄的一个(ECC 靠低层封装、历史贡献较晚),OpenSSL 是参考后端,亦是 mft/Transmit 生态实践。来源:https://www.libssh.org/features/ 、https://gitlab.com/libssh/libssh-mirror/-/raw/master/COPYING

### 用户构建步骤清单(本机不执行,由人跑)

1. **OpenSSL**(取 3.x LTS 源码,按架构各编一次再 lipo;Configure 不支持一次多架构):
   `./Configure darwin64-arm64-cc no-shared no-tests --prefix=$PWD/out-arm64 && make -j && make install_sw`;同法 `darwin64-x86_64-cc`(x86_64 一侧加 `CFLAGS=-mmacosx-version-min=14.0` 或用 arch 前缀);`lipo -create out-{arm64,x86_64}/lib/libcrypto.a -output universal/lib/libcrypto.a`,headers 取任一份。
2. **libssh 0.12.2**(CMake 支持一次产出 fat 二进制):
   ```
   cmake -B build -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
     -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_BUILD_TYPE=Release \
     -DBUILD_SHARED_LIBS=ON -DWITH_SERVER=OFF -DWITH_EXAMPLES=OFF \
     -DUNIT_TESTING=OFF -DWITH_GSSAPI=OFF \
     -DOPENSSL_ROOT_DIR=$PWD/../openssl/universal
   cmake --build build -j
   ```
3. **校验**:`lipo -info build/lib/libssh.dylib`(两架构);`otool -L`(只应引用系统库,不应出现 libcrypto——已静态吸收)。
4. **install name**:`install_name_tool -id @rpath/libssh.dylib build/lib/libssh.dylib`。
5. **xcframework**:staging 目录放 `libssh/*.h` + 手写 `module.modulemap`(`module CLibssh { header "libssh/libssh.h" header "libssh/sftp.h" link "ssh" export * }`);
   `xcodebuild -create-xcframework -library build/lib/libssh.dylib -headers staged-include -output Vendor/libssh.xcframework`。
6. **Package.swift**:`.binaryTarget(name: "CLibssh", path: "Vendor/libssh.xcframework")` + wrapper target 依赖之。
7. **App 装配**:dylib 拷入 `Joey.app/Contents/Frameworks/`(SwiftPM 可执行产物不会自动嵌入,打包脚本负责),主程序需有 `LC_RPATH @executable_path/../Frameworks`。
8. **签名/公证**:由内向外——先 `codesign --force --options runtime --timestamp -s "Developer ID Application: …"` 签 dylib,再签 .app(entitlements 含 `com.apple.security.cs.disable-library-validation`),`notarytool submit` + `stapler staple`。来源:https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle 、https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle 、https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
9. **留存**:保存与 dylib 完全对应的 libssh 源码 tarball(合规用,见下)。

## 3. LGPL-2.1 合规(闭源 + Developer ID + 公证)

libssh 是 LGPL-2.1,**无静态链接例外**(仅 OpenSSL 链接例外)。§6(b) 原文允许:用「合适的共享库机制」链接,条件是运行时加载用户系统上的副本、且**用户装入接口兼容的修改版后程序能正常运行**。合规做法:

1. 只动态链接,dylib 进 `Frameworks/`;
2. App 内(About/致谢 + bundle 内文件)显著声明使用 libssh、附 LGPL-2.1 全文;
3. 随发或托管该版本 libssh 完整源码(FSF FAQ #LGPLStaticVsDynamic:随 app 分发库二进制即须提供库源码,动态亦然);
4. EULA 明确允许为调试修改而做修改与逆向;
5. **加 `disable-library-validation` entitlement**:hardened runtime 默认开库校验,会拒载非同 Team ID 的替换 dylib,直接违背 §6(b)(2);该 entitlement 是普通 hardened-runtime 例外,**公证不拒**(硬性红线只有 `get-task-allow`)。LGPLv2.1 无反 tivoization 条款(那是 GPLv3)。
6. 若日后修改 libssh 源码,必须公开修改部分源码。

来源:https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt 、https://www.gnu.org/licenses/gpl-faq.html#LGPLStaticVsDynamic 、https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation 、https://developer.apple.com/documentation/security/hardened-runtime

## 4. 公证已知坑

均有解:所有分发的可执行体(含 dylib)须 Developer ID 签名 + secure timestamp;主程序开 hardened runtime,entitlements 只放主程序;dylib 放错目录会导致签名/公证失败;用 `notarytool`(altool 已退役)。来源同上 + https://developer.apple.com/documentation/security/resolving-common-notarization-issues

## 风险

- **CMake 一次多架构的特性探测只在宿主架构跑**:若产物异常,退回按架构各编一次 + `lipo -create`(iSSH2 模式,https://github.com/FyrbyAdditive/iSSH2)。
- **安全更新责任自负**:libssh 2026 年已多轮 CVE(0.12.1/0.12.2 均为安全版),需固化「换 tarball 重跑清单」流程。
- **进度/取消无现成回调**:两库皆需自分块循环;spike(issue 03)必须验证 ≥500MB + 字节级进度 + 干净取消,吞吐不够时上 `sftp_aio_*`。
- `disable-library-validation` 略降安全面(LGPL 合规的代价,业界通行)。
- SwiftPM 不会替可执行目标自动嵌入 binaryTarget 的 dylib——打包脚本是必需件,漏拷则运行时 dyld 报错。
