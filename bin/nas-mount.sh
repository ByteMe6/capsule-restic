#!/usr/bin/env bash
#
# nas-mount.sh - mount Apple Time Capsule AFP shares
#
# Credentials live in ~/.config/nas/config (mode 0600), never in this file.
# See --help for usage.

set -euo pipefail

readonly PROG="${0##*/}"
readonly CONFIG="${NAS_CONFIG:-$HOME/.config/nas/config}"
readonly LOGFILE="${XDG_CACHE_HOME:-$HOME/.cache}/nas-mount.log"

if [[ -t 1 ]]; then
    readonly BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' RESET=$'\e[0m'
else
    readonly BOLD='' DIM='' RED='' RESET=''
fi

info() { printf '%s: %s\n' "$PROG" "$*"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }
err()  { printf '%s%s: error: %s%s\n' "$RED" "$PROG" "$*" "$RESET" >&2; }
die()  { err "$*"; exit 1; }

# Shorten $HOME to ~ for display. $HOME must be quoted inside the pattern,
# otherwise bash 5.2 treats it as a glob and matches nothing.
tilde() { printf '%s' "${1/#"$HOME"/\~}"; }

usage() {
    local list='' index=1 share
    for share in "${SHARE_ORDER[@]}"; do
        list+="  $index $share"$'\n'
        index=$((index + 1))
    done

    cat <<EOF
usage: $PROG [command]

Mount Apple Time Capsule shares over AFP (via afpfs-ng).

commands:
  (none)                interactive prompt
  status                print mount status
  mount <share|all>     mount a share
  umount <share|all>    unmount a share
  clean                 clear dead mounts left behind by the afpfs daemon

A share is named, numbered as shown by 'status', or 'all'. Names are
case-insensitive.

shares:
${list%$'\n'}

Credentials are read from $CONFIG (mode 0600).
Output from mount_afp and its daemon lands in $LOGFILE.
EOF
}

# --- configuration -----------------------------------------------------------

if [[ ! -r "$CONFIG" ]]; then
    err "cannot read $CONFIG"
    cat >&2 <<EOF

Create it with mode 0600:

    AFP_HOST="192.168.0.136"
    AFP_USER="ByteMe6"
    AFP_PASS="..."
    NAS_BASE="\$HOME/nas"
EOF
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG"

for required in AFP_HOST AFP_USER AFP_PASS; do
    [[ -n ${!required:-} ]] || die "$required is not set in $CONFIG"
done
unset required

NAS_BASE="${NAS_BASE:-$HOME/nas}"

command -v mount_afp >/dev/null || die "mount_afp not found (pacman -S afpfs-ng)"

# share -> mount point. Mount point names match share names on purpose: the
# previous mapping (ByteMe6 -> ~/nas/samedy6) was a leftover from a username
# change and made it impossible to tell which share you were looking at.
#
# Note: 'drive' and 'ByteMe6' are two shares on the same physical Time Capsule
# disk - df reports identical used/available. Mounting both gives you two
# afpfs-ng connections to one device and no extra storage.
declare -rA SHARES=(
    [drive]="$NAS_BASE/drive"
    [ByteMe6]="$NAS_BASE/byteme6"
)
readonly SHARE_ORDER=(drive ByteMe6)

# --- share operations --------------------------------------------------------

mount_point_of() {
    local share=$1
    if [[ ! -v SHARES[$share] ]]; then
        err "unknown share: $share (have: ${SHARE_ORDER[*]})"
        return 1
    fi
    printf '%s' "${SHARES[$share]}"
}

# Accepts a share name in any case, a list index, or 'all'; prints the canonical
# share name. Indices exist because the status listing numbers the shares.
resolve_share() {
    local input=$1 share index

    if [[ ${input,,} == all ]]; then
        printf 'all'
        return 0
    fi

    if [[ $input =~ ^[0-9]+$ ]]; then
        index=$((input))
        if ((index >= 1 && index <= ${#SHARE_ORDER[@]})); then
            printf '%s' "${SHARE_ORDER[index - 1]}"
            return 0
        fi
        err "no share numbered $input (have 1-${#SHARE_ORDER[@]})"
        return 1
    fi

    for share in "${SHARE_ORDER[@]}"; do
        if [[ ${input,,} == "${share,,}" ]]; then
            printf '%s' "$share"
            return 0
        fi
    done

    err "unknown share: $input (have: ${SHARE_ORDER[*]}, 1-${#SHARE_ORDER[@]}, or all)"
    return 1
}

# afpfs-ng registers each mount as "<server>:<share>", so a share can be mounted
# at a path this script knows nothing about. Print where it actually is, if
# anywhere - without this, mounting fails with a confusing message from
# mount_afp ("Volume X is already mounted on Y") and an empty-looking status.
current_mount_of() {
    local share=$1 device mp rest
    while read -r device mp rest; do
        [[ $device == *":$share" ]] || continue
        printf '%s' "${mp//\\040/ }"   # /proc escapes spaces as \040
        return 0
    done </proc/self/mounts
    return 1
}

mount_share() {
    local share=$1 mp attempt elsewhere
    mp=$(mount_point_of "$share") || return 1

    if mountpoint -q "$mp"; then
        info "$share already mounted on $(tilde "$mp")"
        return 0
    fi

    if elsewhere=$(current_mount_of "$share"); then
        if [[ $elsewhere != "$mp" ]]; then
            err "$share is already mounted on $(tilde "$elsewhere"), not $(tilde "$mp")"
            printf '  release it first:  fusermount -u %q\n' "$elsewhere" >&2
            return 1
        fi

        # Listed in /proc but not reachable: the afpfs daemon died underneath it
        # and left a mount that returns ENOTCONN for every operation. This
        # happens whenever the daemon is restarted, and mount_afp refuses to
        # mount over it. Nothing can be using a dead mount, so clear it.
        info "clearing stale mount on $(tilde "$mp")"
        if ! release "$mp"; then
            err "could not clear the stale mount on $(tilde "$mp")"
            return 1
        fi
    fi

    mkdir -p "$mp"
    info "mounting $share on $(tilde "$mp")"

    # afpfs-ng cannot read the password from a file or stdin, only from the URL,
    # so it is briefly visible in ps(1). That is a limitation of afpfs-ng 0.8.2.
    #
    # Output goes to a log file rather than the terminal, because mount_afp is
    # chatty on success and the interesting part is only the failure. It must be a
    # real file and not a command substitution: mount_afp leaves an afpfsd daemon
    # behind which inherits stdout, so a pipe would block until the daemon exits
    # and a temporary file would live on as a deleted inode for the same reason.
    mkdir -p "$(dirname "$LOGFILE")"
    if [[ -f $LOGFILE ]] && (($(stat -c %s "$LOGFILE") > 1048576)); then
        : >"$LOGFILE"   # the daemon appends here for as long as it runs
    fi

    # Remember where the log ends, so a failure report shows this attempt only
    # and not the output of every previous mount.
    local log_offset=0
    [[ -f $LOGFILE ]] && log_offset=$(stat -c %s "$LOGFILE")

    # The descriptor cap is not cosmetic. afpfs-ng polls with select(), and glibc
    # aborts any process that calls FD_SET on a descriptor >= FD_SETSIZE (1024).
    # This machine has a soft limit of 524288, so during a long backup afpfsd
    # eventually gets a high descriptor and dies with
    #   *** bit out of range 0 - FD_SETSIZE on fd_set ***: terminated
    # taking every mount down with it. Capping the daemon at 1024 makes that
    # impossible: a single operation fails with EMFILE instead of the whole mount
    # disappearing mid-write.
    if ! (ulimit -n 1024 &&
        exec mount_afp "afp://${AFP_USER}:${AFP_PASS}@${AFP_HOST}/${share}" "$mp") \
        >>"$LOGFILE" 2>&1; then
        err "mount_afp failed for $share, from $(tilde "$LOGFILE"):"
        tail -c "+$((log_offset + 1))" "$LOGFILE" | sed '/^$/d; s/^/  /' >&2
        return 1
    fi

    # mount_afp forks into the background, so wait for FUSE to come up.
    for attempt in $(seq 1 10); do
        if mountpoint -q "$mp"; then
            info "$share mounted"
            return 0
        fi
        sleep 0.5
    done

    err "$share did not mount within 5s"
    return 1
}

release() { fusermount -u "$1" 2>/dev/null || umount "$1" 2>/dev/null; }

# True if any share is listed in /proc but no longer answering.
any_stale_mounts() {
    local share path
    for share in "${SHARE_ORDER[@]}"; do
        path=$(current_mount_of "$share") || continue
        mountpoint -q "$path" || return 0
    done
    return 1
}

# afpfs-ng runs one daemon per uid for every share, and that daemon goes down with
# the first unmount. Under a second later the remaining shares stop answering while
# keeping their /proc entries, so 'status' would call them mounted when they are
# corpses. Clear them: they cannot be revived and nothing can be holding them.
#
# Pass 'wait' when calling right after an unmount, to let the daemon actually exit
# before the siblings are probed.
clear_stale_mounts() {
    local mode=${1:-now} share path attempt cleared=0

    if [[ $mode == wait ]]; then
        for attempt in $(seq 1 6); do
            any_stale_mounts && break
            sleep 0.5
        done
    fi

    for share in "${SHARE_ORDER[@]}"; do
        path=$(current_mount_of "$share") || continue
        mountpoint -q "$path" && continue

        info "$share went down with the shared daemon, cleared $(tilde "$path")"
        release "$path" || true
        cleared=$((cleared + 1))
    done

    ((cleared > 0))
}

# Second argument 'quiet' suppresses the running commentary about sibling shares,
# for when the caller is unmounting everything anyway.
umount_share() {
    local share=$1 quiet=${2:-} mp path other others=()
    mp=$(mount_point_of "$share") || return 1

    if ! mountpoint -q "$mp"; then
        # Either genuinely not mounted, or a corpse left behind by a dead daemon.
        if path=$(current_mount_of "$share"); then
            info "$share on $(tilde "$path") is dead, clearing it"
            release "$path" || true
        elif [[ $quiet != quiet ]]; then
            info "$share not mounted"
        fi
        return 0
    fi

    for other in "${SHARE_ORDER[@]}"; do
        [[ $other == "$share" ]] && continue
        mountpoint -q "${SHARES[$other]}" && others+=("$other")
    done

    if ((${#others[@]} > 0)) && [[ $quiet != quiet ]]; then
        info "note: the afpfs daemon is shared, so this also takes down ${others[*]}"
    fi

    # FUSE mounts are released with fusermount; plain umount would need root.
    if ! release "$mp"; then
        err "cannot unmount $share, something is holding it open:"
        fuser -mv "$mp" 2>&1 | head -n 10 >&2 || true
        return 1
    fi

    info "$share unmounted"

    if ((${#others[@]} > 0)); then
        clear_stale_mounts wait || true
    fi
    return 0
}

print_status() {
    local index=1 share mp state path
    for share in "${SHARE_ORDER[@]}"; do
        mp=${SHARES[$share]}

        if mountpoint -q "$mp"; then
            state=mounted
            path=$mp
        elif path=$(current_mount_of "$share"); then
            # Present in /proc but not usable, or mounted at an unexpected path.
            if [[ $path == "$mp" ]]; then
                state='stale (dead daemon)'
            else
                state='mounted elsewhere'
            fi
        else
            state='not mounted'
            path=$mp
        fi

        printf '  %s%d  %-9s%s  %-20s %s%s%s\n' \
            "$BOLD" "$index" "$share" "$RESET" "$state" "$DIM" "$(tilde "$path")" "$RESET"
        index=$((index + 1))
    done
}

# Runs an action over one share or all of them; non-zero if any failed.
apply() {
    local action=$1 target share rc=0 targets=() extra=()

    target=$(resolve_share "$2") || return 1

    if [[ $target == all ]]; then
        targets=("${SHARE_ORDER[@]}")
        # Taking the other shares down is the whole point of 'umount all', so it
        # does not need narrating share by share.
        [[ $action == umount ]] && extra=(quiet)
    else
        targets=("$target")
    fi

    for share in "${targets[@]}"; do
        "${action}_share" "$share" "${extra[@]}" || rc=1
    done
    return "$rc"
}

# --- entry point -------------------------------------------------------------

if (($# > 0)); then
    case $1 in
        status)
            print_status
            ;;
        mount|umount)
            [[ -n ${2:-} ]] || die "$1 needs a share name or 'all'"
            apply "$1" "$2"
            ;;
        clean)
            clear_stale_mounts || info "no dead mounts to clear"
            ;;
        # Undocumented aliases kept so older scripts and shell history keep working.
        --auto)
            [[ -n ${2:-} ]] || die "--auto needs a share name or 'all'"
            apply mount "$2"
            ;;
        --auto-drive)
            apply mount drive
            ;;
        --status)
            print_status
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            err "unknown command: $1"
            usage >&2
            exit 2
            ;;
    esac
    exit $?
fi

while true; do
    printf '\n'
    print_status
    printf '\n'
    printf '  %s%-12s%s %-10s %s%-7s%s %s\n' "$BOLD" 'm <1|name>' "$RESET" mount   "$BOLD" 'm all' "$RESET" 'mount both'
    printf '  %s%-12s%s %-10s %s%-7s%s %s\n' "$BOLD" 'u <1|name>' "$RESET" unmount "$BOLD" 'u all' "$RESET" 'unmount both'
    printf '  %s%-12s%s %s\n' "$BOLD" c "$RESET" 'clear dead mounts'
    printf '  %s%-12s%s %s\n' "$BOLD" q "$RESET" quit
    printf '\n> '

    read -r verb target || exit 0

    case $verb in
        m|mount)
            [[ -n $target ]] || { warn "usage: m <share|number|all>"; continue; }
            apply mount "$target" || true
            ;;
        u|umount)
            [[ -n $target ]] || { warn "usage: u <share|number|all>"; continue; }
            apply umount "$target" || true
            ;;
        c|clean)
            clear_stale_mounts || info "no dead mounts to clear"
            ;;
        q|quit|exit|'')
            exit 0
            ;;
        *)
            warn "unknown command: $verb"
            ;;
    esac
done
