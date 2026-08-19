# Wayfinder map: joey v1

Label: wayfinder:map

## Destination

joey v1 可用:常驻 menubar 的 SSH/SFTP 远程文件管理器,在用户机器上可构建(`build-app.sh`),两大功能可用——(1) 拖任意文件到远程主机任意目录;(2) 超简单远程目录浏览器,可把远程文件拖出到本地。基础协议 sftp,远程有 rsync 时用 rsync 加速。地图携带执行:决策票走完后接实施票,直到 v1 成型。

## Notes

- **本机规则**:agent 只写代码,一切构建/运行/安装由用户执行。git pull/push 已预授权。
- **家族规范**:必须从 `leafiy-ui/template-app/` 起步(不许复制 daisy);遵守 `leafiy-ui/.agents/skills/leafiy-macos-apps/` + `leafiy-ui/docs/adr/`;`ADR-0002` 禁用 Keychain(机密明文存 settings.json,隐私文案明示);构建前过 `check-app-family-contract.sh`;macOS 14 floor,零外部依赖惯例被本效力有意打破(见 joey `docs/adr/0001`)。
- **范围覆盖两个仓库**:通用拖入/拖出组件进 `leafiy-ui`,joey 消费(用户拍板,符合 leafiy-ui ADR-0006)。
- **应用身份**:显示名 Joey,bundle id `com.leafiy.joey`,更新源 `https://leafiy.com/updates/joey.json`,依赖 `.package(path: "../leafiy-ui")`。
- **词汇表**:joey 根目录 `CONTEXT.md`;工程决策记 `docs/adr/`。
- **技能**:决策票默认 grilling + domain-modeling;UI/组件票用 prototype;调研票用 research。
- **Charting 轮已锁定的决策**(详见 CONTEXT.md / ADR-0001):
  - SSH 引擎 = 薄 Swift 封装 + libssh 系 C 栈;rsync 走系统二进制,其 ssh 命令行由同一份 Host Record 生成。
  - 主机配置 = QSpace 式表单(host/port/user/密码或密钥文件),另加一键导入 `~/.ssh/config` 基础字段;认证支持密码 + 密钥。
  - 上传 = 拖进面板浏览器(当前目录/文件夹行)+ 拖到 menubar 图标(落到 Last Browsed Directory)。
  - 浏览器 = 单列列表 + 面包屑,懒加载;行内拖出用 file promise,落盘时才真正下载。
  - rsync 缺失 = 检测 → 面板提示 → 一键安装(sudo 明示),失败回退 sftp。
  - 传输反馈 = 仅 menubar Status-Dot 忙碌闪烁;失败驻留错误态 + 面板顶部可关闭 Error Banner;零弹窗零系统通知。
  - v1 文件管理 = 删除(带确认)、重命名、新建文件夹,仅此三样。
  - 面板一次一个 Active Host,可切换。

## Decisions so far

<!-- one line per closed ticket: gist + link -->

- [01 SSH C 库选型与 SwiftPM 打包](issues/01-ssh-c-library-packaging.md) — 定 libssh 0.12.2 + 静态 libcrypto 链成单 dylib,本地 xcframework 作 `binaryTarget` + 薄 wrapper;LGPL 走 §6(b) 动态链接(附全文+托管源码+`disable-library-validation`);libssh2 因密钥格式/known_hosts/维护劣势落选;spike 03 须验证进度回调需自实现的分块循环。
- [02 rsync 检测与远程一键安装机制](issues/02-rsync-detect-and-install.md) — `command -v` 检测;apt→dnf→yum→zypper→pacman→apk→brew 探测安装;sudo 走 `-S` 喂 stdin 不开 PTY;密码认证主机永远 sftp;进度要求本地 Homebrew rsync ≥3.1 否则 `--progress` 逐文件解析(macOS 自带 rsync/openrsync 均不支持 `--info=progress2`)。
- [04 leafiy-ui 通用拖放组件 API](issues/04-leafiy-ui-drag-components.md) — 三组件真机验证后合入 leafiy-ui main(`400aef5`,ADR-0009):`leafiyFileDrop`+标准高亮、`LeafiyMenuBarDropTarget`(status-bar window 覆盖层,1s 轮询重挂)、`LeafiyFilePromise` 拖出定纯 SwiftUI 惰性 file representation 引擎(临时文件双拷贝代价已知情接受;AppKit 直写备胎存分支历史)。
- [05 面板 UI 定稿](issues/05-panel-ui.md) — A 变体定稿:顶部 Host Switcher + 面包屑行 + 行右键菜单;双层落点高亮(文件夹行 + 空白=当前目录);内嵌 Error Banner 横条;固定 360×520;呈现用 `.window` 样式 MenuBarExtra + Gear Menu 收家族 Menu Tail(Explicit Exception,joey ADR-0002);新词 Host Switcher / Gear Menu 入 CONTEXT.md。
- [06 Joey 图标](issues/06-icons.md) — 用户自行出图(agent 草案落选):两张源图按 ICON_CONTRACT(1024 app + 640 menubar,给 Status-Dot 留角),落位沿 daisy 模式;接线与占位图归实施票。
- [07 v1 全量实施](issues/07-v1-implementation.md) — 应用全量落仓等真机验证:引擎(SSHConnection/HostSession/TransferManager/RsyncSupport/SSHConfigImport)+ 变体 A 面板 + 四页设置 + 契约合规脚手架;leafiy-ui 增 `LeafiyMenuBarExtra(style:)`(ADR-0010)与 DropTarget 悬停回调;sudo 凭据悬案落定 = 安装 sheet 临时输入;图标占位(暂借 daisy 源图)。
- [08 收藏与 Icon Drop 新动线](issues/08-favorite-drop-targets.md) — 用户新需求收编:Favorite(主机+目录,最多三)入 settings + Favorites 设置页;拖悬图标有收藏弹 Favorite Tray(LeafiyFloatingPanel)直接投放、无收藏开主面板;直接松图标兜底传第一收藏;CONTEXT.md 新词 Favorite / Favorite Tray。

## Not yet specified

- **发布链路**:适配 daisy 的 `release.sh` + `install.sh`(公证 profile、DMG、leafiy.com 更新源发布)——等 v1 真机构建通过后再切。
- **真机验证回报**:spike(03)与 app 全量(07/08)都等用户在 mac 上构建运行;失败项回流成新票。
- **正式图标源图**:用户按 ICON_CONTRACT 出图后替换两张占位 PNG(见 README)。

已随实施落定(原悬案):`~/.ssh/config` 导入只认 Host/HostName/User/Port/IdentityFile、跳过通配符与 Match(票 07);rsync 一键安装 sudo 密码 = 安装 sheet 临时输入、不复用主机密码(票 07)。

## Out of scope

- 远程文件移动、编辑、权限修改;目录同步/监听;多主机并联传输;终端/shell 功能。
- 传输完成/失败的系统通知、独立传输窗口、面板内传输队列行(Q7 决定:只要 Status-Dot)。
- 纯 Swift SSH 库(Citadel)与系统 ssh/sftp 二进制方案——已否决,理由见 joey `docs/adr/0001`。
- 最近目录栏(浏览器保持最简)。~~目录收藏~~——2026-08-19 用户直接提需求收编进 v1(票 08:Favorite 最多三个,Icon Drop 有收藏走 Favorite Tray、无收藏开主面板)。
