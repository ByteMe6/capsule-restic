<div align="center">

# 🗄️ backup-tools

**Encrypted `$HOME` backups to an Apple Time Capsule — and a one-command way back to a working Arch system.**

![Bash](https://img.shields.io/badge/bash-5.x-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)
![Arch Linux](https://img.shields.io/badge/Arch_Linux-1793D1?style=for-the-badge&logo=archlinux&logoColor=white)
![restic](https://img.shields.io/badge/restic-encrypted-00ADD8?style=for-the-badge)
![AFP](https://img.shields.io/badge/Time_Capsule-AFP-999999?style=for-the-badge&logo=apple&logoColor=white)
![License](https://img.shields.io/badge/license-Giant_Penis_License-ff69b4?style=for-the-badge)

</div>

---

```
 ┌──────────────┐   nas-mount    ┌─────────────────────┐
 │   Arch box   │ ─────────────▶ │  Time Capsule (AFP) │
 │              │                │                     │
 │   ~/  ───────┼── nas-backup ─▶│  arch-backup/       │
 │              │                │   ├── restic/  🔒   │
 │   pacman ────┼────────────────┼─▶ └── packages/     │
 └──────────────┘                └──────────┬──────────┘
        ▲                                   │
        └──────────── pkg-restore ◀─────────┘
                   (fresh install)
```

## ✨ The tools

| Script | What it does |
| :-- | :-- |
| **`nas-mount.sh`** | Mounts Time Capsule shares over AFP (`afpfs-ng`). Detects and clears dead mounts left by a crashed daemon, caps the daemon's fd limit so it can't blow up mid-backup. |
| **`nas-backup.sh`** | `restic` snapshot of `$HOME` with a sane exclude list, plus a copy of your pacman/AUR package lists. Watchdog aborts fast if the AFP daemon dies. Interactive menu or subcommands. |
| **`pkg-restore.sh`** | Rebuilds a fresh Arch install from the saved lists. Skips packages that left the repos, installs AUR packages one by one so a single broken PKGBUILD can't stop the rest. |

## 🚀 Install

```bash
git clone https://github.com/ByteMe6/backup-tools.git
cd backup-tools
./install.sh              # symlinks into ~/.local/bin, seeds ~/.config/nas/config
$EDITOR ~/.config/nas/config
```

**Dependencies**

```bash
sudo pacman -S restic jq
yay -S afpfs-ng
```

## ⚙️ Config

`~/.config/nas/config` — mode `0600`, never committed:

```bash
AFP_HOST="192.168.0.10"
AFP_USER="your-user"
AFP_PASS="your-password"
NAS_BASE="$HOME/nas"
```

The restic password lives in `~/.config/restic/password` and is created on the first backup.

## 🧭 Usage

### `nas-mount.sh`

```text
nas-mount.sh                 interactive prompt
nas-mount.sh status          show what's mounted
nas-mount.sh mount  drive    mount by name, number, or 'all'
nas-mount.sh umount all
nas-mount.sh clean           clear dead mounts
```

### `nas-backup.sh`

```text
nas-backup.sh                interactive menu
nas-backup.sh backup         snapshot + save package lists
nas-backup.sh snapshots      list snapshots
nas-backup.sh restore        restore into a fresh directory (never over ~ by default)
nas-backup.sh diff           what changed between the last two snapshots
nas-backup.sh forget         retention: last 10 · 12 weekly · 12 monthly (dry run first)
nas-backup.sh check          verify integrity (monthly is a good habit)
nas-backup.sh prune | unlock | pkgs
```

The NAS is mounted automatically when needed.

### `pkg-restore.sh`

```text
pkg-restore.sh [dir]         default: $NAS_BASE/drive/arch-backup/packages
```

Shows a plan (available / gone from repos / AUR), asks once, then installs.
AUR failures end up in `~/pkg-restore-failed.txt`.

## 🔁 Disaster recovery in three steps

```bash
nas-mount.sh mount drive     # 1. reach the NAS
pkg-restore.sh               # 2. get your packages back
nas-backup.sh restore        # 3. get your files back
```

## 🛡️ Design notes

- **Manual, not scheduled.** AFP is slow and flaky; backups run when you're watching.
- **Fail loudly.** A failed restic run never refreshes the package lists and never prints "done".
- **Local lock.** `flock` on local disk — file locking over AFP can't be trusted.
- **No overwrite surprises.** Restores go to `~/restic-restore-<date>` unless you type `yes`.

## 📄 License

[Giant Penis License (GPL)](LICENSE) — not *that* GPL.
