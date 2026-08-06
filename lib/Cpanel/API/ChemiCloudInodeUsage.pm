package Cpanel::API::ChemiCloudInodeUsage;

# cPanel-Inodes-Usage plugin -- https://github.com/dragosboro/cPanel-Inodes-Usage
#
# Repository path: lib/Cpanel/API/ChemiCloudInodeUsage.pm, which mirrors the
# deployed path /usr/local/cpanel/Cpanel/API/ChemiCloudInodeUsage.pm
# (root:root 0644). The line above is this project's PROVENANCE MARKER: the
# installer greps for it verbatim before it will overwrite or delete the
# deployed file, and refuses if it is absent. Do not reword it.
#
# Copyright (C) 2026  the cPanel-Inodes-Usage authors
# SPDX-License-Identifier: GPL-3.0-or-later

use strict;
use warnings;

our $VERSION = '2.2.0';

use Cwd         ();
use Fcntl       ();
use POSIX       ();
use Time::HiRes ();

use Cpanel::JSON    ();
use Cpanel::PwCache ();

=encoding utf-8

=head1 NAME

Cpanel::API::ChemiCloudInodeUsage - inode accounting for the Inode Usage cPanel plugin

=head1 NAMING

=over 4

=item * Package: C<Cpanel::API::ChemiCloudInodeUsage>

=item * Deployed file: F</usr/local/cpanel/Cpanel/API/ChemiCloudInodeUsage.pm>

=item * Endpoints: C</execute/ChemiCloudInodeUsage/get_usage> and
C</execute/ChemiCloudInodeUsage/list_subfolders>

=back

F</usr/local/cpanel/Cpanel/API/> is cPanel's own, cpanelsync-managed namespace.
The plain name C<InodeUsage> was rejected: it sits next to cPanel's
F<ResourceUsage.pm>, F<Bandwidth.pm> and F<Quota.pm> and is exactly the name
cPanel would choose if it ever shipped this feature, at which point cpanelsync
would overwrite this file on update and silently break the plugin for every
account on the server. Every third-party module in that directory here is
vendor-named (F<JetBackup5.pm>, F<Sitejet.pm>, F<WpToolkitCli.pm>); we follow
the same convention with a token cPanel will never ship. The namespaces this
project already owns -- the plugin id, the theme subdirectory, the icon --
deliberately keep the plain C<inode_usage>.

=head1 EXECUTION CONTEXT

UAPI modules run B<as the cPanel user>, in a short-lived F</usr/local/cpanel/uapi>
process that C<cpsrvd> forks and execs per request (see
C<Cpanel::XML::cpanel_exec_fast>). Filesystem permissions are therefore a real
baseline defence, and the process-wide self-throttling below cannot leak into
another request or another account. Path containment is still mandatory: without
it these endpoints are a filesystem enumeration oracle for anything the account
can read.

One exception to "one process, one call": C<Cpanel::API::Batch> runs every
command of a batch B<in the same process, sequentially, with no cap on the
command count>, and nothing on that path imposes a timeout. K copies of
C<get_usage> in one C</execute/Batch/strict> request would otherwise be K
consecutive full-budget walks holding one C<cpsrvd> child, and the one-way
C<nice(19)> would leak into every later command in the batch. Hence
C<$MAX_WALKS_PER_PROCESS>: the second walk in a process is refused with the
ordinary "busy" response.

Unlike C<.live.php> / C<.live.pl> handlers, UAPI works for over-quota accounts:
no unix socket is created in the user home before dispatch.

=head1 COUNTING MODEL

Per-directory subtotals come from B<one> iterative C<opendir> + C<lstat> walk with
an explicit stack that accumulates recursive subtotals at every depth in a single
pass. Semantics, all decided by the C<lstat> we already perform:

=over 4

=item * C<lstat> only. Symlinks are never followed, for counting or for descent.
Every directory entry costs exactly 1, which is what the quota charges (this also
fixes the old PHP, whose C<isFile()> followed symlinks and so never counted a
dangling symlink at all).

=item * Hardlinks are de-duplicated by C<(dev, ino)>, matching what the filesystem
actually charges. Only entries with C<nlink E<gt> 1> are tracked, so the memory
cost is proportional to the number of hardlinked files, not to the tree.

=item * Device boundaries are not crossed. A directory on another device is
never descended and never listed. When the account owns it, its own entry is
still counted as one — like any other owned entry, and deduplicated through the
hardlink table when its C<nlink> exceeds 1 — but the subtree behind it, which
the home filesystem's quota does not charge, is excluded entirely.

=item * Unreadable directories are skipped silently rather than descended. This
is the fix for the old code dying outright on nobody-owned LiteSpeed cache
directories.

=item * Ownership filter: only entries whose C<st_uid> equals the account uid are
counted. Free, because we already have the C<lstat>. Non-owned directories are
still descended (owned content can live inside them) and still listed.

=item * B<A directory's own subtotal is seeded at its own ownership flag>, i.e.
1 when the account owns the directory and 0 when it does not -- the same rule
used for its contribution to its parent. Seeding at 1 unconditionally (as the v1
PHP did, which had no ownership filter at all) made a row disagree with its own
contribution by one per non-owned directory, so children could sum to more than
the parent and C<listed_inodes> could exceed C<counted_inodes>. A nobody-owned
empty directory therefore renders as 0, which is what the quota charges this
account for it.

