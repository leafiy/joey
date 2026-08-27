# joey

常驻 menubar 的 SSH/SFTP 远程文件管理器(leafiy 家族,基于 leafiy-ui)。

- **面板即浏览器**:左键 menubar 图标打开 360×520 面板——Host Switcher、面包屑、可用 Command/Shift 多选的远程列表;文件和文件夹都可单个或成组拖出到 Finder,也可右键下载到设置中的 Download Directory(默认 macOS Downloads)。
- **Icon Drop**:把文件直接拖到 menubar 图标——配置了收藏(Favorite,最多三个:主机 + 远程目录)时弹出 Favorite Tray 直接投放;没有收藏则打开主面板。
- **传输**:基础走 sftp(libssh),上传下载都用请求流水线,吞吐不再被单次往返延迟卡死。上传与下载连接中断时都自动重连并从已有字节续传,完成前分别保存在隐藏的 `.joeyupload`(远端)与 `.joeydownload`(本地)暂存项目中。密钥认证主机且远端有 rsync 时上传自动用 rsync 加速;远端缺 rsync 可在面板一键安装。
- **文件管理**:删除(带确认)、重命名、新建文件夹,仅此三样。

## 构建(在 mac 上,由用户执行)

```sh
./Vendor/build-libssh.sh   # 一次性:产出 Vendor/libssh.xcframework(libssh 0.12.2 + 静态 libcrypto)
sh build-app.sh            # 产出 build.noindex/app/Joey.app
```

`joey-spike`(ticket 03 引擎 spike CLI)仍可用:`swift build && .build/debug/joey-spike --help`。

> 图标:仓库根 `joey.png`(1024)与 `Sources/Joey/Resources/Icons/joey.png`(640)目前是**占位图**(暂借 daisy 源图保证几何合规),等待用户按 ICON_CONTRACT 提供 Joey 正式源图后原位替换即可。

## 发布

`release.sh` 会运行 release 测试，分别构建、签名并公证 Apple Silicon 与
Intel DMG，然后把源码和 GitHub Release 发布到
`git@github.com:leafiy/joey.git`，并把安装包及更新清单发布到
`https://leafiy.com/updates/joey.json`。

```sh
sh release.sh --prepare       # 版本号 patch +1、build +1；检查后提交
sh release.sh v0.1.1          # 发布指定版本

# 只验证本地打包，不推送或上传
PUBLISH_TO_LEAFIY=0 PUBLISH_TO_GITHUB=0 \
ALLOW_UNNOTARIZED=1 SIGN_IDENTITY=- sh release.sh v0.1.1
```

公开发布需要 Developer ID Application 证书、`daisy-notary` notarytool
钥匙串配置，以及已登录的 `gh`；也可通过 `GH_TOKEN` 登录 GitHub。
`LEAFIY_ADMIN_PASSWORD` 走 HTTPS 管理接口，未设置时默认走 leafiy.com
服务器 SSH 通道。`GITEA_TOKEN` 仅用于可选的内部 Gitea 镜像。

## 隐私

> 隐私:按家族 ADR-0002 不用 Keychain:主机密码与私钥口令**明文**保存在 `~/Library/Application Support/Joey/settings.json`;joey 只与你配置的 SSH 主机通信;文件或文件夹拖出时仅在落点接受后下载,右键下载直接写入配置的 Download Directory。中断下载会在目的目录保留隐藏的 `.joeydownload` 暂存项目用于自动续传;中断上传同样在远端目录保留 `.joeyupload` 暂存项目,手动取消则会清除。主机密钥按 `~/.ssh/known_hosts` 校验。

词汇表见 `CONTEXT.md`,工程决策见 `docs/adr/`,预研见 `docs/research/`。
