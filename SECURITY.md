# Security Policy

This project ships an installer that is intended to be run as **root** on a
production cPanel server, and two web endpoints that are served to every hosting
account on that server. Please treat security reports here as you would for any
privileged system tool.

## Supported versions

| Version | Supported          | Notes                                                        |
| ------- | ------------------ | ------------------------------------------------------------ |
| 2.2.0   | Yes                | Current release. Security fixes land here.                    |
| 2.1.0   | No                 | Upgrade to 2.2.0. Fixes are not backported. |
| 2.0.0   | No                 | Upgrade to 2.2.0. Fixes are not backported. Note that 2.0.0's standalone (`bash <(curl …)`) install path is broken — it always fails at extraction — so any 2.0.0 install came from a checkout. |
| < 2.0.0 | No                 | There is no public 1.x. Anything older is a pre-release copy of the PHP implementation, installed from the original vendor tarball, which fetched its payload from an external personal domain that no longer serves it. Those installs are broken as well as unsupported, and one of their endpoints does not confine its path parameter to the caller's home directory — upgrade to 2.0.0 (the installer removes those endpoints) rather than reporting issues against them. |

There is no long-term support branch. Fixes are released as a new patch version
of the newest minor release; older minors are not backported.

If you are unsure which version is installed, check the version marker the
installer writes:

```
cat /usr/local/cpanel/base/frontend/jupiter/inode_usage/VERSION
```

An installation with no `VERSION` file predates 2.0.0 and is a pre-release copy.

## Reporting a vulnerability

**Do not open a public issue, pull request, or discussion for a security
problem.** A public report tells every operator running this plugin about the
weakness at the same moment it tells the maintainer.

Report privately through **GitHub Security Advisories**:

1. Go to <https://github.com/dragosboro/cPanel-Inodes-Usage/security/advisories>
2. Click **Report a vulnerability**
3. Fill in the affected version, impact, and reproduction steps

This creates a private thread visible only to you and the maintainers, and it is
the preferred channel.

<!-- TODO(maintainer): if you want a non-GitHub reporting channel, add a real,
     monitored address here and delete this comment. Do not publish an address
     that nobody reads — a dead security contact is worse than none, because it
     silently absorbs reports. Suggested wording once the address exists:
     "If you cannot use GitHub Security Advisories, email <address>." -->

> **Email:** not currently offered. Use GitHub Security Advisories above. *(A
> private email contact may be added here later; until this line changes, GitHub
> is the only monitored channel.)*

### What to include

- The plugin version, cPanel version, theme, and OS.
- Whether the issue is in the installer, in one of the endpoints, or in the
  packaging.
- Concrete reproduction steps, and what an attacker gains.
- Whether the issue is already public anywhere.

### What to expect

This project is maintained by one person alongside other work, so these are
honest targets rather than a contractual SLA:

| Stage                                          | Target            |
| ---------------------------------------------- | ----------------- |
| Acknowledgement that the report was received    | within 3 business days |
| Initial assessment (valid / not / need more info) | within 7 business days |
| Fix or documented mitigation for a confirmed high-severity issue | within 30 days |
| Fix for lower-severity issues                   | next release      |

If you have not heard anything after 7 business days, please ping the advisory
thread — it means the notification was missed, not that the report was ignored.

Coordinated disclosure is requested: please allow a fix to ship before
publishing details. Credit is given in the release notes and the advisory unless
you ask otherwise. There is no bug bounty.

## Scope

### In scope

**The installer (`install.sh`, `uninstall.sh`)** — it runs as root, so anything
that lets it write, delete, or execute outside its declared targets matters.
Specifically in scope:

- Any path by which the installer touches something other than
  `/usr/local/cpanel/base/frontend/<theme>/inode_usage/`, the theme's
  `dynamicui/` drop-in entry, the theme's `application_icons/` entry, the UAPI
  module at `/usr/local/cpanel/Cpanel/API/ChemiCloudInodeUsage.pm`, the
  size-matched `data.zip` removal in the theme root, and its own `mktemp`
  scratch directory.
- Symlink attacks, `TMPDIR` manipulation, or races against the scratch
  directory or the target directory.
