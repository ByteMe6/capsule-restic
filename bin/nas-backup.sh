#!/usr/bin/env bash
#
# nas-backup.sh - restic backup of $HOME to an Apple Time Capsule
#
# The restic repository lives on the NAS and is reached over AFP (afpfs-ng),
# which is slow and prone to dropping out. Consequences baked into this script:
#
#   - backups are manual, never scheduled;
#   - any restic failure aborts the run, so the package lists are not refreshed
#     and you never get a success message for a backup that did not happen;
#   - 'check' exists and is worth running about once a month.
#
# See --help for usage.

set -euo pipefail

readonly PROG="${0##*/}"
readonly CONFIG="${NAS_CONFIG:-$HOME/.config/nas/config}"

if [[ -t 1 ]]; then
    readonly BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' RESET=$'\e[0m'
else
    readonly BOLD='' DIM='' RED='' RESET=''
fi

info() { printf '%s: %s\n' "$PROG" "$*"; }
err()  { printf '%s%s: error: %s%s\n' "$RED" "$PROG" "$*" "$RESET" >&2; }
die()  { err "$*"; exit 1; }

# Shorten $HOME to ~ for display. $HOME must be quoted inside the pattern,
# otherwise bash 5.2 treats it as a glob and matches nothing.
tilde() { printf '%s' "${1/#"$HOME"/\~}"; }

usage() {
    cat <<EOF
usage: $PROG [command]

Back up \$HOME to the restic repository on the NAS.

commands:
  (none)       interactive prompt
  backup       create a snapshot, then save the package lists
  snapshots    list snapshots
  restore      restore a snapshot into a fresh directory
  forget       apply the retention policy (asks before deleting)
  diff         show what changed between the last two snapshots
  check        verify repository integrity
  prune        reclaim space left behind by interrupted backups
  unlock       clear locks left behind by interrupted runs
  pkgs         save the pacman/AUR package lists only

The NAS share is mounted automatically if needed.
EOF
}

# --- configuration -----------------------------------------------------------

# shellcheck source=/dev/null
[[ -r "$CONFIG" ]] && source "$CONFIG"

NAS_BASE="${NAS_BASE:-$HOME/nas}"
readonly DRIVE_MP="$NAS_BASE/drive"
readonly BACKUP_ROOT="$DRIVE_MP/arch-backup"
readonly PKG_DIR="$BACKUP_ROOT/packages"

# Look for its companion next to this script rather than at a fixed path, so the
# pair keeps working wherever the two are installed.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
readonly MOUNTER="$SCRIPT_DIR/nas-mount.sh"

# The lock lives on local disk: file locking over AFP is not trustworthy.
readonly LOCKFILE="${XDG_CACHE_HOME:-$HOME/.cache}/nas-backup.lock"

export RESTIC_REPOSITORY="$BACKUP_ROOT/restic"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$HOME/.config/restic/password}"

require() { command -v "$1" >/dev/null || die "$1 not installed (pacman -S $2)"; }
require restic restic

mkdir -p "$(dirname "$LOCKFILE")"

# The lock covers one operation, not the whole process. Taking it at startup meant
# the interactive prompt held it while sitting idle waiting for input, so a menu
# left open blocked every other invocation, including the next backup.
with_lock() {
    local rc=0

    exec 9>"$LOCKFILE"
    if ! flock -n 9; then
        err "another $PROG operation is running (lock: $(tilde "$LOCKFILE"))"
        exec 9>&-
        return 1
    fi

    "$@" || rc=$?
    exec 9>&-
    return "$rc"
}

TMPWORK=''
# Must end in a success: the exit status of the EXIT trap replaces the script's
# own, so a failing last command here would report failure for a good run.
cleanup() {
    [[ -n $TMPWORK ]] && rm -rf "$TMPWORK"
    return 0
}
trap cleanup EXIT