=item * Only the largest C<$MAX_ROWS_PER_LEVEL> subdirectories of any one
directory are emitted; the rest are counted but not listed, and the number
dropped is reported additively as C<omitted_directories>. Walking is bounded by
the entry ceiling, but emitting was not: a home with 200,000 immediate
subdirectories is legal under a 250,000 inode limit, fires neither the budget nor
the ceiling, and would serialise a ~45 MB response and then ask the browser to
build 200,000 rows from it.

=back

=head1 GUARDRAILS

Wall-clock budget (default 120s, measured on C<CLOCK_MONOTONIC> so an NTP step
cannot move the deadline), hard entry ceiling (default 2,000,000), max depth 512,
per-level row cap, one walk at a time per account via C<flock>, one walk per
process, and self-throttling. C<cpsrvd> enters neither LVE nor CageFS, so nothing
else throttles this walk on a shared server: the self-throttle is not optional.

B<Be honest about what the self-throttle actually buys.> C<IOPRIO_CLASS_IDLE> is
honoured only by the BFQ and legacy CFQ I/O schedulers; under C<blk-mq> C<none>
-- the default on this server's C<vda> -- the kernel accepts the C<ioprio_set>
call and then ignores the class entirely. C<POSIX::nice(19)> is real but throttles
CPU, and an C<opendir>/C<lstat> walk is metadata-I/O bound. The call that does the
work on a C<none> scheduler is therefore the adaptive duty cycle in C<_walk_tree>:
at each clock checkpoint, if the last window of C<$CLOCK_CHECK_INTERVAL> entries
took longer than C<$IO_SLOW_WINDOW> (i.e. we are hitting the disk rather than the
dentry cache), sleep a fraction of that window. On a warm cache the window is
microseconds per entry and nothing sleeps; the measured 274,011-inode account
(2.2-5.5s of CPU) never reaches the threshold. Set C<$IO_DUTY_FRACTION> to 0 to
disable it. The nap is charged against the wall-clock budget, deliberately: a walk
that is hammering a shared spindle should truncate rather than run longer.

Clients may B<lower> C<time_budget>, C<max_entries> and C<max_tree_dirs> but never
raise them above the compiled defaults.

=head1 FUNCTIONS

=cut

#----------------------------------------------------------------------
# Tunables. Each is also the hard ceiling for the matching request argument.
#----------------------------------------------------------------------

# 120, raised from 25 in 2.1.0: real accounts above ~500k inodes hit the old
# budget and rendered partial results. Anything proxying cpsrvd must allow the
# request to run this long (stock service-subdomain proxying, Timeout 300, does).
our $DEFAULT_TIME_BUDGET   = 120;          # seconds of wall clock for one walk
our $DEFAULT_MAX_ENTRIES   = 2_000_000;    # hard ceiling on directory entries examined
our $DEFAULT_MAX_TREE_DIRS = 25_000;       # emit the full-depth map below this many rows
our $MAX_ROWS_PER_LEVEL    = 5_000;        # most subdirectory rows emitted for one directory
our $MAX_DEPTH             = 512;          # refuse to descend deeper than this
our $LOCK_WAIT_SECONDS     = 5;            # how long to wait for the per-account lock
our $CLOCK_CHECK_INTERVAL  = 512;          # entries between clock checks
our $SELF_THROTTLE         = 1;            # nice(19) + IOPRIO_CLASS_IDLE
our $MAX_WALKS_PER_PROCESS = 1;            # Cpanel::API::Batch amplification cap

# Adaptive duty cycle -- the only throttle that works under a blk-mq 'none'
# scheduler. 0.02s for 512 entries is ~39us/entry: a warm dentry cache is one to
# two orders of magnitude faster than that, so this never fires on a cached tree.
our $IO_DUTY_FRACTION = 0.25;    # sleep this fraction of a slow window (0 = off)
our $IO_SLOW_WINDOW   = 0.02;    # seconds; a window slower than this means real disk I/O
our $IO_MAX_NAP       = 0.05;    # seconds; hard cap on any single nap

# Measured cost of $DEFAULT_MAX_TREE_DIRS, on a synthetic 21,665-directory /
# 63,425-entry tree on this server: the walk itself took 1.30s with the map and
# 1.40s without it (the map is free, as designed), but the response grew from
# 1.4 KiB to 4.7 MiB raw / 218 KiB gzipped. Lowering this to ~5000 keeps the map
# for the large majority of accounts at roughly a fifth of that payload; it is a
# one-line change and nothing else depends on the value.

#----------------------------------------------------------------------
# Constants
#----------------------------------------------------------------------

use constant {
    _S_IFMT             => 0170000,
    _S_IFDIR            => 0040000,
    _IOPRIO_WHO_PROCESS => 1,
    _IOPRIO_CLASS_IDLE  => 3,
    _IOPRIO_CLASS_SHIFT => 13,
};

# ioprio_set / ioprio_get syscall numbers. Unlisted architectures simply skip
# the io priority change rather than guessing a syscall number.
my %IOPRIO_SYSCALL = (
    'x86_64'  => [ 251, 252 ],
    'aarch64' => [ 30,  31 ],
);

