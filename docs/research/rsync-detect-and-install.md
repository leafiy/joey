# rsync detection, remote install, and transfer mechanics

Research for `.scratch/joey-v1/issues/02-rsync-detect-and-install.md`. Date: 2026-08-19.

## 1. Detecting remote rsync

**Recommended probe (one SSH exec):**

```sh
sh -c 'command -v rsync >/dev/null 2>&1 && rsync --version 2>/dev/null | head -n 2'
```

- `command -v` is the POSIX-mandated builtin, present in ash/dash/bash/ksh/zsh and BusyBox `sh`; `which` is neither guaranteed to exist nor portable ([travis.rb PR #765 discussion](https://github.com/travis-ci/travis.rb/pull/765), [nixCraft](https://www.cyberciti.biz/faq/unix-linux-shell-find-out-posixcommand-exists-or-not/)). Very old BusyBox builds (~1.16) could be compiled without `command`; treat any non-0/127 oddity as "unknown", not "missing".
- SSH exec runs the string through the **user's login shell** (`$SHELL -c`). Wrapping in `sh -c '…'` keeps the syntax valid even when the login shell is csh/fish. If `sh` itself is absent (exit 127), classify as "no rsync" and use sftp.
- Parse the version banner: GNU rsync prints `rsync  version 3.x.y  protocol version 31`; Apple's openrsync prints an `openrsync:` banner and is "compatible with rsync protocol versions 27 - 29" ([Apple openrsync.1, rsync-184](https://github.com/apple-oss-distributions/rsync/blob/rsync-184/openrsync/openrsync.1)). Record both name and version — needed for the progress decision (§5).

**Local (mac) side matters more than the remote.** macOS ≤ 14 ships GPLv2 rsync 2.6.9 (2006, protocol 29); macOS 15 Sequoia introduced BSD/ISC-licensed openrsync, initially behind a dispatch wrapper (`/usr/libexec/rsync/rsync.samba` vs `rsync.openrsync`), and since 15.4 `rsync.samba` is gone — `/usr/bin/rsync` is openrsync only ([Der Flounder](https://derflounder.wordpress.com/2025/04/06/rsync-replaced-with-openrsync-on-macos-sequoia/), [mjtsai](https://mjtsai.com/blog/2025/06/06/sequoias-new-rsync/)). Wire interop is fine — protocols negotiate down to 27–29 — but **neither stock binary supports `--info=progress2`** (added in rsync 3.1.0, 2013 — [UbuntuHandbook release note](https://ubuntuhandbook.org/index.php/2013/09/rsync-3-1-0-released-with-new-options-and-improvements/)).

## 2. Package-manager probe order and non-interactive installs

Probe with `command -v <pm>` in this order (first hit wins; `dnf` before `yum` because modern `yum` is a dnf symlink):

| Order | Manager | Distros | Non-interactive install |
|---|---|---|---|
| 1 | `apt-get` | Debian/Ubuntu | `DEBIAN_FRONTEND=noninteractive apt-get install -y rsync` ([apt-get(8)](https://manpages.debian.org/bookworm/apt/apt-get.8.en.html)) |
| 2 | `dnf` | Fedora/RHEL 8+ | `dnf install -y rsync` ([dnf docs](https://dnf.readthedocs.io/en/latest/command_ref.html)) |
| 3 | `yum` | RHEL/CentOS 7 | `yum install -y rsync` |
| 4 | `zypper` | SUSE | `zypper --non-interactive install rsync` ([zypper(8)](https://en.opensuse.org/SDB:Zypper_manual)) |
| 5 | `pacman` | Arch | `pacman -S --noconfirm --needed rsync` ([pacman(8)](https://man.archlinux.org/man/pacman.8)) |
| 6 | `apk` | Alpine | `apk add rsync` (non-interactive by default, [apk docs](https://wiki.alpinelinux.org/wiki/Alpine_Package_Keeper)) |
| 7 | `brew` | macOS remote | `brew install rsync` — **no sudo**; brew refuses root |

Skip `apt-get update` by default; if install fails with "package not found", retry once after `apt-get update` (same idea for others is unnecessary). One probe round-trip: `sh -c 'for p in apt-get dnf yum zypper pacman apk brew; do command -v $p && break; done'`.

## 3. sudo without a TTY over SSH exec

Per [sudo(8)](https://manpages.debian.org/bookworm/sudo/sudo.8.en.html):

- `-n` (non-interactive): "Avoid prompting… If a password is required, sudo will display an error message and exit."
- `-S` (stdin): "Write the prompt to the standard error and read the password from the standard input instead of using the terminal device."

**Decision ladder (recommended):**

1. `id -u` == 0 → run the install command directly, no sudo.
2. `sudo -n true` exits 0 → NOPASSWD (or cached timestamp): run `sudo -n <install>` on a plain SSH exec channel.
3. Otherwise: `sudo -S -p '' sh -c '<install>'`, writing the sudo password + `\n` to the channel's stdin, **no PTY**. `-S` explicitly removes the terminal requirement, so `ssh -tt`-style forced PTY is unnecessary — and undesirable (a PTY echoes the password into the output stream and mixes the prompt into parsed data; see [Baeldung TTY discussion](https://www.baeldung.com/linux/provide-pass-without-tty-override)).
4. If sudo still fails (legacy `Defaults requiretty` on old RHEL, wrong password, user not in sudoers) → surface stderr verbatim, fall back to sftp. Do not attempt PTY workarounds.

Where the sudo password comes from (reuse SSH password vs prompt) is deferred to a follow-up ticket, per the issue.

## 4. rsync invocation template (Host Record, key auth)

```sh
{rsync_bin} -rlpt -z --partial --progress [--info=progress2 --no-inc-recursive] \
  -e "ssh -p {port} -i {key_path} \
      -o BatchMode=yes -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 -o ServerAliveInterval=15" \
  {src} "{user}@{host}:{remote_path}"
```

- Bracketed extras only when local rsync is ≥ 3.1 (§5). Use `-rlpt` rather than `-a` (owner/group need root on the receiver). IPv6 literals must be bracketed: `user@[fe80::1]:path`.
- `BatchMode=yes` makes ssh fail instead of prompting — correct for key auth from a GUI app.
- Quote/escape `remote_path` for the remote shell (rsync passes it through it): wrap in single quotes, escape embedded quotes.

**Password-auth hosts: always use sftp — do not attempt rsync.** The only way to feed a password to OpenSSH non-interactively is `sshpass`, whose own man page says the `-p` mode "should be considered the least secure" (password visible in `ps`) and that programmatic use is inherently race-prone ([sshpass(1)](https://manpages.debian.org/unstable/sshpass/sshpass.1.en.html)). It isn't shipped with macOS, so joey would have to bundle or install it locally. `SSH_ASKPASS` tricks are equally fragile. The app already has a working libssh sftp path for these hosts; use it unconditionally.

## 5. Progress parsing

- **If a modern local rsync (≥ 3.1) is available** — probe `/opt/homebrew/bin/rsync`, `/usr/local/bin/rsync`, then `rsync --version` capability check — add `--info=progress2 --no-inc-recursive`. `progress2` reports whole-transfer stats on one `\r`-rewritten line: `1,036,923,510  99%  39.90MB/s  0:00:24 (xfr#1, to-chk=0/2)`. Split stdout on `\r`/`\n`; regex `(\d+)%\s+(\S+/s)\s+(\d+:\d{2}(?::\d{2})?)` plus optional `xfr#(\d+), (?:ir|to)-chk=(\d+)/(\d+)`. `--no-inc-recursive` forces a full upfront scan so the percentage is monotonic instead of jumping as incremental recursion discovers files ([Dave Dribin](https://www.dribin.org/dave/blog/archives/2024/01/21/rsync-overall-progress/), [rsync(1)](https://download.samba.org/pub/rsync/rsync.1)). Only the **local** binary needs 3.1+; progress is computed client-side, remote version is irrelevant.
- **Stock-binary fallback** (rsync 2.6.9 on macOS ≤ 14, openrsync on 15+): both support `--progress` and `--partial` (Apple's openrsync fork is much richer than OpenBSD upstream — it has `--partial`, `--partial-dir`, `-z`, `--stats`, `--log-file`, but **no `--info`** — [openrsync.1](https://github.com/apple-oss-distributions/rsync/blob/rsync-184/openrsync/openrsync.1)). Parse per-file `\r` lines (`bytes  NN%  rate  eta`) and compute overall progress app-side: joey already knows the file list and sizes from its sftp listing, so overall % = (completed bytes + current-file bytes) / total.
- **Do not bundle GNU rsync 3.x**: it is GPLv3 — the very reason Apple dropped it ([AppleInsider](https://appleinsider.com/inside/macos-sequoia/tips/what-you-should-know-about-apples-switch-from-rsync-to-openrsync)) — which is incompatible with Mac App Store distribution and adds source-offer obligations. Prefer: use Homebrew rsync when present, else stock binary + app-side progress.

## Risks

- Remote login shell not POSIX and no `/bin/sh` → detection returns "unknown"; default to sftp.
- `requiretty` sudoers on legacy RHEL breaks `sudo -S` without PTY → fall back to sftp (by design).
- openrsync behavioral gaps vs GNU rsync (daemon mode, ACL/xattr semantics, occasional assertion failures reported on 15.4) — keep sftp fallback on any non-zero rsync exit ([mjtsai](https://mjtsai.com/blog/2025/06/06/sequoias-new-rsync/)).
- `--noconfirm`/`-y` installs can pull large dependency sets on minimal images. The Host's explicit **Install Automatically…** action is the authorization boundary; the sheet keeps the exact command visible while probing/running. Root/NOPASSWD installs proceed automatically, password sudo pauses for input, and permission failures surface stderr before falling back to sftp.

## Sources

- https://github.com/apple-oss-distributions/rsync/blob/rsync-184/openrsync/openrsync.1
- https://derflounder.wordpress.com/2025/04/06/rsync-replaced-with-openrsync-on-macos-sequoia/
- https://mjtsai.com/blog/2025/06/06/sequoias-new-rsync/
- https://appleinsider.com/inside/macos-sequoia/tips/what-you-should-know-about-apples-switch-from-rsync-to-openrsync
- https://manpages.debian.org/bookworm/sudo/sudo.8.en.html
- https://manpages.debian.org/unstable/sshpass/sshpass.1.en.html
- https://download.samba.org/pub/rsync/rsync.1
- https://ubuntuhandbook.org/index.php/2013/09/rsync-3-1-0-released-with-new-options-and-improvements/
- https://www.dribin.org/dave/blog/archives/2024/01/21/rsync-overall-progress/
- https://www.cyberciti.biz/faq/unix-linux-shell-find-out-posixcommand-exists-or-not/
- https://www.baeldung.com/linux/provide-pass-without-tty-override
