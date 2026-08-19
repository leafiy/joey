# 07 v1 全量实施(app 脚手架到可构建)

Type: task
Status: resolved
Blocked by: 01, 02, 04, 05, 06

## Question

用户指令(2026-08-19):没时间逐票测试,一次性完成 v1 全部实施。范围 = map 中已列的全部实施面:template-app 起步的脚手架、设置页(主机表单 + `~/.ssh/config` 导入 + 隐私文案)、SSHEngine 集成(spike API 转正)、Browser 视图(05 定稿变体 A)、上传/下载 Transfer、rsync 加速路径(02 机制)、menubar 图标拖放接入(04 组件)。图标用占位图,等用户源图就位。构建与真机验证由用户执行;spike 票 03 保持 claimed,不阻塞本票。

## Answer

**已落仓(2026-08-19),等用户 `sh build-app.sh` 真机验证。** 结构:

- **脚手架**:`Package.swift`(`joey` app + 保留 `joey-spike`,依赖 `../leafiy-ui`)、`Info.plist`(com.leafiy.joey,AppIcon,`LeafiyMenuBarIconFile=joey.png`,feed joey.json)、`build-app.sh`(家族契约 + 图标编译 + libssh.dylib 进 Frameworks + `disable-library-validation` entitlement 签名)。图标为占位(暂借 daisy 源图,README 有说明)。
- **引擎** `Sources/Joey/Engine/`:`SSHConnection`(spike 转正 + mkdir/rename/rmdir/exec 通道)、`HostSession`(每主机串行队列的 async 门面,断线自动重连)、`TransferManager`(Transfer 序列化,Status-Dot busy/error/success + Error Banner 数据源;rsync 失败自动回退 sftp)、`RsyncSupport`(02 机制:检测/包管理器探测/sudo -S 无 PTY/命令行模板)、`SSHConfigImport`(Host/HostName/User/Port/IdentityFile,跳过通配符与 Match)。
- **UI**:`PanelRootView`(变体 A:Host Switcher + 面包屑 + 内嵌 Error Banner + 双层落点高亮 + 行右键菜单 + Gear Menu 收 `LeafiyFamilyMenu`;rsync 缺失提示条 + 一键安装 sheet,sudo 密码临时输入不复用主机密码)、`JoeySettingsView`(General/Hosts/Favorites/Privacy 四页,即改即存)。
- **leafiy-ui 配套**(已入 main):`LeafiyMenuBarExtra` 增 `style:` 参数(ADR-0010,joey 用 `.window`);`LeafiyMenuBarDropTarget` 增 `onDragChanged` 悬停回调与 status item 定位/点击 helper;契约脚本与家族名单加入 joey。
- **测试** `Tests/JoeyTests/`:settings 往返/normalize、ssh-config 解析、rsync 机制单元、家族链接。

未做(明示):进度百分比 UI(家族决策只有 Status-Dot)、rsync 下载路径(下载走 sftp file promise)、多选/队列。sudo 凭据复用问题按 map 悬案落定为**临时输入**。