# JSON booleans. NOT Cpanel::JSON::true()/false(): Cpanel/JSON.pm carries the
# comment "Do not save these values as variables, as that causes segfaults."
# directly above sub true, and those values are blessed into a stash that
# copy_boolean() aliases at runtime for compiled code (case 109225) -- which is
# exactly the environment we run in, since /execute/ dispatches to the compiled
# /usr/local/cpanel/uapi binary. JSON::XS encodes a reference to 1 or 0 as bare
# true / false natively, with no blessed object and no stash dependency, so these
# are free to share across every row. Verified byte-identical on the wire.
my $TRUE  = \1;
my $FALSE = \0;

# CLOCK_MONOTONIC if this perl has it: Time::HiRes::time() is CLOCK_REALTIME, and
# a backwards NTP step mid-walk would push the deadline out by the size of the
# step. undef falls back to wall clock rather than dying.
my $CLOCK_MONOTONIC = eval {
    my $id = Time::HiRes::CLOCK_MONOTONIC();
    Time::HiRes::clock_gettime($id);
    $id;
};

sub _now {
    return defined $CLOCK_MONOTONIC ? Time::HiRes::clock_gettime($CLOCK_MONOTONIC) : Time::HiRes::time();
}

# Cpanel::API::Batch runs a whole batch in one process; see EXECUTION CONTEXT.
# Package scope, not lexical, so a test harness can reset it: in production one
# uapi process serves exactly one call, so nothing ever needs to.
our $WALKS_STARTED = 0;

# Walk-frame slots.
use constant {
    _F_NAME  => 0,    # basename of this directory
    _F_PATH  => 1,    # absolute path used for syscalls
    _F_REL   => 2,    # path relative to the account home ('' for the home itself)
    _F_DH    => 3,    # open directory handle
    _F_OWNED => 4,    # 1 if this directory itself is owned by the account
    _F_ACC   => 5,    # running count of owned entries beneath this directory
    _F_KIDS  => 6,    # arrayref of finalised child summaries
    _F_DEPTH => 7,    # 0 for the walk root
};

=head2 get_usage

C<GET /execute/ChemiCloudInodeUsage/get_usage>

Top-level directory breakdown for the account home, plus the quota-sourced total
and limit, plus (additively) the full-depth tree map when it is small enough to
be worth sending.

Optional arguments, all clamped to C<[min, compiled default]>:

=over 4

=item * C<time_budget> - seconds, 1 .. 120 (default 120)

=item * C<max_entries> - 1000 .. 2000000 (default 2000000)

=item * C<max_tree_dirs> - 0 .. 25000 (default 25000; 0 suppresses C<tree>)

=back

=cut

sub get_usage {
    my ( $args, $result ) = @_;

    my ( $home_display, $home_real, $uid ) = _identity();

    if ( !defined $home_real ) {
        $result->data( _blank_usage() );
        $result->raw_error('The system could not determine the home directory for this account.');
        return 0;
    }

    my $budget    = _clamped_int( $args, 'time_budget',   $DEFAULT_TIME_BUDGET,   1,    $DEFAULT_TIME_BUDGET );
    my $max_entry = _clamped_int( $args, 'max_entries',   $DEFAULT_MAX_ENTRIES,   1000, $DEFAULT_MAX_ENTRIES );
    my $max_tree  = _clamped_int( $args, 'max_tree_dirs', $DEFAULT_MAX_TREE_DIRS, 0,    $DEFAULT_MAX_TREE_DIRS );

    # Lock before we look at anything path-shaped so that "busy" can never
    # correlate with whether a requested path exists. The in-process cap is
    # checked here too, so a batch gets the same answer by the same route.
    my ( $lock_fh, $lock_state ) = _acquire_lock($home_real);
    if ( $lock_state eq 'busy' || $WALKS_STARTED >= $MAX_WALKS_PER_PROCESS ) {
        close($lock_fh) if $lock_fh;
        my $blank = _blank_usage();
        $blank->{'busy'} = $TRUE;
        $result->data($blank);
        $result->raw_error('An inode scan is already running for this account. Please try again in a moment.');
        return 0;
    }

    my ( $dh, $root_path, $root_rel, $root_dev ) = _resolve_request_path( '', $home_display, $home_real );

    if ( !$dh ) {
        close($lock_fh) if $lock_fh;
        $result->data( _blank_usage() );
        $result->raw_error('The system could not read the home directory for this account.');
        return 0;
    }

    my $started  = _now();
    my $throttle = _self_throttle();
    $WALKS_STARTED++;

    my $walk = eval {
        _walk_tree(
            {
                root_dh       => $dh,
                root_path     => $root_path,
                root_rel      => $root_rel,
                root_dev      => $root_dev,
                uid           => $uid,
                home_display  => $home_display,
                budget        => $budget,
                max_entries   => $max_entry,
                max_tree_dirs => $max_tree,
                max_rows      => $MAX_ROWS_PER_LEVEL,
                store_tree    => ( $max_tree > 0 ? 1 : 0 ),
            }
        );
    };
    _restore_ioprio($throttle);
    close($lock_fh) if $lock_fh;

    if ( !$walk ) {
        $result->data( _blank_usage() );
        $result->raw_error('The system failed to read the directory tree for this account.');
        return 0;
    }

    my $quota = _quota_inodes();

    my $listed = 0;
    $listed += $_->{'inodes'} for @{ $walk->{'top'} };

    my $counted = $walk->{'root_total'};
    my $total   = $quota->{'available'} ? $quota->{'inodes_used'} : $counted;

    my $data = {
        'directories'         => $walk->{'top'},
        'total_inodes'        => 0 + $total,
        'inode_limit'         => ( $quota->{'inode_limit'} ? 0 + $quota->{'inode_limit'} : 'Unlimited' ),
        'homedir'             => $home_display,
        'counted_inodes'      => 0 + $counted,
        'listed_inodes'       => 0 + $listed,
        'omitted_directories' => 0 + $walk->{'omitted'},
        'quota_available'     => ( $quota->{'available'} ? $TRUE : $FALSE ),
        'quota_inodes_used'   => ( $quota->{'available'} ? 0 + $quota->{'inodes_used'} : undef ),
        'truncated'           => ( $walk->{'truncated'}  ? $TRUE : $FALSE ),
        'busy'                => $FALSE,
        'stats'               => _stats( $walk, $started ),
        'generated_at'        => 0 + time(),
    };

    $data->{'tree'} = $walk->{'tree'} if $walk->{'tree'};

    $result->data($data);

    return 1;
}

