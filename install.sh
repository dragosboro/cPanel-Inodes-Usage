#!/usr/bin/env bash
#
# cPanel "Inode Usage" plugin installer -- https://github.com/dragosboro/cPanel-Inodes-Usage
# Copies three files into a cPanel theme AND one UAPI module into /usr/local/cpanel/Cpanel/API/,
# registers a menu entry through cPanel's own scripts/install_plugin, rebuilds the icon sprite
# sheet, verifies the result. Runs as root.
#
# ===========================================================================================
# BLAST RADIUS -- every path this script can create, modify or delete.
# T = /usr/local/cpanel/base/frontend/<theme>
# CREATE/    T/inode_usage/                                      dir,   0755 root:root
# OVERWRITE  T/inode_usage/index.html.tt, T/inode_usage/preloader.gif,
#            T/inode_usage/VERSION                               files, 0644 root:root
#            T/dynamicui/dynamicui_inode_usage.conf              by cPanel install_plugin
#            T/assets/application_icons/inode_usage.svg          by cPanel install_plugin
#            T/assets/application_icons/sprites/*                by cPanel sprite_generator
#            $TMPDIR/inode-usage-install.XXXXXXXX                standalone download only
# OVERWRITE  /usr/local/cpanel/Cpanel/API/ChemiCloudInodeUsage.pm  file, 0644 root:root -- the ONE path
#            outside the theme; 0644 because the cPanel USER's uapi process require's it. Refused unless
#            cPanel's .cpanelsync_cpanel does NOT claim that path AND any file there carries our marker.
#            install(1) unlinks-then-creates: no write through a symlink, no service restart, but a cpsrvd
#            child that already require'd the module keeps the old code until that session process exits.
# DELETE     T/inode_usage/<STALE_FILES>  superseded names, only after a successful deploy
#            T/data.zip     only when byte-for-byte the 43472-byte artifact left by a 2025
#                           partial run; any other data.zip is left alone
#            T/inode_usage/ recursively and Cpanel/API/ChemiCloudInodeUsage.pm (same two conditions as
#            the install side), --uninstall only; plus the temp dir above
# NEVER      T/dynamicui.conf (the single file) -- cpanelsync-managed, cPanel rewrites it on
# TOUCHED    update; only the dynamicui/ DIRECTORY is safe for third parties, and writing there
#            invalidates every user's menu cache by itself, so /home/*/.cpanel/caches/ is never
#            touched either. Neither this script nor anything it calls touches /home/* or /etc/*.
# VIA        This script writes nothing under /var and signals no service, but install_plugin AND
# CPANEL     uninstall_plugin each enqueue 'sprite_generator' + 'verify_api_spec_files' in /var/
#            cpanel/taskqueue/servers_{queue,sched}.json for the running queueprocd, and log to
#            /usr/local/cpanel/logs/error_log. verify_api_spec_files rewrites /var/cpanel/api_spec/
#            cpanel_uapi.json to list the new module -- ASYNCHRONOUSLY, so nothing here waits on it.
#            --uninstall also lets cPanel rewrite /var/cpanel/account_enhancements/config/installed.json
#            and unlink whostmgr/addonfeatures/<id>.
# EXIT CODES 0 ok  1 usage  2 not root  3 not cPanel  4 cPanel tooling missing  5 theme unusable
#   6 payload missing/inconsistent  7 deploy failed  8 download/checksum  9 (de)registration
#   10 verification failed  11 utility missing  12 unexpected failure (ERR trap)
# ===========================================================================================

set -Eeuo pipefail   # -E propagates the ERR trap into functions, which makes exit 12 reachable.

readonly SCRIPT_VERSION='2.0.0'
readonly REPO_SLUG='dragosboro/cPanel-Inodes-Usage'
readonly RELEASE_TAG="v${SCRIPT_VERSION}"
# An UPLOADED asset, not GitHub's auto-generated /archive/ tarball: that one is recompressed server-
# side and its checksum has moved under people before. The asset is payload-only (src/ lib/ plugin/ VERSION,
# no install.sh), so embedding its checksum here cannot change it. RELEASE ENGINEERING: lib/ is NOT optional
# -- without it every standalone install dies 6 on the module source check.
readonly RELEASE_ASSET="cPanel-Inodes-Usage-${SCRIPT_VERSION}.tar.gz"
readonly RELEASE_URL="https://github.com/${REPO_SLUG}/releases/download/${RELEASE_TAG}/${RELEASE_ASSET}"
# RELEASE ENGINEERING: substituted at tag time; gate tagging on it. Until then this is not 64 hex
# digits, so standalone mode refuses to run rather than fetch unverified code as root.
readonly RELEASE_SHA256='REPLACE_WITH_RELEASE_ASSET_SHA256'
readonly PLUGIN_ID='inode_usage'    # cPanel names BOTH dynamicui_<id>.conf and <id>.<ext> from this
readonly APP_SUBDIR='inode_usage'
readonly ICON_FILE='inode_usage.svg'
readonly ENTRY_POINT='index.html.tt'
readonly LEGACY_ENTRY_POINT='index.live.php'   # v1's; only ever READ, to recognise an old install
readonly EXPECTED_URI="${APP_SUBDIR}/${ENTRY_POINT}"
readonly PAYLOAD_FILES=(index.html.tt preloader.gif)
# The three .live.php names moved here from PAYLOAD_FILES in 2.0.0: without that move the unvalidated
# fetch_subfolders.live.php traversal stays live at its old URL on every server that "upgraded". No
# *.live.pl names -- none were ever shipped, so listing them would only widen the delete surface.
readonly STALE_FILES=(index.php fetch_inode_data.php fetch_subfolders.php
                      index.live.php fetch_inode_data.live.php fetch_subfolders.live.php data.zip)
