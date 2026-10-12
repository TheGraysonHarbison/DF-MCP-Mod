#!/usr/bin/env bash
# Add this repository's mod scripts to a Dwarf Fortress install's DFHack script path.
# Usage: tools/link-mod.sh <path to Dwarf Fortress folder>
# Follows https://docs.dfhack.org/en/stable/docs/guides/modding-guide.html (dev setup).
set -euo pipefail

df_dir="${1:-}"
if [[ -z "$df_dir" || ! -d "$df_dir" ]]; then
    echo "usage: $0 <path to Dwarf Fortress folder>" >&2
    exit 2
fi

config_dir="$df_dir/dfhack-config"
if [[ ! -d "$config_dir" ]]; then
    echo "no dfhack-config folder in $df_dir; is DFHack installed there?" >&2
    exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts_dir="$repo_root/mod/scripts_modinstalled"
paths_file="$config_dir/script-paths.txt"
line="+$scripts_dir"

touch "$paths_file"
if grep -qxF "$line" "$paths_file"; then
    echo "already linked: $line"
else
    printf '%s\n' "$line" >> "$paths_file"
    echo "added to $paths_file: $line"
fi
echo "Next: in the DFHack console run 'enable claude-bridge' (restart DF or run ':lua require(\"script-manager\").reload()' first if DF is already open)."