=head2 list_subfolders

C<GET /execute/ChemiCloudInodeUsage/list_subfolders?path=E<lt>home-relative pathE<gt>>

Immediate subdirectories of C<path>, with a recursive inode subtotal for each.
This is the fallback used when C<get_usage> omitted the C<tree> map.

C<path> is B<home-relative> and must not contain C<.>, C<..>, empty components or
a NUL. The absolute form this module emits in C<path> / C<homedir> is also
accepted (the home prefix is stripped server-side); no other absolute path is.
The base is always derived from C<$Cpanel::homedir>, never from the request.

Outside-home, nonexistent and unreadable all produce the B<same> successful empty
response, so there is no existence oracle in the body, the status or the shape.

=cut

sub list_subfolders {
    my ( $args, $result ) = @_;

    my ( $home_display, $home_real, $uid ) = _identity();
    return _blank_listing($result) if !defined $home_real;

    # Lock first: "busy" must not depend on the requested path.
    my ( $lock_fh, $lock_state ) = _acquire_lock($home_real);
    if ( $lock_state eq 'busy' || $WALKS_STARTED >= $MAX_WALKS_PER_PROCESS ) {
        close($lock_fh) if $lock_fh;
        my $blank = _blank_listing_data();
        $blank->{'busy'} = $TRUE;
        $result->data($blank);
        $result->raw_error('An inode scan is already running for this account. Please try again in a moment.');
        return 0;
    }

    my ($raw) = $args->get('path');

    my ( $dh, $root_path, $root_rel, $root_dev ) = _resolve_request_path( $raw, $home_display, $home_real );

    if ( !$dh ) {
        close($lock_fh) if $lock_fh;
        return _blank_listing($result);
    }

    my $budget    = _clamped_int( $args, 'time_budget', $DEFAULT_TIME_BUDGET, 1,    $DEFAULT_TIME_BUDGET );
    my $max_entry = _clamped_int( $args, 'max_entries', $DEFAULT_MAX_ENTRIES, 1000, $DEFAULT_MAX_ENTRIES );

    my $started  = _now();
    my $throttle = _self_throttle();
    $WALKS_STARTED++;

    my $walk = eval {
        _walk_tree(
            {
                root_dh       => $dh,
                root_path     => $root_path,
                root_rel      => $root_rel,
                root_dev      => $root_dev,
                uid           => $uid,
                home_display  => $home_display,
                budget        => $budget,
                max_entries   => $max_entry,
                max_tree_dirs => 0,
                max_rows      => $MAX_ROWS_PER_LEVEL,
                store_tree    => 0,
            }
        );
    };

    _restore_ioprio($throttle);
    close($lock_fh) if $lock_fh;

    return _blank_listing($result) if !$walk;

    $result->data(
        {
            'directories'         => $walk->{'top'},
            'path'                => $root_rel,
            'inodes'              => 0 + $walk->{'root_total'},
            'omitted_directories' => 0 + $walk->{'omitted'},
            'truncated'           => ( $walk->{'truncated'} ? $TRUE : $FALSE ),
            'busy'                => $FALSE,
            'stats'               => _stats( $walk, $started ),
        }
    );

    return 1;
}

#----------------------------------------------------------------------
# Identity
#----------------------------------------------------------------------

# Returns ( display home, resolved home, uid ) or an empty list.
#
# The display home is $Cpanel::homedir verbatim (that is what the account, the
# sidebar and File Manager call it). The resolved home is the abs_path() form and
# is what every syscall uses, so a symlinked /home cannot confuse containment.
sub _identity {
    no warnings 'once';

    my $user = $Cpanel::user;
    my $home = $Cpanel::homedir;

    my $uid;

    if ( defined $user && length $user ) {
        my @pw = Cpanel::PwCache::getpwnam_noshadow($user);
        if (@pw) {
            $uid = $pw[2];
            $home = $pw[7] if !defined $home || !length $home;
        }
    }

    return if !defined $home || !length $home;

    $home =~ s{/+\z}{};
    return if !length $home;

    my $resolved = Cwd::abs_path($home);
    return if !defined $resolved || !length $resolved;
    $resolved =~ s{/+\z}{};
    return if !length $resolved;

    my @hst = lstat($resolved);
    return if !@hst || ( $hst[2] & _S_IFMT ) != _S_IFDIR;

    # Fall back to the home directory owner, then to the effective uid. Never
    # leave $uid at 0 by accident: a 0 here would filter out every entry.
    $uid = $hst[4] if !defined $uid;
    $uid = $>      if !defined $uid;

    return ( $home, $resolved, 0 + $uid );
}

