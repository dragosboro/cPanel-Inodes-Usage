#!/usr/bin/env bash
#
# Convenience wrapper. All removal logic lives in install.sh --uninstall so that
# there is exactly one code path to audit. Accepts the same options, e.g.:
#
#   sudo ./uninstall.sh --theme=jupiter
#   sudo ./uninstall.sh --dry-run
#
set -euo pipefail

# Resolve this script's own directory, and NEVER fall back to the caller's $PWD. Piped in
# (`curl ... | bash`) BASH_SOURCE is unset: under `set -u` only the inner $() subshell dies, the
# outer one survives, `cd -- ""` is a silent no-op success, and SCRIPT_DIR becomes $PWD -- which
# would exec an arbitrary ./install.sh from whatever directory the admin happened to be in, as root.
SELF=${BASH_SOURCE[0]:-}
[[ -n $SELF && -f $SELF ]] || { printf 'uninstall.sh: this wrapper has no file on disk (piped in?). Run it from a checkout, or use: sudo bash install.sh --uninstall\n' >&2; exit 1; }
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$SELF")" && pwd -P) || exit 1
INSTALLER="${SCRIPT_DIR}/install.sh"

[[ -f $INSTALLER ]] || { printf 'uninstall.sh: %s not found.\n' "$INSTALLER" >&2; exit 1; }

exec bash "$INSTALLER" --uninstall "$@"
