#!/usr/bin/env bash
# agy-install.sh - install the portable agy wrapper + PostInvocation hook that
# the `agy` executor profile needs, with explicit operator confirmation.
#
# Usage:
#   bash docs/examples/agy-install.sh
#
# This script:
#   1. copies docs/examples/agy-with-permissions.sh  -> ~/bin/agy-with-permissions
#   2. copies docs/examples/agy-hook-notify.sh       -> ~/bin/agy-hook-notify.sh
#   3. merges the "agy-result-hook" PostInvocation registration into the global
#      agy hooks config (default ~/.gemini/config/hooks.json), preserving all
#      unrelated existing hook entries.
#
# Nothing is overwritten or edited without explicit confirmation. Existing
# unrelated hooks are never deleted. The script never silently creates empty
# result files; the hook creates the result file only when it first appends.
set -euo pipefail

repo=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
examples="$repo/docs/examples"

home="${CMURO_AGENT_HOME:-$(printf '%s' "$HOME")}"
bin_dir="${CMUX_AGENT_BIN:-${home}/bin}"
hooks_config="${CMUX_AGENT_HOOKS_CONFIG:-${home}/.gemini/config/hooks.json}"

source_wrapper="$examples/agy-with-permissions.sh"
source_adapter="$examples/agy-hook-notify.sh"
source_registration="$examples/agy-result-hook.hooks.json"

for required in "$source_wrapper" "$source_adapter" "$source_registration"; do
  if [[ ! -s "$required" ]]; then
    echo "Missing or empty template: $required" >&2
    exit 1
  fi
done

wrapper_target="$bin_dir/agy-with-permissions"
adapter_target="$bin_dir/agy-hook-notify.sh"

echo
echo "Install the portable agy executor template files for the 'agy' profile."
echo
echo "  wrapper:            $wrapper_target"
echo "  hook adapter:       $adapter_target"
echo "  hooks config (merge): $hooks_config"
echo
echo "No existing file is overwritten without explicit confirmation, and"
echo "existing unrelated hook entries are preserved."
echo
echo "Continue? (y/N)"
read -r proceed
if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
  echo "Aborted; nothing installed."
  exit 1
fi

mkdir -p -- "$bin_dir"

# install_file <target> <source> <label>
install_file() {
  local target="$1"
  local source="$2"
  local label="$3"
  if [[ -e "$target" ]]; then
    echo "File already exists: $target"
    echo "Replace it with the portable template? (This removes its current content.) (y/N)"
    read -r replace
    if [[ ! "$replace" =~ ^[Yy]$ ]]; then
      echo "Skipped $label; existing file left intact."
      return 0
    fi
  fi
  cp -- "$source" "$target"
  chmod 755 "$target"
  echo "Installed $label: $target"
}

install_file "$wrapper_target" "$source_wrapper" "wrapper"
install_file "$adapter_target" "$source_adapter" "hook adapter"

# Merge the PostInvocation registration into the existing agy hooks config.
merge_or_write_hooks() {
  if [[ -e "$hooks_config" ]]; then
    echo
    echo "Merging the agy-Result-hook PostInvocation registration into: $hooks_config"
    echo "Existing hook entries other than 'agy-result-hook' are preserved. Edit this file? (y/N)"
    read -r edit
    if [[ ! "$edit" =~ ^[Yy]$ ]]; then
      echo "Skipped hooks.json merge."
      return 0
    fi
    python3 - "$hooks_config" "$source_registration" <<'PY'
import copy
import json
import shutil
import sys

config_path = sys.argv[1]
fragment_path = sys.argv[2]
with open(config_path, encoding="utf-8") as stream:
    config = json.load(stream)
if not isinstance(config, dict):
    raise SystemExit("agy hooks config is not a JSON object; refusing to edit")
with open(fragment_path, encoding="utf-8") as stream:
    fragment = json.load(stream)
if set(fragment) != {"agy-result-hook"}:
    raise SystemExit("unexpected registration fragment; refusing to edit")
new_entry = fragment["agy-result-hook"]
if config.get("agy-result-hook") not in (None, new_entry):
    shutil.copy2(config_path, config_path + ".bak")
    print("Backed up existing config to " + config_path + ".bak", file=sys.stderr)
config["agy-result-hook"] = copy.deepcopy(new_entry)
tmp = config_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as stream:
    json.dump(config, stream, indent=2)
    stream.write("\n")
shutil.move(tmp, config_path)
print("Merged agy-result-hook into " + config_path)
PY
  else
    echo
    echo "No existing agy hooks config at: $hooks_config"
    echo "Write it with only the agy-result-hook PostInvocation registration? (y/N)"
    read -r write
    if [[ ! "$write" =~ ^[Yy]$ ]]; then
      echo "Skipped hooks.json creation."
      return 0
    fi
    mkdir -p -- "$(dirname -- "$hooks_config")"
    python3 - "$hooks_config" "$source_registration" <<'PY'
import json
import shutil
import sys

config_path = sys.argv[1]
fragment_path = sys.argv[2]
with open(fragment_path, encoding="utf-8") as stream:
    fragment = json.load(stream)
tmp = config_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as stream:
    json.dump(fragment, stream, indent=2)
    stream.write("\n")
shutil.move(tmp, config_path)
print("Wrote " + config_path)
PY
  fi
}

merge_or_write_hooks

echo "Done. Before first use:"
echo "  - The wrapper launches agy with --dangerously-skip-permissions. That is"
echo "    explicit and profile-declared; the supervisor still stops at a"
echo "    'NEED_APPROVAL' marker before a consequential action."
echo "  - No result file is created here on purpose; the hook creates it on its"
echo "    first PostInvocation append. The agy result source must be writable by"
echo "    the Pi process, and the runtime event directory must exist."
echo "  - Registering the hook does not install or alter your existing hooks."
echo "  - Test with a disposable canonical checkout and exactly one harmless"
echo "    artifact before relying on agy."