# Paths excluded from the backup. Everything here is either reinstallable from
# the network, a cache, or the NAS itself.
readonly EXCLUDES=(
    --exclude-caches

    # games and wine prefixes
    --exclude "$HOME/Games"
    --exclude "$HOME/.steam"
    --exclude "$HOME/.local/share/Steam"
    --exclude "$HOME/.local/share/lutris"
    --exclude "$HOME/.local/share/bottles"
    --exclude "$HOME/main_bottle"
    --exclude "$HOME/.wine"
    --exclude "$HOME/.local/share/anime-game-launcher"
    --exclude "$HOME/.local/share/honkers-railway-launcher"
    --exclude "$HOME/.paradoxlauncher"
    --exclude "$HOME/VirtualBox"

    # caches and trash
    --exclude "$HOME/.cache"
    --exclude "$HOME/.local/share/Trash"
    --exclude "$HOME/.thumbnails"
    --exclude "$HOME/.var"
    --exclude "$HOME/.zoom"

    # toolchain and package manager caches
    --exclude "$HOME/.cargo/registry"
    --exclude "$HOME/.rustup/toolchains"
    --exclude "$HOME/.gradle"
    --exclude "$HOME/.m2"
    --exclude "$HOME/.nuget"
    --exclude "$HOME/.dotnet"
    --exclude "$HOME/.pub-cache"
    --exclude "$HOME/go/pkg"
    --exclude "node_modules"
    --exclude "__pycache__"
    --exclude "*.pyc"

    # rootless docker: overlayfs layers and images. Reinstallable from a
    # registry, and the subdirectories are root-owned, so restic cannot read
    # them anyway - without this the backup always ends at rc=3.
    --exclude "$HOME/.docker-data"

    # bulky or worthless
    --exclude "*.iso"
    --exclude ".DS_Store"

    # the NAS itself, so the backup does not contain the backup
    --exclude "$NAS_BASE"

    # AI tools and models
    --exclude "$HOME/stable-diffusion-webui-forge"
    --exclude "$HOME/.ollama/models"

)

# --- preconditions -----------------------------------------------------------

ensure_mounted() {
    mountpoint -q "$DRIVE_MP" && return 0

    info "NAS not mounted, mounting"
    [[ -x "$MOUNTER" ]] || die "$MOUNTER not found, mount the drive share yourself"

    # 9>&- closes the lock descriptor for the mounter. mount_afp leaves an afpfsd
    # daemon running, that daemon inherits every open descriptor, and a daemon
    # holding fd 9 keeps this script's flock for as long as it lives - which made
    # every later run abort with "another nas-backup.sh is already running".
    "$MOUNTER" mount drive 9>&- || die "could not mount the NAS"
    mountpoint -q "$DRIVE_MP" || die "NAS still not mounted"
}

ensure_repo() {
    [[ -f "$RESTIC_REPOSITORY/config" ]] && return 0

    info "no repository at $(tilde "$RESTIC_REPOSITORY"), initialising"

    if [[ ! -f "$RESTIC_PASSWORD_FILE" ]]; then
        local pass confirm
        printf 'Encryption password for the backup: '
        read -rs pass; printf '\n'
        printf 'Repeat: '
        read -rs confirm; printf '\n'

        [[ -n $pass ]] || die "empty password"
        [[ $pass == "$confirm" ]] || die "passwords do not match"

        mkdir -p "$(dirname "$RESTIC_PASSWORD_FILE")"
        chmod 700 "$(dirname "$RESTIC_PASSWORD_FILE")"
        # umask before creating the file: a later chmod would leave the password
        # world-readable for a moment.
        (umask 077; printf '%s\n' "$pass" >"$RESTIC_PASSWORD_FILE")
    fi

    mkdir -p "$RESTIC_REPOSITORY"
    restic init || die "restic init failed"
}

# --- commands ----------------------------------------------------------------

