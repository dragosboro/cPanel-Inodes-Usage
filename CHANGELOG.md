# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [2.0.0] - 2026-08-06

**First public release.** There is no public 1.x. A 1.0.0 was prepared — a corrected
version of the original PHP implementation, self-contained and with a real
uninstall path — and then dropped rather than shipped, because no amount of
correction fixes the thing that matters most: a `.live.*` page cannot be served
to an account that is over quota, which is exactly the account whose owner opens
an inode usage tool.

The version number starts at 2.0.0, not 1.0.0, because pre-release copies of the
older code are installed in the field from the original vendor tarball. A `1.0.0`
version marker would be ambiguous against them; `2.0.0` is not. The installer
recognises those installs and upgrades them in place.

Everything described under *Fixed* below was a real, reproducible defect in code
that has been running on production servers.

### Architecture

- **The plugin is now a Template Toolkit page plus a custom UAPI module. There is
  no `.live.php` and no `.live.pl` handler.**
  - `base/frontend/<theme>/inode_usage/index.html.tt` is rendered by cPanel with
    the same chrome as its own pages.
  - `/usr/local/cpanel/Cpanel/API/ChemiCloudInodeUsage.pm` is a standard UAPI
    module, reached over cPanel's `/execute/` endpoint the same way cPanel's own
    front-end code reaches `Quota` or `Fileman`. It runs as the cPanel user, not
    as root.
  - The reason is not tidiness. To serve any `.live.*` page cPanel creates a unix
    socket inside the user's home directory *before* the handler is dispatched.
    Over quota that fails, and the handler never runs at all — a PHP handler
    returns HTTP 500, a Perl handler returns HTTP 200 whose entire body is
    `[A fatal error or timeout occurred while processing this directive.]`.
    Guarding inside the handler does not help; the handler is never reached.
    A Template Toolkit page and a UAPI module have no such step, and both were
    measured working on an account that was over quota.
- The module name is deliberately vendor-prefixed. `Cpanel/API/` is cPanel's own
  namespace and is synchronised from cPanel's manifests on every update, so a
  generic name there is a collision waiting to happen. The plugin id, the
  application directory and the icon keep the plain `inode_usage` name, because
  those live in namespaces this plugin already owns.

### Added

- `plugin/install.json` and `plugin/inode_usage.svg` are tracked in the
  repository. Neither had ever been committed: both existed only inside the
  vendor tarball, so a clone of this repository was never sufficient to install
  the plugin. The SVG is byte-identical to the icon already deployed on
  production servers, so upgrading in place does not move or redraw the icon.
- A real uninstall path (`./install.sh --uninstall`, or the `uninstall.sh`
  wrapper). cPanel's own `uninstall_plugin` removes the `dynamicui` entry and the
  theme icon but deliberately leaves the application directory behind; the
  installer removes the application directory and the UAPI module itself, each
  confined to an explicit absolute path and each refused unless the file on disk
  is identifiably the one this project installed.
- `--dry-run`, which prints every action that would be taken and is guaranteed to
  make zero changes, including creating no temporary directory.
- `--theme=NAME`. Without it the theme is resolved from `DEFMOD` in
  `/etc/wwwacct.conf` the way cPanel resolves it, rather than being hardcoded to
  `jupiter`.
- A `VERSION` marker in the application directory, so an installed copy can be
  identified without guessing from timestamps.
- Post-install verification: owner and mode on every deployed path, a `perl -c`
  syntax check and a load check on the UAPI module (which confirms every function
  named in `%API` is actually dispatchable — a typo there is a silent 404 at run
  time), and confirmation that the `dynamicui` entry points at the file that was
  really deployed.
- A wall-clock budget, default 25 seconds, and a hard entry ceiling. Exceeding
  either returns the partial result with a `truncated` flag instead of hanging.
- A per-account lock, so one account cannot start several concurrent walks, plus
  a one-walk-per-process cap. `Cpanel::API::Batch` runs every command of a batch
  in a single process, sequentially, with no limit on the command count and no
  timeout on that path, so without the cap one request could ask for an unbounded
  number of consecutive full-budget walks.
- A per-level cap on how many subdirectory rows are emitted (5,000). The walk was
  bounded; the response was not. A home with 200,000 immediate subdirectories
  trips neither the time budget nor the entry ceiling and would have produced a
  ~45 MB response and 200,000 table rows. Directories left out are still counted,
  and the number omitted is reported and shown.
- An adaptive I/O duty cycle. `IOPRIO_CLASS_IDLE` is honoured only by the BFQ and
  CFQ I/O schedulers and is ignored under `blk-mq` `none`, so on most current
  servers it does nothing; `nice(19)` throttles CPU, and this walk is bound by
  metadata I/O. When a batch of directory reads is slow enough to mean real disk
  access, the walk now pauses for a fraction of that time. On a warm cache it
  never triggers: measured at no detectable cost over a 63,426-entry tree.