readonly CPANEL_ROOT='/usr/local/cpanel'
readonly THEMES_DOCROOT="${CPANEL_ROOT}/base/frontend"       # Cpanel::Themes::Utils
readonly INSTALL_PLUGIN="${CPANEL_ROOT}/scripts/install_plugin"
readonly UNINSTALL_PLUGIN="${CPANEL_ROOT}/scripts/uninstall_plugin"
readonly SPRITE_GENERATOR="${CPANEL_ROOT}/bin/sprite_generator"
readonly CPANEL_PERL="${CPANEL_ROOT}/3rdparty/bin/perl"
readonly WWWACCT_CONF='/etc/wwwacct.conf'
readonly DEFAULT_ICON_SUBPATH='assets/application_icons'
# Theme-root litter from a 2025 partial run that unzipped from the wrong cwd. The SIZE is load-
# bearing: that root is shared, so deleting by name alone would eat another vendor's data.zip.
readonly LITTER_NAME='data.zip' LITTER_SIZE='43472'
# The fourth destructive destination. Cpanel/API/ is cPanel's SHARED namespace, so this name carries a vendor
# prefix as every third-party .pm there does, while the names we own stay plain. MODULE_MARKER must appear
# verbatim in the shipped .pm; it is an anti-footgun, not a security control (that dir is root:root 0755).
readonly MODULE_NAME='ChemiCloudInodeUsage'
readonly MODULE_FILE="${MODULE_NAME}.pm"
readonly MODULE_SRC_SUBPATH="lib/Cpanel/API/${MODULE_FILE}"
readonly API_DIR="${CPANEL_ROOT}/Cpanel/API"
readonly MODULE_DEST="${API_DIR}/${MODULE_FILE}"
readonly MODULE_MARKER='cPanel-Inodes-Usage plugin -- https://github.com/dragosboro/cPanel-Inodes-Usage'
readonly SYNC_MANIFEST="${CPANEL_ROOT}/.cpanelsync_cpanel"
readonly SYNC_CLAIM="f===./Cpanel/API/${MODULE_FILE}==="
THEME='' THEME_ROOT='' APP_DIR='' DUI_CONF='' ICON_DIR='' ICON_DEST=''
PAYLOAD_DIR='' PLUGIN_DIR='' MODULE_SRC='' WORK='' WORK_PREFIX=''
DRY_RUN=0 QUIET=0 MODE='install' THEME_GIVEN=0 FAILURES=0

say()  { (( QUIET )) || printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { local c=$1; shift; printf 'ERROR: %s\n' "$*" >&2; exit "$c"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; FAILURES=$(( FAILURES + 1 )); }

run() { if (( DRY_RUN )); then say "  [would run] $*"; else "$@"; fi; }   # every mutation goes here

on_err() { printf 'ERROR: unexpected failure at line %s (exit %s). The install may be partial; inspect %s and re-run.\n' "${1:-?}" "$?" "${APP_DIR:-$THEMES_DOCROOT}" >&2; exit 12; }
trap 'on_err $LINENO' ERR

# DESTRUCTIVE OP (a): the work dir -- only a path we minted from mktemp, still matching that prefix,
# and still a directory.
cleanup() { [[ -n $WORK && -n $WORK_PREFIX && $WORK == "${WORK_PREFIX}"* && -d $WORK ]] && rm -rf -- "$WORK"; return 0; }
trap cleanup EXIT

ensure_work() {   # Allocated LAZILY, so --dry-run creates nothing: only a real download gets here.
    [[ -z $WORK ]] || return 0
    WORK_PREFIX="${TMPDIR:-/tmp}/inode-usage-install."
    WORK=$(mktemp -d "${WORK_PREFIX}XXXXXXXX") || die 8 "Could not create a temp directory under ${TMPDIR:-/tmp} to download into."
}

usage() {
    cat <<EOF
cPanel Inode Usage plugin installer ${SCRIPT_VERSION}
  sudo ./install.sh [--theme=NAME] [--dry-run] [--quiet]
  sudo ./install.sh --uninstall [--theme=NAME] [--dry-run]

  --theme=NAME  Theme to install into. Default: DEFMOD from ${WWWACCT_CONF}.
  --uninstall   Deregister the plugin and remove its application directory.
  --dry-run     Print the plan and touch nothing -- not even a temp file.
  --quiet       Progress off; warnings and errors still go to stderr.
  --version     Print ${SCRIPT_VERSION} and exit.        --help  This text.

Run from a checkout (payload beside the script), or standalone -- then the ${RELEASE_TAG} release tarball is
downloaded and its SHA256 checked against a value embedded here before anything is unpacked. Every
path this script can touch is listed under BLAST RADIUS at the top of the file.
EOF
}

parse_args() {
    local a
    for a in "$@"; do
        case $a in
            --theme=*)   THEME=${a#*=}; THEME_GIVEN=1 ;;
            --dry-run)   DRY_RUN=1 ;;
            --quiet)     QUIET=1 ;;
            --uninstall) MODE='uninstall' ;;
            --version)   printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
            -h|--help)   usage; exit 0 ;;
            *)           usage >&2; die 1 "Unknown option: ${a}" ;;
        esac
    done
}