#----------------------------------------------------------------------
# Path containment
#----------------------------------------------------------------------

# Validate a client-supplied home-relative path and hand back an already-open
# directory handle for it.
#
# Returns ( $dirhandle, $abs_path, $relative_path, $dev ) on success and an empty
# list for every rejection reason, so the caller cannot accidentally branch on
# why it failed.
sub _resolve_request_path {
    my ( $raw, $home_display, $home_real ) = @_;

    $raw = '' if !defined $raw;
    return if index( $raw, "\0" ) >= 0;

    # Accept the absolute form we emit ourselves by stripping the home prefix.
    # Anything else absolute is rejected below.
    for my $base ( $home_display, $home_real ) {
        next if !defined $base || !length $base;
        if ( $raw eq $base ) { $raw = ''; last; }
        if ( rindex( $raw, "$base/", 0 ) == 0 ) {
            $raw = substr( $raw, length($base) + 1 );
            last;
        }
    }

    # Anything still absolute after that is not ours to serve.
    return if length($raw) && substr( $raw, 0, 1 ) eq '/';

    $raw =~ s{/+\z}{};
    $raw = '' if $raw eq '.';

    my $rel = '';
    if ( length $raw ) {
        my @parts = split m{/}, $raw, -1;
        for my $part (@parts) {
            return if !length $part;                    # '//' or a trailing empty component
            return if $part eq '.' || $part eq '..';    # traversal
        }
        $rel = join '/', @parts;
    }

    my $target = length($rel) ? "$home_real/$rel" : $home_real;

    # abs_path resolves every component. Requiring it to come back unchanged
    # means no component anywhere in the path is a symlink, which is a much
    # stronger invariant than a prefix check and is exactly what our own
    # listings produce (we never descend into symlinks, so we never emit one).
    my $canonical = Cwd::abs_path($target);
    return if !defined $canonical;
    return if $canonical ne $target;

    # Belt: the prefix check the resolution above already implies.
    return if $canonical ne $home_real && rindex( $canonical, "$home_real/", 0 ) != 0;

    # Braces: cPanel's own re-rooting must agree with ours. Skipped for the
    # pathological case of a newline in a directory name, which homedirfixup
    # strips and we do not.
    if ( index( $rel, "\n" ) < 0 ) {
        require Cpanel::SafeDir::Fixup;
        my $fixed = Cpanel::SafeDir::Fixup::homedirfixup( $rel, $home_real, $home_real );
        return if !defined $fixed || $fixed ne $target;
    }

    my @lst = lstat($target);
    return if !@lst;
    return if ( $lst[2] & _S_IFMT ) != _S_IFDIR;    # symlink or non-directory

    opendir( my $dh, $target ) or return;

    # Close the easy TOCTOU: whatever we actually opened must be the same inode
    # we just validated. (A swap of an *intermediate* component inside the
    # account's own home remains theoretically racy; it is same-uid and grants
    # no access the account does not already have from a shell.)
    my @dst = stat($dh);
    if ( !@dst || $dst[0] != $lst[0] || $dst[1] != $lst[1] ) {
        closedir($dh);
        return;
    }

    return ( $dh, $target, $rel, $lst[0] );
}

#----------------------------------------------------------------------
# The walk
#----------------------------------------------------------------------

