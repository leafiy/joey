# Joey

常驻 menubar 的 SSH/SFTP 远程文件管理器:拖文件上传到远程任意目录,超简单浏览器把远程文件拖出到本地。leafiy 家族应用,基于 leafiy-ui。

## Language

**Host Record**:
设置里的一条远程主机配置(名称、host、port、用户名、默认目录、认证方式),SFTP 引擎与 rsync 命令行共用同一份。
_Avoid_: server、connection、profile

**Active Host**:
面板当前操作的那一台主机;一次只有一台,可切换。
_Avoid_: current server、session

**Browser**:
面板里的远程目录视图:单列列表 + 面包屑,懒加载,支持 Command/Shift 多选;Gear Menu 可切换隐藏文件,目录读取与文件传输共用一套等待指示。
_Avoid_: explorer、finder

**Default Directory**:
Host Record 上可选的固定远程起始目录;配置后,每次激活该主机时 Browser 从这里打开。留空则恢复 Last Browsed Directory,新主机首次打开时解析远程 home。

**Last Browsed Directory**:
Active Host 上最近一次浏览/落盘的远程目录;未配置 Default Directory 时用于恢复 Browser,也是拖到 menubar 图标时的上传落点。
_Avoid_: home

**Panel Drop**:
把本地文件拖进 Browser 完成上传——拖到空白处传当前目录,拖到文件夹行传进该文件夹。
_Avoid_: import

**Icon Drop**:
把本地文件直接拖到 menubar 图标:配置了 Favorite 时弹出 Favorite Tray 直接投放;没有 Favorite 时打开主面板落到 Browser。

**Favorite**:
Host Record 上的收藏开关,最多开启三个;Icon Drop 以该 Host 的 Default Directory 为直达落点,未配置时使用 Last Browsed Directory。
_Avoid_: bookmark、pinned folder

**Favorite Tray**:
拖文件悬停 menubar 图标时弹出的小面板,每个已收藏 Host 一个落点行,拖上即传。
_Avoid_: quick drop menu

**Drag-out**:
从 Browser 把一个或多个选中的远程文件或文件夹拖到本地(Finder/桌面);基于 file promise,落盘时才真正递归下载。
_Avoid_: export、save as

**Download Directory**:
Browser 右键 Download 的本地落点;默认使用 macOS Downloads,可在设置中选择其他文件夹。文件和文件夹都可下载,已有同名项目时保留原项目并生成带序号的新名称。
_Avoid_: export folder

**Transfer**:
一次上传或下载;能走 rsync 就走 rsync,否则 sftp。两个方向都先写隐藏暂存项目(下载 `.joeydownload` 落在本地,上传 `.joeyupload` 落在远端目录),连接中断后自动重连并从已有字节继续,完成后再原子改名为最终名称;用户不感知协议切换和续传。sftp 两个方向都用请求流水线,吞吐不再被单次往返延迟卡死。
_Avoid_: sync、copy job

**Staging Item**:
Transfer 写到最终名称之前占位的隐藏项目。取消会清掉它(下次传输本就从头开始,留着没有续传价值),网络失败则保留给重试续用。
_Avoid_: temp file、partial

**rsync Acceleration**:
私钥认证 Host 的上传加速路径;Host 设置自动检测本机与远程 rsync 并显示启用状态。远程缺失时可自动安装:root/NOPASSWD 直接执行,需要 sudo 时临时输入密码,权限不足则显示明确错误并继续回退 sftp。


**Error Banner**:
面板顶部可关闭的一条错误概要(哪个文件、什么错);与 Status-Dot 错误态一起构成全部失败反馈——无弹窗、无系统通知。

**Host Switcher**:
面板工具条左侧的 Active Host 下拉:列出全部 Host Record,可切换,尾部带 Configure Hosts… 入口。
_Avoid_: server picker、connection menu

**Gear Menu**:
面板工具条右侧的齿轮菜单,收纳家族 Menu Tail(Settings… / 检查更新 / Quit)。
_Avoid_: hamburger、more menu