preflight() {
    local u
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die 2 "Must run as root: sudo ./install.sh"
    [[ -r "${CPANEL_ROOT}/version" ]] || die 3 "${CPANEL_ROOT}/version not found; this is not a cPanel server."
    for u in install stat mktemp awk grep; do command -v "$u" >/dev/null 2>&1 || die 11 "Required utility '${u}' is not in PATH."; done
    if [[ $MODE == 'install' ]]; then
        [[ -x $INSTALL_PLUGIN ]] || die 4 "${INSTALL_PLUGIN} is missing or not executable. This script registers plugins only through cPanel's own tooling; it will not hand-write theme files."
        # Mandatory since 2.0.0: the only interpreter that can see the Cpanel:: tree, so the only one that can
        # verify the UAPI module. /usr/bin/perl cannot, and must not be substituted.
        [[ -x $CPANEL_PERL ]] || die 4 "${CPANEL_PERL} is missing or not executable; the UAPI module could not be verified."
    elif [[ ! -x $UNINSTALL_PLUGIN ]]; then warn "${UNINSTALL_PLUGIN} is missing; will remove the known paths directly."; fi
    [[ -x $SPRITE_GENERATOR ]] || warn "${SPRITE_GENERATOR} is missing; the icon may render from a stale sprite sheet."
    say "cPanel $(< "${CPANEL_ROOT}/version"), installer ${SCRIPT_VERSION}"
}

# Theme default is DEFMOD (what Cpanel::Config::LoadWwwAcctConf hands install_plugin), read with awk
# and no pipeline, so pipefail has nothing to interact with.
resolve_theme() {
    if (( ! THEME_GIVEN )); then
        [[ -r $WWWACCT_CONF ]] || die 5 "${WWWACCT_CONF} is unreadable and no --theme was given. Re-run with --theme=NAME."
        THEME=$(awk '$1=="DEFMOD"{print $2; exit}' "$WWWACCT_CONF")
        [[ -n $THEME ]] || die 5 "No DEFMOD entry in ${WWWACCT_CONF}. Re-run with --theme=NAME."
    fi
    # Exactly one directory component: rejects '.', '..', '/' and anything else that could escape
    # THEMES_DOCROOT, before the value is ever used to build a path.
    [[ $THEME =~ ^[A-Za-z0-9_-]+$ ]] || die 5 "Invalid theme name '${THEME}': allowed characters are A-Z a-z 0-9 _ -"
    THEME_ROOT="${THEMES_DOCROOT}/${THEME}"
    [[ -d $THEME_ROOT ]] || die 5 "No such theme directory: ${THEME_ROOT}"
    [[ ! -L $THEME_ROOT ]] || die 5 "${THEME_ROOT} is a symlink. Refusing to install through it."
    APP_DIR="${THEME_ROOT}/${APP_SUBDIR}"
    [[ ! -L "${THEME_ROOT}/dynamicui" ]] || die 5 "${THEME_ROOT}/dynamicui is a symlink. Refusing to write or delete a menu entry through it."
    DUI_CONF="${THEME_ROOT}/dynamicui/dynamicui_${PLUGIN_ID}.conf"
    say "Theme: ${THEME}$( (( THEME_GIVEN )) && printf ' (--theme)' || printf ' (DEFMOD)' )"
}