# One iterative opendir + lstat pass. Accumulates a recursive subtotal for every
# directory at every depth, and builds the child-row lists as each directory
# finalises (children always finalise before their parent, so their subtotals are
# already known).
#
# Returns a hashref:
#   top        arrayref of rows for the walk root's immediate subdirectories
#   root_total inode subtotal for the walk root itself
#   tree       hashref { relative path => [rows] }, or undef
#   truncated  1 when the budget or an entry ceiling fired
#   omitted    directories counted but not emitted, because of the row cap
#   dirs / entries / skipped / depth_capped counters
sub _walk_tree {
    my ($opt) = @_;

    my $uid          = $opt->{'uid'};
    my $root_dev     = $opt->{'root_dev'};
    my $home_display = $opt->{'home_display'};
    my $max_entries  = $opt->{'max_entries'};
    my $max_tree     = $opt->{'max_tree_dirs'};
    my $max_rows     = $opt->{'max_rows'} || $MAX_ROWS_PER_LEVEL;

    my $store = $opt->{'store_tree'} ? 1 : 0;

    # The walk root's own ownership flag, from the descriptor we already hold, so
    # its row and its subtotal follow the same rule as every other directory.
    my @root_st    = stat( $opt->{'root_dh'} );
    my $root_owned = ( @root_st && $root_st[4] == $uid ) ? 1 : 0;

    my @stack = ( [ '', $opt->{'root_path'}, $opt->{'root_rel'}, $opt->{'root_dh'}, $root_owned, 0, [], 0 ] );

    my %seen_hardlink;
    my %tree;
    my @top;

    my $tree_rows    = 0;
    my $entries      = 0;
    my $dirs         = 0;
    my $skipped      = 0;
    my $depth_capped = 0;
    my $omitted      = 0;
    my $truncated    = 0;
    my $root_total   = $root_owned;
    my $tick         = 0;

    # The budget arrives as a duration, not as an absolute deadline: the caller
    # must not have to know which clock this walk reads.
    my $last_check = _now();
    my $deadline   = $last_check + $opt->{'budget'};

    while (@stack) {
        my $frame = $stack[-1];

        my $name;
        if ( !$truncated ) {
            while ( defined( $name = readdir( $frame->[_F_DH] ) ) ) {
                last if $name ne '.' && $name ne '..';
            }
        }

        #--- directory exhausted (or aborted): finalise it -------------------
        if ( !defined $name ) {
            closedir( $frame->[_F_DH] );

            my $rel      = $frame->[_F_REL];
            my $depth    = $frame->[_F_DEPTH];
            my $kids     = $frame->[_F_KIDS];
            my $total    = $frame->[_F_OWNED] + $frame->[_F_ACC];
            my $has_kids = scalar(@$kids) ? 1 : 0;

            if ( $has_kids && ( $depth == 0 || $store ) ) {
                my @sorted = sort { $b->[2] <=> $a->[2] || $a->[0] cmp $b->[0] } @$kids;

                # Rows are sorted largest first, so the cap keeps exactly the
                # ones worth showing. The dropped count is reported additively;
                # every dropped directory is still inside the subtotals above.
                if ( @sorted > $max_rows ) {
                    $omitted += scalar(@sorted) - $max_rows;
                    splice( @sorted, $max_rows );
                }

                my @rows = map { _row( $_, $home_display ) } @sorted;

                if ( $depth == 0 ) {
                    @top = @rows;
                }

                if ($store) {
                    $tree{$rel} = \@rows;
                    $tree_rows += scalar @rows;

                    # Past the cap the map is worthless to the client and
                    # expensive to hold, so drop it wholesale and reclaim the
                    # memory. The walk itself continues unaffected.
                    if ( $tree_rows > $max_tree ) {
                        %tree      = ();
                        $tree_rows = 0;
                        $store     = 0;
                    }
                }
            }

            pop @stack;

            if (@stack) {
                # One number, used twice: what this directory contributes to its
                # parent IS what its own row shows. Anything else lets the
                # children of a row sum to more than the row.
                my $parent = $stack[-1];
                $parent->[_F_ACC] += $total;
                push @{ $parent->[_F_KIDS] }, [ $frame->[_F_NAME], $rel, $total, $has_kids ];
            }
            else {
                $root_total = $total;
            }

            next;
        }

        #--- one directory entry --------------------------------------------
        $entries++;

        if ( ++$tick >= $CLOCK_CHECK_INTERVAL ) {
            $tick = 0;
            my $now = _now();

            if ( $entries >= $max_entries || $now >= $deadline ) {
                $truncated = 1;
                next;
            }

            # Adaptive duty cycle. A window this slow means we are reading the
            # disk rather than the dentry cache, and nothing else on this box
            # throttles us (see GUARDRAILS): give the spindle back for a moment.
            if ( $IO_DUTY_FRACTION > 0 ) {
                my $window = $now - $last_check;
                if ( $window >= $IO_SLOW_WINDOW ) {
                    my $nap = $window * $IO_DUTY_FRACTION;
                    $nap = $IO_MAX_NAP if $nap > $IO_MAX_NAP;
                    Time::HiRes::sleep($nap);
                    $now = _now();
                }
            }

            $last_check = $now;
        }

        my $full = $frame->[_F_PATH] . '/' . $name;

        my @st = lstat($full);
        next if !@st;    # vanished between readdir and lstat

        my $owned = ( $st[4] == $uid ) ? 1 : 0;

        if ( ( $st[2] & _S_IFMT ) == _S_IFDIR && $st[0] == $root_dev ) {

            # An entry that WAS a real directory on our device when lstat ran.
            $dirs++;

            my $child_rel = length( $frame->[_F_REL] ) ? $frame->[_F_REL] . '/' . $name : $name;

            my ( $child_dh, $decline );

            if ( $frame->[_F_DEPTH] >= $MAX_DEPTH ) {
                $decline = 'depth';
            }
            elsif ( !opendir( $child_dh, $full ) ) {

                # Unreadable: the nobody-owned LiteSpeed cache case. Count it as
                # itself and move on instead of dying, which is what v1 did.
                $decline = 'unreadable';
            }
            else {
                # TOCTOU. $full is a path string, re-resolved from / by the
                # kernel at opendir time with no O_NOFOLLOW, so "we lstat'd a
                # directory" does NOT prove "we opened that directory": an entry
                # renamed to a symlink between the two syscalls sends the walk
                # wherever the symlink points. On this server /, /etc, /home and
                # the cPanel root are all one device, so the device test above is
                # no backstop whatsoever -- one win of that race would list every
                # account under /home. This is the same check
                # _resolve_request_path already makes on the request path, and it
                # closes the race completely at the leaf: either the entry was a
                # symlink at lstat time (branch not taken) or the handle we now
                # hold is a different inode from the one we validated.
                my @dst = stat($child_dh);
                if ( !@dst || $dst[0] != $st[0] || $dst[1] != $st[1] || $dst[0] != $root_dev ) {
                    closedir($child_dh);
                    undef $child_dh;
                    $decline = 'swapped';
                }
            }

            if ($decline) {
                $decline eq 'depth' ? $depth_capped++ : $skipped++;
                $frame->[_F_ACC] += $owned;
                push @{ $frame->[_F_KIDS] }, [ $name, $child_rel, $owned, 0 ];
                next;
            }

            push @stack, [ $name, $full, $child_rel, $child_dh, $owned, 0, [], $frame->[_F_DEPTH] + 1 ];
            next;
        }

        # Everything else: files, symlinks (counted, never followed), fifos,
        # sockets, devices, and directories on another device.
        next if !$owned;

        if ( $st[3] > 1 ) {

            # Possible hardlink. The filesystem charges one inode per file, not
            # one per name, so only the first name we meet counts.
            next if $seen_hardlink{ $st[0] . ':' . $st[1] }++;
        }

        $frame->[_F_ACC]++;
    }

    return {
        'top'          => \@top,
        'root_total'   => $root_total,
        'tree'         => ( $store && $tree_rows ? \%tree : undef ),

        # A depth-capped directory is an undercount produced by one of our own
        # limits, exactly like the budget and the entry ceiling, so it says so
        # rather than reporting a confidently wrong number with nothing to
        # indicate it. Unreachable in practice at 512 levels.
        'truncated' => ( $truncated || $depth_capped ) ? 1 : 0,
        'omitted'      => $omitted,
        'dirs'         => $dirs,
        'entries'      => $entries,
        'skipped'      => $skipped,
        'depth_capped' => $depth_capped,
    };
}

