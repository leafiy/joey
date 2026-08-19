# 02 rsync 检测与远程一键安装机制

Type: research
Status: resolved

## Question

已定交互(检测 → 面板提示 → 一键安装,sudo 明示,失败回退 sftp),机制未定。回答:

1. **检测**:通过 SSH exec 探测远程 rsync 是否可用的最稳命令(`command -v rsync` 的 shell 兼容性、busybox/最小系统的坑);本地 mac 侧 rsync 版本差异(macOS 自带 openrsync vs brew rsync)是否影响与远端互通。
2. **包管理器探测与安装命令**:apt/dnf/yum/apk/pacman/zypper/brew(Linux/macOS 远端)的探测顺序与各自的非交互安装命令行。
3. **sudo 无 TTY 问题**:通过 SSH exec 跑 `sudo` 时没有终端——`sudo -S`(stdin 喂密码)、`-t` 强制 TTY、NOPASSWD 检测各自的可行性与风险;root 用户直连时跳过 sudo 的判断。
4. **rsync 传输命令行**:从 Host Record(host/port/user/密码或密钥)生成 `rsync -e "ssh …"` 的完整参数;密码认证的主机 rsync 怎么办(sshpass?不可行则密码主机永远 sftp?)——给出明确建议。
5. **进度解析**:`rsync --info=progress2` 输出的稳定解析方式。

产出:机制设计写入 `docs/research/rsync-detect-and-install.md`,含推荐的探测/安装/传输命令模板。凭据复用细节(sudo 密码来源)留给后续决策票。

## Answer

详见 [docs/research/rsync-detect-and-install.md](../../../docs/research/rsync-detect-and-install.md)。要点:

1. **检测**:一次 SSH exec——`sh -c 'command -v rsync >/dev/null 2>&1 && rsync --version | head -n 2'`(`command -v` 是 POSIX;`sh -c` 包裹可在 csh/fish 登录 shell 下存活;exit 127 = 缺失)。解析 banner 区分 GNU rsync / openrsync。
2. **安装**:探测顺序 `apt-get → dnf → yum → zypper → pacman → apk → brew`;各自的非交互命令(`DEBIAN_FRONTEND=noninteractive apt-get install -y rsync`、`dnf/yum -y`、`zypper --non-interactive`、`pacman -S --noconfirm --needed`、`apk add`;brew 永不加 sudo)。
3. **sudo 无 TTY**:`id -u`==0 跳过;`sudo -n true` 探测 NOPASSWD;否则 `sudo -S -p ''` 从 stdin 喂密码,走普通 exec 通道**不要 PTY**(`-tt` 会回显密码);任何失败(如老式 `requiretty`)→ 回退 sftp。sudo 密码来源留后续决策。
4. **传输命令行(密钥认证)**:`rsync -rlpt -z --partial --progress -e "ssh -p {port} -i {key} -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" src user@host:'path'`。**密码认证的主机永远走 sftp**(sshpass 官方 man 自认不安全,且 macOS 无原生包)。
5. **进度**:`--info=progress2 --no-inc-recursive` 仅当本地 rsync ≥3.1(Homebrew 版);macOS 14 自带 rsync 2.6.9、macOS 15 换 openrsync,都不支持 `--info` → 回退 `--progress` 逐文件解析 + 应用侧用 sftp 列表算总量。不捆绑 GPLv3 rsync。互通只看协议,远端版本无碍。
