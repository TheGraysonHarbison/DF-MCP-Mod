#!/usr/bin/env bash
# Remove the claude-bridge mod from a Dwarf Fortress install (the counterpart of tools/link-mod.sh).
# Usage: tools/unlink-mod.sh <path to Dwarf Fortress folder>
#
# Removes:
#   - every line in dfhack-config/script-paths.txt that points at this mod's scripts folder: this
#     repository's line, any scripts_modinstalled folder that holds claude-bridge.lua (another copy
#     or an older extracted release), and any missing folder ending in mod/scripts_modinstalled
#     (an older release that was deleted). Other lines, comments, and line endings stay as they are.
#   - the mod's settings folder dfhack-config/mods/claude-bridge/ (settings, permissions, allowlist).
# Leaves saves (their claude-df/ folders and enabled flag) and Claude Code's config alone.
# script-paths.txt format: https://docs.dfhack.org/en/stable/docs/Core.html#custom-script-paths
# (checked against DFHack 53.16-r2).
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
settings_dir="$config_dir/mods/claude-bridge"
removed=0

# True when a script-paths.txt line (without its line ending) names a claude-bridge scripts folder.
is_mod_line() {
    local entry="$1" path norm
    case "$entry" in
        +* | -*) path="${entry:1}" ;;
        *) path="$entry" ;;
    esac
    # Trim surrounding whitespace.
    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"
    [[ -z "$path" || "$path" == \#* ]] && return 1
    # Relative paths are relative to the DF folder.
    if [[ "$path" != /* && ! "$path" =~ ^[A-Za-z]: ]]; then
        path="$df_dir/$path"
    fi
    norm="${path//\\//}"
    while [[ "$norm" == */ && "$norm" != / ]]; do norm="${norm%/}"; done
    [[ "$norm" == "$scripts_dir" ]] && return 0
    [[ "$norm" == */scripts_modinstalled ]] || return 1
    [[ -f "$norm/claude-bridge.lua" ]] && return 0
    [[ ! -e "$norm" && "$norm" == */mod/scripts_modinstalled ]] && return 0
    return 1
}

if [[ -f "$paths_file" ]]; then
    tmp_file="$(mktemp "$config_dir/.script-paths.txt.XXXXXX")"
    trap 'rm -f "$tmp_file"' EXIT
    dropped=()
    while true; do
        ending=$'\n'
        if ! IFS= read -r line; then
            # A last line without a final newline: keep it that way.
            [[ -z "$line" ]] && break
            ending=""
        fi
        # read strips the "\n"; a "\r" from CRLF endings stays on the line and is written back.
        if is_mod_line "${line%$'\r'}"; then
            dropped+=("${line%$'\r'}")
        else
            printf '%s%s' "$line" "$ending" >> "$tmp_file"
        fi
        [[ -z "$ending" ]] && break
    done < "$paths_file"
    if (( ${#dropped[@]} > 0 )); then
        # mktemp creates the file private; give it the mode a new file would get.
        chmod "$(printf '%o' $(( 0666 & ~0$(umask) )))" "$tmp_file"
        mv -f "$tmp_file" "$paths_file"
        for entry in "${dropped[@]}"; do
            echo "removed from $paths_file: $entry"
        done
        removed=1
    fi
fi

if [[ -d "$settings_dir" ]]; then
    rm -rf "$settings_dir"
    echo "removed settings folder: $settings_dir"
    removed=1
fi

if (( removed == 0 )); then
    echo "nothing to remove: claude-bridge is not installed in $df_dir"
else
    echo "Saves and Claude Code were left alone. If Dwarf Fortress is running, restart it so DFHack forgets the scripts."
fi