- The page reports when the quota lookup was unavailable instead of silently
  labelling the walked home subtotal as the account Total.
- Reloading the page during a slow scan retries briefly instead of reporting that
  a scan is already running. The abandoned walk keeps running to completion and
  holds the per-account lock while it does.
- Self-throttling. cpsrvd does not run inside LVE or CageFS, so nothing else on a
  shared server limits this walk; it lowers its own scheduling and I/O priority.
- `SECURITY.md`, `.editorconfig`, `.gitignore`, `VERSION`, and this changelog.

### Fixed

- **The scan no longer dies on a directory it cannot read.** The old walk aborted
  outright the first time it reached a `nobody`-owned LiteSpeed cache directory
  inside the account's home — a common layout — and the page simply failed.
  Unreadable directories are skipped.
- **The drill-down endpoint validates its input.** The old endpoint took an
  absolute directory path in a query parameter and listed it, with no check that
  the path was inside the requesting account's home directory. It ran with that
  authenticated user's own privileges and returned directory names and counts,
  not file contents, so it granted no read access the user did not already have
  from a shell — but on a shared server it was a convenient enumerator for paths
  outside the home directory. The replacement takes a **home-relative** path; the
  base is derived server-side from the account's own home directory and is never
  taken from the client; the joined path is resolved and must land on the home
  directory or inside it. Outside-home, nonexistent and unreadable all produce an
  identical empty response, so the endpoint cannot be used to test for the
  existence of a path.
- **The double walk is gone.** The old page walked the tree roughly twice per
  load, once for the per-directory rows and once again for the account total, and
  on large accounts that could exceed the request timeout and fail rather than
  render slowly. The total and the limit now come from `Cpanel::Quota::displayquota`
  — the same call and the same `/var/cpanel/repquota.cache` behind cPanel's own
  `Quota::get_quota_info`, called directly so that "quotas are disabled here" stays
  distinguishable from "zero inodes used" — and is O(1) — and is the same figure
  cPanel's sidebar shows, so the two can no longer disagree. The rows come from a
  single iterative walk that accumulates a recursive subtotal for every directory
  at every depth in one pass, so expanding a folder in the UI never triggers a
  second scan. Measured on a 274,011-inode account, the single-pass walk took
  2.2–5.5 seconds of CPU depending on the strategy benchmarked, and computing
  subtotals for every depth rather than only the top level cost about 1.25× the
  depth-1 walk.
- **Directory names are rendered as text, never as markup.** Rows are built with
  `createElement` and `textContent`. A directory named
  `x<img src=x onerror=alert(1)>&"test` renders as that string.
- **The File Manager link is a relative URL.** It was built from the request's
  `Host` header — which cpsrvd accepts from the client — with a hardcoded `:2083`.
  That was both client-influenced and broken behind a proxy.
- **The expand chevron reverts when an expansion fails** instead of staying open
  against an empty row.
- **Expanded levels sort descending**, matching the top level. `insertBefore`
  inside the loop reversed the server's already-sorted array, so every expanded
  level rendered ascending while the top level rendered descending.
- **The walk cannot be raced out of the home directory.** Between the `lstat`
  that decided an entry was a directory and the `opendir` that descended into it,
  the account could rename that entry to a symlink pointing anywhere — `opendir`
  re-resolves a path string from `/` and does not use `O_NOFOLLOW`. The device
  check was no protection: on a typical server `/`, `/etc`, `/home` and the cPanel
  root are all one filesystem. The walk now confirms that the directory handle it
  opened is the same `(device, inode)` it validated, which is the check the
  request-path resolver already performed. Demonstrated with a race harness: the
  unpatched walk emitted rows naming directories outside the home; the patched one
  emitted none.
- **A row's number now equals what that row contributes to its parent.** Every
  directory seeded its own subtotal at 1 but contributed only its ownership flag
  upward, so each `nobody`-owned directory made the children of a row sum to one
  more than the row itself, and `listed_inodes` could exceed `counted_inodes` —
  quietly wrong arithmetic on a page whose Total row invites reconciliation.
- **Clicking a folder twice while it is loading no longer duplicates rows.** The
  second click collapsed the row but left it flagged as loading; the in-flight
  response then inserted its children under a collapsed chevron, and a third click
  inserted a second copy that nothing could ever collapse. An expand is now
  invalidated when the row is collapsed or re-clicked.
- **Collapsing a folder while a child is loading no longer raises an error
  dialog.** The child row was detached, so the insert threw a `TypeError` that was
  shown to the user as `Error fetching subfolders: Cannot read properties of null`.
- **A partial result from an expansion is reported.** The truncation flag on a
  drill-down response was discarded, so a shortened child list read as complete.
- **The wall-clock budget uses a monotonic clock**, so an NTP step during a walk
  cannot move the deadline.