cmd_pkgs() {
    ensure_mounted

    # Build the lists locally first: a failed pacman run must not truncate the
    # good copies sitting on the NAS.
    TMPWORK=$(mktemp -d)

    pacman -Qqen >"$TMPWORK/pkgs-native.txt" || die "pacman -Qqen failed"
    pacman -Qqem >"$TMPWORK/pkgs-aur.txt" || die "pacman -Qqem failed"
    [[ -s "$TMPWORK/pkgs-native.txt" ]] || die "native package list came back empty, keeping the old one"

    mkdir -p "$PKG_DIR" || die "cannot create $(tilde "$PKG_DIR")"
    cp "$TMPWORK/pkgs-native.txt" "$TMPWORK/pkgs-aur.txt" "$PKG_DIR/" ||
        die "cannot write the lists to $(tilde "$PKG_DIR")"

    info "saved $(wc -l <"$PKG_DIR/pkgs-native.txt") native and $(wc -l <"$PKG_DIR/pkgs-aur.txt") AUR packages"
}

cmd_backup() {
    ensure_mounted
    ensure_repo

    info "starting backup"

    # The mount can vanish mid-run when afpfsd crashes. restic reacts by retrying
    # against a dead endpoint with exponential backoff, which burns the better part
    # of an hour printing "transport endpoint is not connected" before giving up.
    # This watchdog turns that into an immediate failure.
    #
    # It watches the daemon process, not the mount point. Probing the mount means a
    # stat() through the same single-threaded daemon the backup is saturating, which
    # can stall or fail spuriously - a health check that aborts healthy backups is
    # worse than none. A missing daemon, by contrast, is unambiguous and costs no
    # I/O to detect. Two consecutive misses are required so that a daemon restart
    # racing with a check is not fatal. 9>&- keeps the watchdog off this script's
    # lock, which afpfsd would otherwise inherit and hold forever.
    local rc=0 restic_pid watchdog_pid
    restic backup "$HOME" "${EXCLUDES[@]}" --tag arch --verbose &
    restic_pid=$!

    (
        misses=0
        while kill -0 "$restic_pid" 2>/dev/null; do
            sleep 15

            if pgrep -x afpfsd >/dev/null; then
                misses=0
                continue
            fi

            misses=$((misses + 1))
            ((misses >= 2)) || continue

            err "the afpfs daemon died, aborting the backup"
            kill -TERM "$restic_pid" 2>/dev/null || true
            sleep 5
            kill -KILL "$restic_pid" 2>/dev/null || true
            exit 0
        done
    ) 9>&- &
    watchdog_pid=$!

    wait "$restic_pid" || rc=$?
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    case $rc in
        0) info "backup complete" ;;
        3) info "backup complete, but some files could not be read (restic rc=3)" ;;
        *) die "backup FAILED (restic rc=$rc), not touching the package lists" ;;
    esac

    cmd_pkgs
}

cmd_snapshots() {
    ensure_mounted
    restic snapshots
}

cmd_restore() {
    ensure_mounted
    restic snapshots
    printf '\n'

    local snapshot target default_target answer
    printf 'Snapshot id [latest]: '
    read -r snapshot
    snapshot=${snapshot:-latest}

    # Deliberately not $HOME by default: restoring over a live home directory
    # overwrites newer files with older ones and gives no warning while doing it.
    default_target="$HOME/restic-restore-$(date '+%Y%m%d-%H%M')"
    printf 'Restore into [%s]: ' "$(tilde "$default_target")"
    read -r target
    target=${target:-$default_target}

    if [[ $(readlink -m "$target") == "$(readlink -m "$HOME")" ]]; then
        printf '%sThis restores on top of your live home directory.%s\n' "$BOLD" "$RESET"
        printf "Type 'yes' to continue: "
        read -r answer
        [[ $answer == yes ]] || die "cancelled"
    fi

    restic restore "$snapshot" --target "$target" || die "restore failed"
    info "restored into $(tilde "$target")"
}

cmd_forget() {
    ensure_mounted

    # Group by host and tags rather than the default host+paths: the backup path
    # changed from /home/byteme to /home/samedy during a username change, which
    # split the history into two groups and meant retention never expired the
    # older half.
    local policy=(--group-by host,tags --keep-last 10 --keep-weekly 12 --keep-monthly 12)
    local answer

    info "dry run, nothing is deleted yet"
    restic forget "${policy[@]}" --dry-run || die "forget --dry-run failed"

    printf '\nApply this policy and prune? [y/N] '
    read -r answer
    [[ $answer == [yY] ]] || { info "cancelled"; return 0; }

    restic forget "${policy[@]}" --prune || die "forget failed"
}

