#!/usr/bin/env bash
#
# pkg-restore.sh - reinstall packages on a fresh Arch install from saved lists
#
# Meant to run on a machine that has nothing set up yet, so it needs neither the
# nas config nor a mounted NAS - only the two list files at a readable path.
#
# Two things it does that a plain 'pacman -S - < list' does not:
#
#   - filters the native list against the repositories, because a single package
#     that has since left the repos aborts the whole pacman transaction;
#   - installs AUR packages one at a time, so one broken PKGBUILD does not stop
#     the remaining hundred.
#
# See --help for usage.

set -euo pipefail

readonly PROG="${0##*/}"

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
usage: $PROG [package-list-directory]

Reinstall native and AUR packages from pkgs-native.txt and pkgs-aur.txt.

The directory defaults to \$NAS_BASE/drive/arch-backup/packages, where
nas-backup.sh writes the lists. Packages that failed to build are listed in
~/pkg-restore-failed.txt afterwards.
EOF
}

case ${1:-} in
    -h|--help|help)
        usage
        exit 0
        ;;
esac

# --- inputs ------------------------------------------------------------------

readonly CONFIG="${NAS_CONFIG:-$HOME/.config/nas/config}"
# shellcheck source=/dev/null
[[ -r "$CONFIG" ]] && source "$CONFIG"
NAS_BASE="${NAS_BASE:-$HOME/nas}"

readonly PKG_DIR="${1:-${PKG_DIR:-$NAS_BASE/drive/arch-backup/packages}}"
readonly NATIVE_LIST="$PKG_DIR/pkgs-native.txt"
readonly AUR_LIST="$PKG_DIR/pkgs-aur.txt"
readonly FAILED_LOG="$HOME/pkg-restore-failed.txt"

((EUID != 0)) || die "do not run as root, makepkg refuses to build that way"
command -v pacman >/dev/null || die "pacman not found, is this Arch?"

if [[ ! -s "$NATIVE_LIST" ]]; then
    err "missing or empty: $NATIVE_LIST"
    mountpoint -q "$NAS_BASE/drive" 2>/dev/null ||
        printf '  the NAS looks unmounted - try nas-mount.sh first\n' >&2
    exit 1
fi

have_aur=1
if [[ ! -s "$AUR_LIST" ]]; then
    info "no AUR list at $AUR_LIST, skipping AUR packages"
    have_aur=0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- plan --------------------------------------------------------------------

info "refreshing package databases"
sudo pacman -Sy || die "pacman -Sy failed"

pacman -Slq | sort -u >"$work/available" || die "cannot list repository packages"
sort -u "$NATIVE_LIST" >"$work/wanted"
comm -12 "$work/wanted" "$work/available" >"$work/installable"
comm -23 "$work/wanted" "$work/available" >"$work/gone"

n_wanted=$(wc -l <"$work/wanted")
n_installable=$(wc -l <"$work/installable")
n_gone=$(wc -l <"$work/gone")
n_aur=0
((have_aur == 0)) || n_aur=$(wc -l <"$AUR_LIST")

printf '\n'
printf '  %-22s %s\n' 'native in list' "$n_wanted"
printf '  %-22s %s\n' 'available in repos' "$n_installable"
printf '  %-22s %s\n' 'gone from repos' "$n_gone"
printf '  %-22s %s\n' 'AUR' "$n_aur"
printf '\n'

if ((n_gone > 0)); then
    printf '%sGone from the repositories, look for them in the AUR by hand:%s\n' "$BOLD" "$RESET"
    sed 's/^/  /' "$work/gone"
    printf '\n'
fi

printf 'Continue? [y/N] '
read -r answer
[[ $answer == [yY] ]] || exit 0

# --- native ------------------------------------------------------------------

native_rc=0
if ((n_installable > 0)); then
    printf '\n'
    info "installing $n_installable native packages"
    # pacman treats an empty target list as an error, hence the guard above.
    sudo pacman -S --needed - <"$work/installable" || native_rc=$?
else
    info "nothing to install from the repositories"
fi

# --- AUR helper --------------------------------------------------------------

if ((have_aur == 1)) && ! command -v yay >/dev/null; then
    printf '\n'
    info "yay not found, building it"
    sudo pacman -S --needed git base-devel || die "could not install git and base-devel"
    git clone https://aur.archlinux.org/yay.git "$work/yay" || die "cloning yay failed"
    (cd "$work/yay" && makepkg -si) || die "building yay failed"
fi

# --- AUR ---------------------------------------------------------------------

if ((have_aur == 1)) && command -v yay >/dev/null; then
    printf '\n'
    info "installing $n_aur AUR packages one at a time"

    : >"$FAILED_LOG"
    n=0
    while read -r pkg; do
        [[ -n $pkg ]] || continue
        n=$((n + 1))
        printf '\n%s[%d/%d] %s%s\n' "$DIM" "$n" "$n_aur" "$pkg" "$RESET"

        if ! yay -S --needed --noconfirm "$pkg"; then
            err "$pkg failed"
            printf '%s\n' "$pkg" >>"$FAILED_LOG"
        fi
    done <"$AUR_LIST"
fi

# --- summary -----------------------------------------------------------------

problems=0
((native_rc == 0)) || problems=1
((n_gone == 0)) || problems=1
[[ ! -s "$FAILED_LOG" ]] || problems=1

printf '\n'
if ((problems)); then
    printf '%sFinished with problems:%s\n' "$BOLD" "$RESET"
    ((native_rc == 0)) || printf '  pacman exited %d, check its output above\n' "$native_rc"
    ((n_gone == 0)) || printf '  %d native packages are no longer in the repos\n' "$n_gone"
    if [[ -s "$FAILED_LOG" ]]; then
        printf '  %d AUR packages failed, listed in %s\n' \
            "$(wc -l <"$FAILED_LOG")" "$(tilde "$FAILED_LOG")"
    fi
else
    info "all packages installed"
    rm -f "$FAILED_LOG"
fi

printf '\nNext step, restoring files:\n  nas-backup.sh restore\n'

# Non-zero when the machine did not end up with everything the lists asked for.
exit "$problems"