# [ name, relpath, inodes, has_kids ] -> the wire row.
sub _row {
    my ( $kid, $home_display ) = @_;

    return {
        'name'           => $kid->[0],
        'relpath'        => $kid->[1],
        'path'           => $home_display . '/' . $kid->[1],
        'inodes'         => 0 + $kid->[2],
        'has_subfolders' => ( $kid->[3] ? $TRUE : $FALSE ),
    };
}

sub _stats {
    my ( $walk, $started ) = @_;

    return {
        'directories'              => 0 + $walk->{'dirs'},
        'entries'                  => 0 + $walk->{'entries'},
        'unreadable_directories'   => 0 + $walk->{'skipped'},
        'depth_capped_directories' => 0 + $walk->{'depth_capped'},
        'elapsed_ms'               => int( ( _now() - $started ) * 1000 ),
    };
}

#----------------------------------------------------------------------
# Quota
#----------------------------------------------------------------------

# The Total is the quota figure, not a walk result: O(1), and the same number the
# cPanel sidebar shows.
#
# We call Cpanel::Quota::displayquota() directly rather than
# Cpanel::API::Quota::get_quota_info() for two reasons. First, get_quota_info
# collapses "quotas are disabled on this filesystem" (displayquota returns "NA")
# into inodes_used => 0, which we would render as a total of zero next to a
# populated table; we need to tell those apart. Second, get_quota_info makes
# blocking HTTPS calls to any linked worker nodes, and worker inodes do not live
# in this home directory, so adding them would widen the reconciliation gap the
# page has to explain. If linked nodes are ever used here, port the eight-line
# aggregation loop from Cpanel/API/Quota.pm.
sub _quota_inodes {
    no warnings 'once';

    my %out = ( 'available' => 0, 'inodes_used' => undef, 'inode_limit' => 0 );

    # The cpuser file wins when it sets a limit, exactly as get_quota_info does;
    # some operators set the limit only in the quota system, hence the fallback.
    my $limit = 0;
    $limit = $Cpanel::CPDATA{'DISK_INODE_LIMIT'} || 0 if %Cpanel::CPDATA;

    my @quota = eval {
        require Cpanel::Quota;
        Cpanel::Quota::displayquota(1);
    };

    if ( !$@ && scalar(@quota) == 6 ) {
        $out{'available'}   = 1;
        $out{'inodes_used'} = $quota[3] || 0;    # $Cpanel::Quota::INODES_USED
        $limit ||= $quota[4] || 0;               # $Cpanel::Quota::INODES_LIMIT
    }

    # Anything else (the "NA\n" single-element form, or a failure) means we have
    # no quota figure. The caller falls back to the walked total.

    $out{'inode_limit'} = ( $limit && $limit =~ m{\A[0-9]+\z} ) ? 0 + $limit : 0;

    return \%out;
}

#----------------------------------------------------------------------
# Concurrency and self-throttling
#----------------------------------------------------------------------

# One walk at a time per account. We flock the home directory's own descriptor:
# no file is created, so this works for an account that is already over quota,
# and it is per-account by construction with nothing in a world-writable
# directory for another local user to squat on.
#
# Returns ( $fh, 'locked' ) | ( undef, 'unavailable' ) | ( undef, 'busy' ).
# 'unavailable' deliberately fails open: a lock we cannot take is not a reason to
# break the page.
sub _acquire_lock {
    my ($home_real) = @_;

    # 0 rather than a numeric fallback: O_DIRECTORY is 0200000 on x86_64 but
    # 040000 on aarch64, and guessing wrong would open something else entirely.
    # Fcntl has provided it for many releases, and on Linux a plain O_RDONLY open
    # of a directory works anyway -- the flag only refuses non-directories.
    my $o_directory = eval { Fcntl::O_DIRECTORY() } || 0;

    my $fh;
    return ( undef, 'unavailable' ) if !sysopen( $fh, $home_real, Fcntl::O_RDONLY() | $o_directory );

    my $deadline = _now() + $LOCK_WAIT_SECONDS;

    while (1) {
        return ( $fh, 'locked' ) if flock( $fh, Fcntl::LOCK_EX() | Fcntl::LOCK_NB() );
        last if _now() >= $deadline;
        Time::HiRes::sleep(0.1);
    }

    close($fh);
    return ( undef, 'busy' );
}