cmd_diff() {
    # Only this command needs jq, so a machine without it can still take backups.
    require jq jq
    ensure_mounted

    # Two steps, so a restic failure is reported as such instead of surfacing as
    # "need at least two snapshots": pipefail does not cover a process substitution.
    local json ids
    json=$(restic snapshots --json) || die "cannot list snapshots"
    mapfile -t ids < <(printf '%s' "$json" | jq -r 'sort_by(.time) | .[-2:] | .[].id')
    ((${#ids[@]} >= 2)) || die "need at least two snapshots"

    restic diff "${ids[0]}" "${ids[1]}"
}

cmd_check() {
    ensure_mounted

    info "checking repository structure"
    if ! restic check; then
        err "check found problems"
        printf '  if it refused because the repository is locked, run: %s unlock\n' "$PROG" >&2
        return 1
    fi

    local answer
    printf 'Also verify 5%% of the actual data? Slow over AFP. [y/N] '
    read -r answer
    if [[ $answer == [yY] ]]; then
        restic check --read-data-subset=5% || die "data verification found problems"
    fi
}

# An interrupted run leaves its lock behind, and an exclusive one blocks 'check'
# and 'forget --prune' until it is cleared. Plain 'restic unlock' only removes
# locks whose owning process is gone, so it cannot disturb a live backup.
cmd_unlock() {
    ensure_mounted
    restic unlock || die "unlock failed"
    info "stale locks removed"
}

# Interrupted backups leave packs behind that hold data nothing references any
# more; 'check' reports them as "additional files ... duplicate data". This
# reclaims the space without deleting any snapshot.
cmd_prune() {
    ensure_mounted
    restic prune || die "prune failed"
}

dispatch() {
    case $1 in
        b|backup)    cmd_backup ;;
        s|snapshots) cmd_snapshots ;;
        r|restore)   cmd_restore ;;
        f|forget)    cmd_forget ;;
        d|diff)      cmd_diff ;;
        c|check)     cmd_check ;;
        u|unlock)    cmd_unlock ;;
        prune)       cmd_prune ;;
        p|pkgs)      cmd_pkgs ;;
        *)           return 127 ;;
    esac
}

# --- entry point -------------------------------------------------------------

if (($# > 0)); then
    case $1 in
        -h|--help|help)
            usage
            exit 0
            ;;
    esac

    rc=0
    with_lock dispatch "$1" || rc=$?
    if ((rc == 127)); then
        err "unknown command: $1"
        usage >&2
        exit 2
    fi
    exit "$rc"
fi

# menu_row <name> <description> [name] [description] - one or two columns. The
# column padding is trimmed off the end so no line ends in whitespace.
menu_row() {
    local line
    line=$(printf '  %s%-10s%s %-22s %s%-8s%s %s' \
        "$BOLD" "$1" "$RESET" "$2" "$BOLD" "${3:-}" "$RESET" "${4:-}")

    while [[ $line == *' ' ]]; do
        line=${line% }
    done
    printf '%s\n' "$line"
}

printf '%srepository%s %s\n' "$DIM" "$RESET" "$(tilde "$RESTIC_REPOSITORY")"

while true; do
    printf '\n'
    menu_row backup    'create a snapshot'  forget 'apply retention policy'
    menu_row snapshots 'list snapshots'     check  'verify integrity'
    menu_row restore   'restore a snapshot' prune  'reclaim wasted space'
    menu_row diff      'last two snapshots' unlock 'clear stale repo locks'
    menu_row pkgs      'save package lists' quit
    printf '\n> '
    read -r choice || exit 0
    printf '\n'

    case $choice in
        q|quit|exit|'')
            exit 0
            ;;
        *)
            # Subshell: a failing command must not kill the prompt, and die()
            # inside a command should only abort that command.
            rc=0
            (with_lock dispatch "$choice") || rc=$?
            ((rc == 127)) && err "unknown command: $choice"
            ;;
    esac
done
