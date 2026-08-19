# Joey

常驻 menubar 的 SSH/SFTP 远程文件管理器:拖文件上传到远程任意目录,超简单浏览器把远程文件拖出到本地。leafiy 家族应用,基于 leafiy-ui。

## Language

**Host Record**:
设置里的一条远程主机配置(名称、host、port、用户名、认证方式),SFTP 引擎与 rsync 命令行共用同一份。
_Avoid_: server、connection、profile

**Active Host**:
面板当前操作的那一台主机;一次只有一台,可切换。
_Avoid_: current server、session

**Browser**:
面板里的远程目录视图:单列列表 + 面包屑,懒加载。
_Avoid_: explorer、finder

**Last Browsed Directory**:
Active Host 上最近一次浏览/落盘的远程目录;拖到 menubar 图标时的上传落点。
_Avoid_: default directory、home

**Panel Drop**:
把本地文件拖进 Browser 完成上传——拖到空白处传当前目录,拖到文件夹行传进该文件夹。
_Avoid_: import

**Icon Drop**:
把本地文件直接拖到 menubar 图标:配置了 Favorite 时弹出 Favorite Tray 直接投放;没有 Favorite 时打开主面板落到 Browser。

**Favorite**:
设置里收藏的一个远程落点 = Host Record + 远程目录,最多三个;是 Icon Drop 的直达目标。
_Avoid_: bookmark、pinned folder

**Favorite Tray**:
拖文件悬停 menubar 图标时弹出的小面板,每个 Favorite 一个落点行,拖上即传。
_Avoid_: quick drop menu

**Drag-out**:
从 Browser 把远程文件拖到本地(Finder/桌面);基于 file promise,落盘时才真正下载。
_Avoid_: export、save as

**Transfer**:
一次上传或下载;能走 rsync 就走 rsync,否则 sftp。用户不感知协议切换。
_Avoid_: sync、copy job

**Error Banner**:
面板顶部可关闭的一条错误概要(哪个文件、什么错);与 Status-Dot 错误态一起构成全部失败反馈——无弹窗、无系统通知。

**Host Switcher**:
面板工具条左侧的 Active Host 下拉:列出全部 Host Record,可切换,尾部带 Configure Hosts… 入口。
_Avoid_: server picker、connection menu

**Gear Menu**:
面板工具条右侧的齿轮菜单,收纳家族 Menu Tail(Settings… / 检查更新 / Quit)。
_Avoid_: hamburger、more menu