- **Correct content types** on responses, and accessibility attributes on the
  page's interactive elements.
- Ownership filtering is applied consistently. Previously only the top-level
  endpoint filtered by owner, so the top-level totals and the drill-down could
  disagree for accounts containing files owned by another uid. Every entry is
  counted only when its owner matches the account's UID; on the test account this
  correctly excluded 50 `nobody`-owned inodes.
- Counting uses `lstat` only and never follows a symlink, for counting or for
  descent. Hard links are de-duplicated by `(device, inode)`, and device
  boundaries are not crossed.
- The installer removes the three pre-release `.live.php` endpoints from the
  application directory on upgrade. Leaving them would leave the unvalidated
  drill-down reachable at its old URL on every server that "upgraded".
- The installer removes `base/frontend/<theme>/data.zip`, a 43 KB leftover
  dropped into the theme root by a partial run of the old installer. It is
  matched by exact size (43472 bytes), not by name, so an unrelated file of the
  same name in that shared directory is reported and left in place; and it is
  removed on install only, never on `--uninstall`.

### Changed

- **The repository is self-contained.** `install.sh` no longer downloads anything
  from a personal domain. The previous installer fetched `inode_usage.tar.gz` and
  `data.zip` at install time; `data.zip` had begun returning HTTP 404, so recent
  installs registered the icon and the `dynamicui` entry but never populated the
  application directory — the icon 404'd and the feature did not work at all. All
  payload ships in this repository and is copied from the checkout. The only
  network fetch anywhere in the project is the optional one-liner, which
  downloads a single checksum-pinned release asset from GitHub.
- `install.sh` rewritten from scratch:
  - `set -Eeuo pipefail`, and preflight checks for root, for a real cPanel
    installation, for the required cPanel tooling and system utilities, and for
    the requested theme — all of which fail before anything is modified.
  - Idempotent: re-running installs cleanly over an existing copy instead of
    stopping at an interactive `unzip` overwrite prompt. That prompt was
    unanswerable under the documented `bash <(curl …)` one-liner, because stdin
    was the script itself, so a second run simply hung.
  - Permissions and ownership are set atomically with `install(1)` rather than by
    a later `chmod`/`chown`, so a file is never briefly world-writable or owned
    by the wrong user. Deployed files are `0644 root:root`, the application
    directory is `0755 root:root`.
  - Every destructive operation targets a path validated against an explicit
    absolute literal, and refuses symlinks and any path containing `..`. The
    unguarded `rm -rf "$(pwd)"` that terminated an earlier internal version of
    this script, running as root, is gone and will not return.
  - The installer now writes one file outside the theme directory — the UAPI
    module. That destination carries the same class of guard as the others: an
    exact-path comparison against `/usr/local/cpanel/Cpanel/API/`, no `..`,
    neither the directory nor the file may be a symlink, the path must not be
    claimed by cPanel's own `cpanelsync` manifest, and an existing file must
    carry this project's provenance marker or the installer refuses to touch it
    and exits without changing anything.
  - Failure paths report a distinct exit code and state whether anything changed.
- The `dynamicui` entry is written only into the `dynamicui/` drop-in directory,
  by way of cPanel's `install_plugin`. The single `<theme>/dynamicui.conf` file is
  `cpanelsync`-managed and is rewritten by cPanel updates; it is never touched.
  Writing into the drop-in directory updates its mtime, which is already
  sufficient to invalidate every user's cached menu, so the installer never
  reaches into `/home/*/.cpanel/caches/` — or into `/home` at all.
- Sprite generation runs synchronously after registration. `install_plugin` only
  queues it through `Cpanel::ServerTasks`, which left a window where the new icon
  rendered as a blank tile.
- Documentation presents `git clone --branch <tag>` followed by
  `sudo ./install.sh` as the primary installation method. The pinned
  `bash <(curl -fsSL …)` one-liner remains documented as a convenience, with the
  trade-off stated plainly.
- `install.sh` stays at the repository root. The ChemiCloud blog post and the
  existing public forks reference that exact path.
- `featuremanager` stays `false` in `plugin/install.json`. This is deliberate:
  flipping it to `true` would make the icon disappear for every existing customer
  whose hosting package predates the feature and does not have it enabled.
  Revisiting it is deferred to a release where the package change can be
  coordinated.

### Removed

- The three PHP endpoints, `index.live.php`, `fetch_inode_data.live.php` and
  `fetch_subfolders.live.php`. They are not superseded in place; they are deleted
  from any application directory the installer upgrades.
- The dependency on a PHP interpreter being available to cPanel's internal web
  server. Nothing in the plugin is PHP any more.

[Unreleased]: https://github.com/dragosboro/cPanel-Inodes-Usage/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/dragosboro/cPanel-Inodes-Usage/releases/tag/v2.0.0