# cpsrvd enters neither LVE nor CageFS, so on a shared server this and the duty
# cycle in _walk_tree are the only throttles that exist. The process is a
# per-request /usr/local/cpanel/uapi child, so neither change can leak into
# another request or another account -- with the single exception of a
# Cpanel::API::Batch, where nice(19) would leak into every later command of the
# batch; $MAX_WALKS_PER_PROCESS bounds that to one.
#
# nice(19) is one-way for a non-root process and is not restored; io priority is.
# IOPRIO_CLASS_IDLE is set unconditionally but is honoured only by BFQ and legacy
# CFQ: under blk-mq 'none' (this server's vda) the kernel accepts the call and
# ignores the class. Kept because it costs nothing and becomes real the moment an
# operator switches the scheduler; see GUARDRAILS for what actually throttles.
sub _self_throttle {
    return if !$SELF_THROTTLE;

    my $arch = eval { ( POSIX::uname() )[4] };
    $arch = '' if !defined $arch;

    my $previous;

    if ( my $nr = $IOPRIO_SYSCALL{$arch} ) {
        local $@;
        eval {
            my $got = syscall( 0 + $nr->[1], 0 + _IOPRIO_WHO_PROCESS, 0 );
            $previous = $got if defined $got && $got >= 0;
            syscall(
                0 + $nr->[0], 0 + _IOPRIO_WHO_PROCESS, 0,
                0 + ( ( _IOPRIO_CLASS_IDLE << _IOPRIO_CLASS_SHIFT ) | 7 )
            );
            1;
        };
    }

    { local $@; eval { POSIX::nice(19); 1 }; }

    return { 'arch' => $arch, 'ioprio' => $previous };
}

sub _restore_ioprio {
    my ($throttle) = @_;

    return if !$throttle || !defined $throttle->{'ioprio'};

    my $nr = $IOPRIO_SYSCALL{ $throttle->{'arch'} } or return;

    local $@;
    eval { syscall( 0 + $nr->[0], 0 + _IOPRIO_WHO_PROCESS, 0, 0 + $throttle->{'ioprio'} ); 1 };

    return;
}

#----------------------------------------------------------------------
# Argument handling and canned responses
#----------------------------------------------------------------------

# Clients may lower a budget but never raise it: $max is always the compiled
# default, so a hostile or buggy caller cannot buy itself more of the server.
sub _clamped_int {
    my ( $args, $key, $default, $min, $max ) = @_;

    my ($raw) = $args->get($key);

    return $default if !defined $raw;
    return $default if $raw !~ m{\A[0-9]{1,12}\z};

    my $value = 0 + $raw;

    $value = $min if $value < $min;
    $value = $max if $value > $max;

    return $value;
}

sub _blank_stats {
    return {
        'directories'              => 0,
        'entries'                  => 0,
        'unreadable_directories'   => 0,
        'depth_capped_directories' => 0,
        'elapsed_ms'               => 0,
    };
}

sub _blank_usage {
    return {
        'directories'         => [],
        'total_inodes'        => 0,
        'inode_limit'         => 'Unlimited',
        'homedir'             => '',
        'counted_inodes'      => 0,
        'listed_inodes'       => 0,
        'omitted_directories' => 0,
        'quota_available'     => $FALSE,
        'quota_inodes_used'   => undef,
        'truncated'           => $FALSE,
        'busy'                => $FALSE,
        'stats'               => _blank_stats(),
        'generated_at'        => 0 + time(),
    };
}

sub _blank_listing_data {
    return {
        'directories'         => [],
        'path'                => '',
        'inodes'              => 0,
        'omitted_directories' => 0,
        'truncated'           => $FALSE,
        'busy'                => $FALSE,
        'stats'               => _blank_stats(),
    };
}

# The single rejection response: outside home, nonexistent, unreadable and
# "walk blew up" are all indistinguishable in body, status and shape.
sub _blank_listing {
    my ($result) = @_;

    $result->data( _blank_listing_data() );

    return 1;
}

=head1 RESPONSE

Both functions return the usual UAPI envelope; everything documented above lives
under C<result.data>. C<get_usage> returns C<result.status> 0 in four cases:
the account's home directory cannot be determined; the concurrency refusal
(which also sets C<data.busy> to C<true>); the home directory cannot be resolved
or opened; and a walk that dies. C<list_subfolders> returns 0 B<only> for the
concurrency refusal — every other rejection deliberately returns the successful
blank listing, so a status probe is not an existence oracle.

Fields the page must not ignore:

=over 4

=item * C<truncated> - the walk hit the wall-clock budget, the entry ceiling or
the depth cap. The numbers are undercounts.

=item * C<omitted_directories> - directories counted but not listed, because of
the per-level row cap. Present on B<both> endpoints.

=item * C<quota_available> - false means C<Cpanel::Quota::displayquota()> could
not be used (quotas off on the filesystem, or its datastore cache write failed
with something other than EDQUOT), and C<total_inodes> is therefore the walked
home subtotal rather than the figure the cPanel sidebar shows. Silently rendering
that as "Total" would be a wrong number with nothing to explain it.

=back

=cut

my $allow_demo = { 'allow_demo' => 1 };

our %API = (
    'get_usage'       => $allow_demo,
    'list_subfolders' => $allow_demo,
);

1;
