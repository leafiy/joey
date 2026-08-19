# joey

常驻 menubar 的 SSH/SFTP 远程文件管理器(leafiy 家族,基于 leafiy-ui)。

- **面板即浏览器**:左键 menubar 图标打开 360×520 面板——Host Switcher、面包屑、单列远程目录;拖文件进面板上传(空白=当前目录,文件夹行=进该文件夹),文件行拖出到 Finder 落盘时才真正下载(file promise)。
- **Icon Drop**:把文件直接拖到 menubar 图标——配置了收藏(Favorite,最多三个:主机 + 远程目录)时弹出 Favorite Tray 直接投放;没有收藏则打开主面板。
- **传输**:基础走 sftp(libssh);密钥认证主机且远端有 rsync 时自动用 rsync 加速;远端缺 rsync 可在面板一键安装(sudo 密码明示走 stdin)。失败反馈只有 menubar Status-Dot 错误态 + 面板 Error Banner,零弹窗零系统通知。
- **文件管理**:删除(带确认)、重命名、新建文件夹,仅此三样。

## 构建(在 mac 上,由用户执行)

```sh
./Vendor/build-libssh.sh   # 一次性:产出 Vendor/libssh.xcframework(libssh 0.12.2 + 静态 libcrypto)
sh build-app.sh            # 产出 build.noindex/app/Joey.app
```

`joey-spike`(ticket 03 引擎 spike CLI)仍可用:`swift build && .build/debug/joey-spike --help`。

> 图标:仓库根 `joey.png`(1024)与 `Sources/Joey/Resources/Icons/joey.png`(640)目前是**占位图**(暂借 daisy 源图保证几何合规),等待用户按 ICON_CONTRACT 提供 Joey 正式源图后原位替换即可。

## 隐私

按家族 ADR-0002 不用 Keychain:主机密码与私钥口令**明文**保存在 `~/Library/Application Support/Joey/settings.json`;joey 只与你配置的 SSH 主机通信;拖出的文件先落本机临时目录再由 Finder 复制。主机密钥按 `~/.ssh/known_hosts` 校验(首次信任并记录,变更即阻断)。

词汇表见 `CONTEXT.md`,工程决策见 `docs/adr/`,预研见 `docs/research/`。
