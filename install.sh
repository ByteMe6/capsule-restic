#!/usr/bin/env bash
# install.sh - symlink the tools into ~/.local/bin and seed the config
set -euo pipefail

src=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
bin="${PREFIX:-$HOME/.local/bin}"
cfg="$HOME/.config/nas/config"

mkdir -p "$bin"
for f in "$src"/bin/*.sh; do
    ln -sfn "$f" "$bin/${f##*/}"
    printf '  linked  %s\n' "$bin/${f##*/}"
done

if [[ ! -e $cfg ]]; then
    mkdir -p "${cfg%/*}"
    (umask 077; cp "$src/examples/config.example" "$cfg")
    printf '  created %s  (edit it: host, user, password)\n' "$cfg"
fi