# <theme>/config.json is not optional: DynamicUI builds the icon destination from its .icon.path and
# sprite_generator pod2usage(2)s without one -- missing means a loose icon in the theme root and a
# dead sprite step. Read the path from it rather than hardcoding.
resolve_icon_dest() {
    local cfg="${THEME_ROOT}/config.json" path=''
    if [[ ! -f $cfg ]]; then   # fatal for install, survivable for uninstall
        [[ $MODE == 'uninstall' ]] || die 5 "${cfg} is missing. cPanel cannot place a plugin icon in a theme without it and ${SPRITE_GENERATOR} refuses to run against one. Repair the theme, or pass --theme=NAME for a complete one."
        warn "${cfg} is missing; assuming '${DEFAULT_ICON_SUBPATH}' for removal only."
    elif [[ -x $CPANEL_PERL ]]; then
        path=$("$CPANEL_PERL" -MCpanel::Branding::Lite::Config -e 'my $c = eval { Cpanel::Branding::Lite::Config::load_theme_config_from_file($ARGV[0]) };
            print $c->{icon}{path} if $c && ref $c->{icon} eq "HASH" && defined $c->{icon}{path};' "$cfg" 2>/dev/null) || path=''
    fi
    [[ -n $path ]] || path=$DEFAULT_ICON_SUBPATH
    path=${path#/}; path=${path%/}      # cPanel stores it as "assets/application_icons/"
    [[ -n $path && $path != *'..'* ]] || die 5 "Refusing icon path '${path}' from ${cfg}: empty or contains '..'."
    ICON_DIR="${THEME_ROOT}/${path}"
    [[ ! -L $ICON_DIR ]] || die 5 "${ICON_DIR} is a symlink. Refusing to place or remove an icon through it."
    # The installed basename is <PLUGIN_ID>.<ext>, NOT the source filename -- DynamicUI.pm
    # builds it from install.json's "id". They coincide today; not necessarily after v2.
    ICON_DEST="${ICON_DIR}/${PLUGIN_ID}.${ICON_FILE##*.}"
}

# A payload only sits beside a REAL file; anything else fails here and standalone mode takes over.
# Both pipe forms must land there: `bash <(curl ...)` gives /dev/fd/NN, `curl ... | bash` leaves
# BASH_SOURCE unset -- which must NOT fall back to $0 ('bash', dirname '.'), or the caller's $PWD
# silently becomes payload and trust root. CDPATH='' stops cd printing into $().
script_dir() { local s=${BASH_SOURCE[0]:-}; [[ -n $s && -f $s ]] || return 1; CDPATH='' cd -- "$(dirname -- "$s")" 2>/dev/null && pwd -P; }

locate_payload() {
    local here f
    here=$(script_dir) || here=''
    if [[ -n $here && -d "${here}/src" && -f "${here}/plugin/install.json" ]]; then
        PAYLOAD_DIR=$here
        say "Payload: ${PAYLOAD_DIR}"
    # An incomplete checkout fails loudly; it never silently becomes a network install of a different build.
    elif [[ -n $here && -f "${here}/install.sh" && ( -d "${here}/src" || -d "${here}/plugin" ) ]]; then
        die 6 "${here} looks like a checkout of this repository but is missing src/ or plugin/install.json. Re-clone rather than let this turn into a download of a different build."
    else
        download_payload
    fi
    PLUGIN_DIR="${PAYLOAD_DIR}/plugin"
    # -s, not -f: `perl -c` reports "syntax OK" for a zero-byte file (exactly as `php -l` did), so a
    # truncated clone would otherwise deploy 0 bytes and pass every downstream check.
    for f in "${PAYLOAD_FILES[@]}"; do
        [[ -s "${PAYLOAD_DIR}/src/${f}" ]] || die 6 "Missing or empty payload file ${PAYLOAD_DIR}/src/${f}; refusing to deploy a partial plugin."
    done
    MODULE_SRC="${PAYLOAD_DIR}/${MODULE_SRC_SUBPATH}"
    [[ -s $MODULE_SRC ]] || die 6 "Missing or empty ${MODULE_SRC}; refusing to deploy a page with no UAPI module behind it."
    # Ship-time self-check: both the upgrade and the uninstall path refuse to touch an unmarked file, so a
    # release without the marker could never be upgraded or removed by its own installer.
    grep -Fq -- "$MODULE_MARKER" "$MODULE_SRC" \
        || die 6 "${MODULE_SRC} carries no provenance marker; this build could never be upgraded or uninstalled. Fix the source."
    [[ -s "${PLUGIN_DIR}/${ICON_FILE}" ]] || die 6 "Missing or empty ${PLUGIN_DIR}/${ICON_FILE}."
    # cPanel names both the conf and the icon from "id": drift here would register files we could never find again.
    grep -Eq "\"id\"[[:space:]]*:[[:space:]]*\"${PLUGIN_ID}\"" "${PLUGIN_DIR}/install.json" \
        || die 6 "${PLUGIN_DIR}/install.json does not declare id \"${PLUGIN_ID}\"."
    grep -Eq "\"uri\"[[:space:]]*:[[:space:]]*\"${EXPECTED_URI//./\\.}\"" "${PLUGIN_DIR}/install.json" \
        || die 6 "${PLUGIN_DIR}/install.json does not declare uri \"${EXPECTED_URI}\"; payload and installer disagree."
}

download_payload() {
    local -a fetch tops; local got=''
    (( DRY_RUN )) && die 6 "--dry-run has no payload to inspect in standalone mode. Clone and dry-run there: git clone --branch ${RELEASE_TAG} --depth 1 https://github.com/${REPO_SLUG}.git"
    # Shape check, not a placeholder comparison: an unsubstituted marker, a truncated paste and a
    # stray newline all fail it, and none of them may reach the comparison as a "checksum".
    [[ $RELEASE_SHA256 =~ ^[0-9a-fA-F]{64}$ ]] \
        || die 8 "This build has no valid release checksum embedded, so a download cannot be verified. Refusing to fetch and run unverified code as root. Use: git clone --branch ${RELEASE_TAG} --depth 1 https://github.com/${REPO_SLUG}.git"
    command -v tar >/dev/null 2>&1 || die 11 "'tar' is not in PATH."
    fetch=()
    command -v curl >/dev/null 2>&1 && fetch=(curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --max-time 120 -o)
    (( ${#fetch[@]} )) || { command -v wget >/dev/null 2>&1 && fetch=(wget -q --https-only --tries=3 --timeout=60 -O); }
    (( ${#fetch[@]} )) || die 11 "Neither curl nor wget is available to download ${RELEASE_ASSET}."

    ensure_work
    say "Downloading ${RELEASE_URL}"
    "${fetch[@]}" "${WORK}/asset.tar.gz" "$RELEASE_URL" || die 8 "Download failed: ${RELEASE_URL}"
    if command -v sha256sum >/dev/null 2>&1; then
        read -r got _ < <(sha256sum -- "${WORK}/asset.tar.gz")
    elif [[ -x $CPANEL_PERL ]]; then
        got=$("$CPANEL_PERL" -MDigest::SHA -e 'print Digest::SHA->new(256)->addfile($ARGV[0])->hexdigest' "${WORK}/asset.tar.gz")
    else
        die 11 "No SHA256 implementation available."
    fi
    [[ ${got,,} == "${RELEASE_SHA256,,}" ]] || die 8 "Checksum mismatch for ${RELEASE_ASSET}: expected ${RELEASE_SHA256}, got ${got}. Not proceeding."
    mkdir -p "${WORK}/x"
    # As root, without these flags tar restores the archive's ownership, setuid bits and modes -- and
    # the icon's mode reaches the theme docroot verbatim (install_plugin copies with KeepMode=1).
    tar -xzf "${WORK}/asset.tar.gz" -C "${WORK}/x" --no-same-owner --no-same-permissions --no-absolute-names \
        || die 8 "Could not extract ${RELEASE_ASSET}."
    shopt -s nullglob; tops=("${WORK}/x"/*/); shopt -u nullglob   # our asset: one top-level dir
    (( ${#tops[@]} == 1 )) || die 6 "${RELEASE_ASSET} does not have the expected single top-level directory."
    PAYLOAD_DIR=${tops[0]%/}
    say "Payload: ${RELEASE_ASSET} (SHA256 verified)"
}

# Destructive-path guards. The private predecessor of this installer ended with `rm -rf "$(pwd)"` as
# root; that is what these make impossible. No delete target below derives from $(pwd), $0, or any
# unchecked caller string. DESTRUCTIVE OP (c) precondition: exact path, no '..', not a symlink.
assert_app_dir() {
    [[ $APP_DIR == "${THEMES_DOCROOT}/${THEME}/${APP_SUBDIR}" ]] || die 6 "Refusing to operate on '${APP_DIR}': it is not <theme root>/${APP_SUBDIR}."
    [[ $APP_DIR != *'..'* ]] || die 6 "Refusing to operate on a path containing '..'."
    [[ ! -L $APP_DIR ]] || die 6 "${APP_DIR} is a symlink. Remove it by hand and re-run."
    [[ ! -e $APP_DIR || -d $APP_DIR ]] || die 6 "${APP_DIR} exists but is not a directory. Remove it by hand and re-run."
}

# DESTRUCTIVE OP (d): the one file landing OUTSIDE the theme, in a directory cPanel owns and cpanelsync
# manages. (c)'s exact-path test with BOTH halves of the join pinned, plus the two questions cPanel's manifest
# and our own marker can answer. Every branch dies BEFORE any mutation.
assert_api_module() {
    [[ $MODULE_NAME =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || die 6 "Invalid MODULE_NAME '${MODULE_NAME}': must be a bare Perl package segment."
    [[ $API_DIR == "${CPANEL_ROOT}/Cpanel/API" && $MODULE_DEST == "${API_DIR}/${MODULE_FILE}" ]] \
        || die 6 "Refusing to operate on '${MODULE_DEST}': it is not ${CPANEL_ROOT}/Cpanel/API/${MODULE_FILE}."
    [[ $MODULE_DEST != *'..'* ]]               || die 6 "Refusing to operate on a path containing '..'."
    [[ -d $API_DIR && ! -L $API_DIR ]]         || die 6 "${API_DIR} is missing or is a symlink. Refusing to write or delete a UAPI module through it."
    [[ ! -L $MODULE_DEST ]]                    || die 6 "${MODULE_DEST} is a symlink. Remove it by hand and re-run."
    [[ ! -e $MODULE_DEST || -f $MODULE_DEST ]] || die 6 "${MODULE_DEST} exists but is not a regular file. Remove it by hand and re-run."
    # The manifest is the authority on which paths under Cpanel/ are cPanel's, and answers before the file
    # exists. A claim means THIS BUILD must be renamed: no admin can fix it, and installing anyway breaks a
    # cPanel feature server-wide until the next upcp silently reverts it and breaks us instead.
    if [[ -r $SYNC_MANIFEST ]]; then
        ! grep -Fq -- "$SYNC_CLAIM" "$SYNC_MANIFEST" \
            || die 6 "cPanel's sync manifest claims ./Cpanel/API/${MODULE_FILE}: this cPanel release ships a module at our path. Refusing to overwrite it. This build must be re-released under a different MODULE_NAME."
    else
        warn "${SYNC_MANIFEST} is unreadable; could not confirm cPanel does not ship ${MODULE_FILE}. Falling back to the provenance marker alone."
    fi
    # Second question: is the file already there ours? grep -F on a fixed string; no regex, no eval.
    if [[ -f $MODULE_DEST ]]; then
        grep -Fq -- "$MODULE_MARKER" "$MODULE_DEST" \
            || die 6 "${MODULE_DEST} exists but was not written by this installer (no provenance marker). Refusing to overwrite it. Nothing has been changed."
    fi
}

# DESTRUCTIVE OP (b): one regular file = already-validated dir + BARE filename (no separators, no dot-dot, no symlink), so no caller can turn it into a traversal.
remove_file_in() {
    local dir=$1 name=$2 target
    [[ -d $dir ]] || return 0
    [[ -n $name && $name != */* && $name != '.' && $name != '..' ]] || die 6 "Refusing to remove suspicious filename '${name}'."
    target="${dir}/${name}"
    [[ -f $target && ! -L $target ]] || return 0
    run rm -f -- "$target" || { warn "Could not remove ${target}; continuing."; return 0; }
    (( DRY_RUN )) || say "  removed ${target}"
}

# Deployed modes are 0644 root:root and NOT executable, matching every shipped vendor plugin here
# (imunify/php_selector/resource_usage .live.pl); app dir 0755 root:root. cPanel's handler runs them.
# The UAPI module is 0644 root:root for a different reason: it is require'd by the cPanel USER's uapi process
# (measured) and read by a 'nobody' one enumerating Cpanel/API/. cPanel's own 91 modules there are 0644
# root:root; the two 0777 WP Toolkit files are third-party and wrong.
deploy() {
    local f v='' size='' litter="${THEME_ROOT}/${LITTER_NAME}"
    if [[ ! -d $APP_DIR ]]; then say "Fresh install into ${APP_DIR}"
    else
        # `read` returns 1 at EOF-without-newline AFTER assigning: a bare `|| v=''` would discard a
        # good marker that merely lacks a trailing newline. Swallow the status, keep the value.
        [[ -f "${APP_DIR}/VERSION" ]] && { read -r v < "${APP_DIR}/VERSION" || : ; }
        if   [[ -z $v ]]; then warn "${APP_DIR} exists with no VERSION marker: it predates 2.0.0 or was installed by hand. Treating as an upgrade -- PAYLOAD_FILES replaced in place, STALE_FILES removed afterwards."
        elif [[ $v == "$SCRIPT_VERSION" ]]; then say "Version ${SCRIPT_VERSION} already installed; re-installing over it (idempotent)."
        else say "Upgrading ${APP_DIR} from ${v} to ${SCRIPT_VERSION}."; fi
    fi
    say "==> Deploying to ${APP_DIR} and ${MODULE_DEST}"
    # Both preconditions are settled before the first byte is written, so either refusal changes nothing.
    assert_app_dir
    assert_api_module
    # The module goes FIRST, deliberately: it is inert until something calls /execute/<Module>, and nothing
    # routes there without the page. The reverse order leaves a visibly broken menu item.
    run install -o root -g root -m 0644 "$MODULE_SRC" "$MODULE_DEST" \
        || die 7 "Failed installing ${MODULE_DEST}; it may now be truncated. Fix the cause (disk, I/O) and re-run."
    (( DRY_RUN )) || say "  ${MODULE_DEST}"
    run install -d -o root -g root -m 0755 "$APP_DIR" || die 7 "Could not create ${APP_DIR} (0755 root:root). Nothing was deployed."
    for f in "${PAYLOAD_FILES[@]}"; do
        run install -o root -g root -m 0644 "${PAYLOAD_DIR}/src/${f}" "${APP_DIR}/${f}" \
            || die 7 "Failed installing ${APP_DIR}/${f}; it may now be truncated. Fix the cause (disk, quota, I/O) and re-run."
        (( DRY_RUN )) || say "  ${f}"
    done
    # install(1), never `> .../VERSION`: a redirect writes THROUGH a symlink (chmod/chown follow it too), install unlinks first.
    run install -o root -g root -m 0644 /dev/stdin "${APP_DIR}/VERSION" <<<"$SCRIPT_VERSION" \
        || die 7 "Could not write ${APP_DIR}/VERSION."
    (( DRY_RUN )) || say "  VERSION (${SCRIPT_VERSION})"
    # Stale cleanup runs AFTER the payload lands, deliberately: delete-first means an interrupted
    # upgrade leaves the directory emptier than it started.
    for f in "${STALE_FILES[@]}"; do
        if [[ " ${PAYLOAD_FILES[*]} " == *" ${f} "* ]]; then warn "'${f}' is in both STALE_FILES and PAYLOAD_FILES; keeping it. Fix the manifest."
        else remove_file_in "$APP_DIR" "$f"; fi
    done
    if [[ -f $litter && ! -L $litter ]]; then
        size=$(stat -c '%s' -- "$litter" 2>/dev/null) || size=''
        if [[ $size == "$LITTER_SIZE" ]]; then remove_file_in "$THEME_ROOT" "$LITTER_NAME"
        else warn "${litter} is ${size:-unreadable} bytes, not the ${LITTER_SIZE}-byte pre-1.0 artifact. Not ours; leaving it."; fi
    fi
}

register() {
    local rc=0
    say "==> Registering the menu entry"
    if (( DRY_RUN )); then
        say "  [would run] ${INSTALL_PLUGIN} --theme=${THEME} ${PLUGIN_DIR}"
        say "              -> writes ${DUI_CONF}, copies the icon to ${ICON_DEST}"
        return 0
    fi
    # The repository's REAL plugin/ directory is passed as-is: install_plugin accepts a plain dir and
    # also reads sitemap.json and menu/ out of it (_has_custom_menus), so a staged copy holding only
    # install.json plus the icon would silently drop those. Its output is deliberately NOT captured:
    # install_plugin exits via POSIX::_exit(), skipping the stdio flush, so its stdout survives only
    # while a tty (line-buffered) -- $(...) makes it a block-buffered pipe and DESTROYS diagnostics.
    "$INSTALL_PLUGIN" --theme="$THEME" "$PLUGIN_DIR" || rc=$?
    # DynamicUI::_save copies the icon FIRST, then opens the conf with '>' -- a failure at step two
    # leaves an EXISTING conf truncated to zero bytes: corrupt, not absent.
    (( rc == 0 )) || die 9 "${INSTALL_PLUGIN} failed for theme '${THEME}' (exit ${rc}); its own output is above. Application files are deployed. Check ${DUI_CONF}: if it exists but is zero bytes it is corrupt, not missing. Fix the cause and re-run, or run --uninstall."
}

# --theme is NOT optional despite looking it: with no arguments sprite_generator falls back to
# $Cpanel::Config::Constants::DEFAULT_CPANEL_THEME ('jupiter'), NOT the server's DEFMOD. --application
# defaults to cpanel, passed explicitly so nobody has to check. install_plugin only QUEUES a rebuild
# (1s delay, byte-identical output), so running it here just makes the icon appear promptly.
sprites() {
    local out=''
    [[ -x $SPRITE_GENERATOR ]] || { say "==> Skipping sprites (${SPRITE_GENERATOR} absent)"; return 0; }
    say "==> Rebuilding icon sprites for '${THEME}'"
    if (( DRY_RUN )); then
        say "  [would run] ${SPRITE_GENERATOR} --application=cpanel --theme=${THEME}"
    elif out=$("$SPRITE_GENERATOR" --application=cpanel --theme="$THEME" 2>&1); then
        say "  sprites rebuilt"
    else
        warn "${SPRITE_GENERATOR} exited non-zero; cPanel's queued sprite task should still rebuild them. Output: ${out}"
    fi
}

chk_mode() { local m; m=$(stat -c '%a %U %G' -- "$1" 2>/dev/null) || m=''; [[ $m == "$2" ]] || fail "$1 is '${m:-missing}', expected '$2'."; }

# The deployed module must not merely parse: dispatch does ->can($function), so a name listed in %API but
# never defined is a runtime 404 with nothing in any log. This loads it and checks every name -- and NEVER
# calls one, so no home directory is walked and no account is touched.
verify_module() {
    local out
    chk_mode "$MODULE_DEST" '644 root root'
    # Keep the compiler's message -- it names the line, and is this step's only diagnostic.
    out=$("$CPANEL_PERL" -c -I"$CPANEL_ROOT" -- "$MODULE_DEST" 2>&1) \
        || { fail "perl -c failed for ${MODULE_DEST}: ${out}"; return 0; }
    out=$("$CPANEL_PERL" -I"$CPANEL_ROOT" -e 'no strict "refs"; my ($p,$m)=@ARGV; require $p;
            my %api = %{"Cpanel::API::${m}::API"} or die "no %API in Cpanel::API::$m\n";
            for ( sort keys %api ) { "Cpanel::API::$m"->can($_) or die "%API names $_ but Cpanel::API::$m cannot($_)\n" }' \
        -- "$MODULE_DEST" "$MODULE_NAME" 2>&1) \
        || fail "${MODULE_DEST} is not loadable as Cpanel::API::${MODULE_NAME}: ${out}"
}

verify_install() {
    local f line
    (( DRY_RUN )) && { say "==> [would run] verify modes/owner, perl -c and %API loadability of ${MODULE_DEST}, ${DUI_CONF} contains url=>${EXPECTED_URI}, and ${ICON_DEST} exists"; return 0; }
    say "==> Verifying"
    FAILURES=0
    chk_mode "$APP_DIR" '755 root root'
    for f in "${PAYLOAD_FILES[@]}" VERSION; do chk_mode "${APP_DIR}/${f}" '644 root root'; done
    verify_module
    # LOAD-BEARING, not decorative. Cpanel::Plugin::Install only WARNS when the SiteMap fails to load,
    # then returns _add_plugins_to_feature_manager(), a hardcoded 1 for an empty feature list -- and
    # ours IS empty (install.json sets featuremanager:false). install_plugin can therefore exit 0
    # having written no conf at all, and this check is the only thing that notices.
    if [[ -f $DUI_CONF ]]; then
        # NO PIPELINE, deliberately: `tr ... < f | grep -q x` makes grep exit at the first match and
        # SIGPIPE the producer, so under pipefail the pipeline FAILS ON SUCCESS. Match in the shell,
        # comma-wrapped so a trailing ".bak" cannot pass.
        line=$(< "$DUI_CONF")
        [[ ",${line}," == *",url=>${EXPECTED_URI},"* ]] || fail "${DUI_CONF} has no exact url=>${EXPECTED_URI} field."
        # Cpanel::Themes::Serializer::DynamicUI copies install.json's "uri" straight into url=> with no
        # validation, so nothing else ever checks that the menu entry points at a file that exists.
        [[ -f "${THEME_ROOT}/${EXPECTED_URI}" ]] || fail "${DUI_CONF} points at ${EXPECTED_URI} but ${THEME_ROOT}/${EXPECTED_URI} does not exist."
    else
        fail "menu entry ${DUI_CONF} is missing."
    fi
    [[ -f $ICON_DEST ]] || fail "icon ${ICON_DEST} is missing."
    (( FAILURES == 0 )) || die 10 "${FAILURES} verification check(s) failed; the plugin may be partially installed. Fix the cause and re-run, or: bash install.sh --uninstall --theme=${THEME}"
    say "  all checks passed"
}

do_uninstall() {
    local p declined=0 mdeclined=0; local -a left
    say "==> Deregistering the menu entry"
    if [[ -x $UNINSTALL_PLUGIN && -n $PLUGIN_DIR && -f "${PLUGIN_DIR}/install.json" ]]; then
        if (( DRY_RUN )); then say "  [would run] ${UNINSTALL_PLUGIN} --theme=${THEME} ${PLUGIN_DIR}"
        else "$UNINSTALL_PLUGIN" --theme="$THEME" "$PLUGIN_DIR" || warn "${UNINSTALL_PLUGIN} exited non-zero; removing the known paths below regardless."; fi
    else
        say "  no usable plugin manifest beside this script; removing the known paths directly"
    fi
    # NOT an else-branch, deliberately -- the mirror of the load-bearing install-side check.
    # uninstall_plugin only WARNS when the SiteMap fails to load (any other vendor's malformed file in
    # dynamicui/ does it), then returns a hardcoded 1 and prints "Plugin uninstalled ok": exit 0 does
    # NOT mean conf and icon are gone. Never gate removal on it. Both are no-ops when already gone.
    remove_file_in "${THEME_ROOT}/dynamicui" "dynamicui_${PLUGIN_ID}.conf"
    remove_file_in "$ICON_DIR" "${PLUGIN_ID}.${ICON_FILE##*.}"
    # DESTRUCTIVE OP (c). uninstall_plugin removes the conf and icon but NEVER the app directory.
    say "==> Removing ${APP_DIR}"
    assert_app_dir
    # Shape is proven above, ownership is not: refuse to rm -rf a dir with none of our fingerprints.
    if [[ ! -d $APP_DIR ]]; then say "  already gone"
    # LEGACY_ENTRY_POINT is here so --uninstall still recognises a PRE-RELEASE v1 install, which has neither a
    # VERSION marker nor index.html.tt and would otherwise be declined.
    elif [[ -f "${APP_DIR}/VERSION" || -f "${APP_DIR}/${ENTRY_POINT}" || -f "${APP_DIR}/${LEGACY_ENTRY_POINT}" ]]; then
        run rm -rf -- "$APP_DIR" || die 10 "Could not remove ${APP_DIR}. The menu entry is already deregistered; remove the directory by hand."
        (( DRY_RUN )) || say "  removed"
    # Still DESTRUCTIVE OP (c): same assert_app_dir-validated target, strictly weaker verb. An EMPTY
    # dir is safe to drop and this installer can create one (install -d succeeds, then the first
    # payload copy fails on a full disk); rmdir refuses a non-empty dir. Declining is a decision, not
    # a failure -- `declined` keeps APP_DIR out of the verify, which would else exit 10 on every retry.
    elif run rmdir -- "$APP_DIR" 2>/dev/null; then (( DRY_RUN )) || say "  removed (was empty)"
    else
        warn "${APP_DIR} has none of a VERSION marker, ${ENTRY_POINT} or ${LEGACY_ENTRY_POINT} and is not empty: no evidence it is ours. NOT deleting it. If it really is, remove it by hand: rm -rf ${APP_DIR}"
        declined=1
    fi
    # DESTRUCTIVE OP (d), removal side, AFTER the page on purpose: menu entry, then page, then module, so the
    # module never disappears out from under a still-reachable page. Same guards, but a foreign or unmarked
    # file WARNS and declines rather than dying -- the theme side is already gone, so aborting would leave the
    # uninstall half-done.
    say "==> Removing ${MODULE_DEST}"
    if [[ ! -e $MODULE_DEST ]]; then say "  already gone"
    elif [[ $MODULE_DEST != "${CPANEL_ROOT}/Cpanel/API/${MODULE_FILE}" || $MODULE_DEST == *'..'* \
         || ! -d $API_DIR || -L $API_DIR || ! -f $MODULE_DEST || -L $MODULE_DEST ]]; then
        warn "${MODULE_DEST} failed its removal preconditions (wrong path, symlink, or not a regular file). NOT deleting it."; mdeclined=1
    elif ! grep -Fq -- "$MODULE_MARKER" "$MODULE_DEST"; then
        warn "${MODULE_DEST} carries no provenance marker: no evidence this installer wrote it. NOT deleting it. If it really is ours, remove it by hand."; mdeclined=1
    elif run rm -f -- "$MODULE_DEST"; then (( DRY_RUN )) || say "  removed"
    else warn "Could not remove ${MODULE_DEST}; remove it by hand."; mdeclined=1; fi
    sprites   # deliberately NOT the theme-root data.zip: our plugin never created it
    if (( DRY_RUN )); then say "==> [would run] verify all four paths are gone"; return 0; fi
    say "==> Verifying removal"
    FAILURES=0
    # Declining is a decision, not a failure: a declined path stays out of this list, or every subsequent
    # --uninstall would exit 10 forever.
    left=("$DUI_CONF" "$ICON_DEST"); (( declined )) || left+=("$APP_DIR"); (( mdeclined )) || left+=("$MODULE_DEST")
    for p in "${left[@]}"; do [[ ! -e $p ]] || fail "still present: ${p}"; done
    (( FAILURES == 0 )) || die 10 "${FAILURES} path(s) remain. Remove them by hand."
    say "  removed cleanly. Users may need a hard refresh (Ctrl-Shift-R) to drop the cached menu."
}

main() {
    local here
    parse_args "$@"
    preflight
    resolve_theme
    resolve_icon_dest
    (( DRY_RUN )) && say "-- DRY RUN: nothing below is executed; no file, not even a temp dir, is created --"
    if [[ $MODE == 'uninstall' ]]; then
        here=$(script_dir) || here=''
        # Same id check locate_payload does: uninstall_plugin deletes the conf and icon named by the
        # "id" in whatever manifest it is handed, so an unchecked dir here would deregister SOMEONE
        # ELSE'S plugin. A wrong or missing manifest falls through to the guarded direct removal.
        if [[ -n $here && -d "${here}/src" && -f "${here}/plugin/install.json" ]] \
            && grep -Eq "\"id\"[[:space:]]*:[[:space:]]*\"${PLUGIN_ID}\"" "${here}/plugin/install.json"; then
            PLUGIN_DIR="${here}/plugin"
        fi
        do_uninstall
        return 0
    fi
    locate_payload
    deploy
    register
    sprites
    verify_install
    say ""
    say "$( (( DRY_RUN )) && printf 'Plan complete; nothing changed.' || printf 'Installed.' ) The plugin lives at /frontend/${THEME}/${EXPECTED_URI} -- cPanel home > Files > Inode Usage."
    say "Users must hard-refresh (Ctrl-Shift-R / Cmd-Shift-R): the menu and the icon sprite are browser-cached."
}

main "$@"