- Injection through arguments, environment, or the resolved theme name.
- Anything that causes `--dry-run` to modify state; it is documented as making
  zero changes.
- Failure modes that leave a partially installed or partially removed plugin
  without a non-zero exit and a clear message.
- Files deployed with wrong ownership or mode (they must be `0644 root:root`,
  in a `0755 root:root` directory) — including the UAPI module, which is the one
  path installed outside the theme.
- Anything that lets the installer write to, or delete, a path other than the
  ones it documents under BLAST RADIUS, or that defeats the manifest and
  provenance-marker checks guarding `/usr/local/cpanel/Cpanel/API/`.
- Problems in the pinned `bash <(curl …)` convenience path, including checksum
  verification.

**The cPanel endpoints** — the Template Toolkit page (`src/index.html.tt`) and
the UAPI module (`lib/Cpanel/API/ChemiCloudInodeUsage.pm`), served to
authenticated hosting accounts and executing as the calling account's own Unix
user:

- Anything that lets one account read, infer, or affect another account's data.
- Privilege escalation beyond the calling user's own Unix privileges.
- Path traversal or containment failures. `list_subfolders` takes a
  **home-relative** path, derives the base server-side, resolves the join, and
  requires the result to be the home directory or inside it; the walk verifies
  that every directory handle it opened is the inode it validated. Any input, or
  any race, that gets either of them to report on a path outside the account's
  home directory is in scope and wanted.
- Any difference — in body, status, or timing — between the responses for
  outside-home, nonexistent and unreadable paths, since that difference would be
  an existence oracle.
- Cross-site scripting via file or directory names rendered into the page.
- Cross-site request forgery against the endpoints.
- Denial of service that a single account can inflict on the whole server, as
  opposed to slowing down its own page load.

**Packaging** — a release tarball whose contents do not match the tagged source,
or a checksum embedded in `install.sh` that does not match the published asset.

### Out of scope

- Vulnerabilities in cPanel & WHM itself, CloudLinux, LiteSpeed, Imunify360, or
  PHP. Report those to their vendors. If cPanel changes behaviour in a way that
  makes *this* plugin unsafe, that is in scope here.
- The known performance characteristics already documented in the README: the
  tree is walked synchronously once per page load under a wall-clock budget, so a
  very large home directory makes that account's own page slow or returns a
  partial result. A report is in
  scope only if it demonstrates impact on *other* accounts or on the server as a
  whole.
- Over-quota failures of the pre-2.0 `.live.php` endpoints (an HTTP 500 raised
  in cPanel's `.live.*` socket setup before any plugin code runs). Those
  endpoints are removed by the 2.0.0+ installer. The current page is expected
  to work over quota — a failure of *this* page on an over-quota account IS in
  scope.
- Findings that require root on the server, or physical/console access. If you
  are already root, the installer is not your obstacle.
- Anything requiring the operator to have deliberately deviated from the
  documented install — hand-edited files under
  `/usr/local/cpanel/base/frontend/`, modified `dynamicui` entries, or a
  third-party fork.
- Missing hardening headers, TLS configuration, or cookie flags on the cPanel
  interface itself; the plugin does not control those.
- Automated scanner output submitted without a working reproduction or a stated
  impact.
- Social engineering, spam, or physical attacks against the maintainer or any
  hosting provider using this plugin.

## Notes for operators

- Read `install.sh` before running it as root. That is precisely why the
  documentation recommends `git clone --branch <tag>` and a local
  `sudo ./install.sh` over piping a script from the network.
- Run `sudo ./install.sh --dry-run` first. It prints every action it would take
  and changes nothing.
- This release removed all remote fetching at install time. If you find a copy of
  the installer that downloads `inode_usage.tar.gz` or `data.zip` from a personal
  domain, it is a pre-release copy — discard it.
- The plugin is registered only through cPanel's own
  `/usr/local/cpanel/scripts/install_plugin` and the `dynamicui/` drop-in
  directory. It never edits the `cpanelsync`-managed `<theme>/dynamicui.conf`,
  and it never writes into `/home`.
