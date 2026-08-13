package PVE::Storage::Custom::QNAP::Multipath;

# dm-multipath, for QNAP LUNs.
#
# The rules inherited from the related projects, which cost real outages there:
#
#   * `multipath -F` (capital F) is NEVER generated. It flushes every unused map
#     on the node, including other vendors' storage and an operator's own
#     hand-built maps. Only ever one named map at a time. `make
#     check-multipath-flush` fails the build on any occurrence.
#   * Flush only after `multipathd disablequeueing map` and
#     `dmsetup message <map> 0 fail_if_no_path`. With queueing on and every path
#     down, a flush waits forever for I/O that can never complete.
#   * `no_path_retry` is a number, never `queue`. `dev_loss_tmo` is never
#     `infinity`.
#   * `multipathd reconfigure` is NODE-WIDE and is permitted in exactly one
#     place: after this plugin's own conf.d drop-in changed. It is never used to
#     make a device appear.
#
# And three that are about QNAP:
#
#   1. **`/dev/mapper/<wwid>` cannot be assumed to exist.** On a node with
#      `user_friendly_names yes` multipath names the map `mpathX` and
#      `/dev/mapper/<wwid>` is simply absent.
#      `/dev/disk/by-id/dm-uuid-mpath-<wwid>` is always there whatever naming
#      policy the node's administrator chose, and it is what this module hands
#      out. Setting `user_friendly_names no` globally would rename OTHER
#      vendors' maps.
#   2. **multipath-tools ships no built-in entry for QNAP**, so the drop-in
#      below is mandatory rather than tuning. Without it a QNAP LUN falls back
#      to the generic defaults, and those include `no_path_retry "queue"` —
#      which turns the loss of every path into a hang nothing can recover from
#      without a reboot.
#   3. **The LUN number inside a target is reused**, so a by-path device name is
#      a hint for finding a candidate and never proof of which LUN it is. Every
#      device is confirmed against the LUN's `LUNNAA` by the kernel's own WWID
#      before it is used.
#
# WHAT THE INQUIRY ACTUALLY SAYS is the one thing here that has not been read
# off hardware by this project. The vendor is expected to be
# `QNAP`; the product string is matched with `.*` rather than a literal for that
# reason — a stanza that matches the vendor and every product of that vendor
# cannot silently fail to apply, and cannot reach another vendor's disk either.
# `pve-qnap-api-probe --node` prints what a node really sees. See
# docs/TESTING.md.

use strict;
use warnings;

# File::Basename is imported explicitly. The ported in-use check calls dirname
# and basename, `perl -c` compiles a call to an undefined subroutine without
# complaint, and in the related project the failure surfaced only when a real VM
# held the device — where it failed SAFE, refusing the delete, but for entirely
# the wrong reason. t/06-imports.t exists because of this.
use File::Basename qw(basename dirname);

use PVE::Storage::Custom::QNAP::Command qw(
    run_cmd is_block_device sysfs_read_with_timeout tool_path
);

# Everything here is a function, not a method. This module and Naming have both
# been called as `Module->function(...)` in the related projects, and the shifted
# arguments do not error — they quietly produce a default. In Naming that made
# the ownership gate answer "not owned"; here it silently ignored a
# no_path_retry the caller had set.
sub _not_a_method {
    my ($first) = @_;
    return if !defined $first || $first ne __PACKAGE__;
    die __PACKAGE__ . ": these are functions, not methods. Call"
      . " Multipath::name(...) rather than Multipath->name(...).\n";
}

use constant {
    # SCSI INQUIRY vendor, as a QNAP LUN is expected to report it. multipath matches
    # these as regular expressions.
    VENDOR  => 'QNAP',
    # Every product of that vendor. See the note at the top of this file: a
    # literal that is slightly wrong makes the whole stanza silently not apply,
    # and the fallback is the generic default with `no_path_retry queue`.
    PRODUCT => '.*',

    CONF_DIR  => '/etc/multipath/conf.d',
    CONF_FILE => '/etc/multipath/conf.d/jt-pve-storage-qnap.conf',

    # Bumped whenever the drop-in's content changes, so an upgrade can tell
    # whether the file on disk is this version's.
    CONF_VERSION => 1,
};

# ---------------------------------------------------------------------------
# The configuration drop-in
# ---------------------------------------------------------------------------

sub conf_content {
    _not_a_method($_[0]);
    my (%opt) = @_;
    my $no_path_retry = $opt{no_path_retry} // 18;
    my $version = CONF_VERSION;
    my $vendor  = VENDOR;
    my $product = PRODUCT;

    # `no_path_retry` is a NUMBER. `queue` is what the generic defaults give a
    # QNAP LUN on a node with no entry for it, and with queueing on, losing
    # every path is an unkillable hang rather than an I/O error.
    #
    # `path_grouping_policy multibus` and `prio const`, NOT `group_by_prio` with
    # `alua`: a QNAP is a single-controller array and every portal reaches the
    # same LUN through the same backend, so all paths are equal and should carry
    # I/O at once. Asking for ALUA priorities on a target that advertises none
    # leaves every path in one group with equal priority anyway, but by way of a
    # prioritiser that has to be run for each path on each check.
    return <<"EOF";
# jt-pve-storage-qnap drop-in
# qnap-multipath-config-version: $version
#
# Generated. Do not edit: this file is rewritten when the plugin's
# configuration changes.
#
# multipathd ships no built-in entry for QNAP, so without this stanza a QNAP
# LUN falls back to the generic defaults — which include no_path_retry "queue",
# and queueing forever is not a failure mode anyone can recover from without a
# reboot.
devices {
    device {
        vendor                  "$vendor"
        product                 "$product"
        path_grouping_policy    multibus
        prio                    const
        path_checker            tur
        failback                immediate
        rr_weight               uniform
        no_path_retry           $no_path_retry
        fast_io_fail_tmo        5
        dev_loss_tmo            60
    }
}
EOF
}

# Returns 1 if the file changed and multipathd therefore has to be told.
sub write_conf {
    _not_a_method($_[0]);
    my (%opt) = @_;
    my $want = conf_content(%opt);

    my $have = '';
    if (-e CONF_FILE) {
        open(my $fh, '<', CONF_FILE) or die "cannot read " . CONF_FILE . ": $!\n";
        local $/;
        $have = <$fh> // '';
        close($fh);
    }
    return 0 if $have eq $want;

    mkdir CONF_DIR if !-d CONF_DIR;
    my $tmp = CONF_FILE . ".tmp.$$";
    open(my $fh, '>', $tmp) or die "cannot write $tmp: $!\n";
    print $fh $want;
    close($fh) or die "cannot write $tmp: $!\n";
    rename($tmp, CONF_FILE) or die "cannot install " . CONF_FILE . ": $!\n";

    return 1;
}

# NODE-WIDE. The only place it is allowed, and only when the drop-in actually
# changed — multipathd has no per-file reload. Never on a timer, and never to
# make a device appear.
sub reload_config {
    _not_a_method($_[0]);
    my (%opt) = @_;
    eval { run_cmd([ 'multipathd', 'reconfigure' ], timeout => 30) };
    warn "multipathd reconfigure failed: $@" if $@;
    return 1;
}

# ---------------------------------------------------------------------------
# Finding a map from a WWID
# ---------------------------------------------------------------------------

# The stable handle. Present whatever the node's user_friendly_names setting
# is, which /dev/mapper/<wwid> is not.
sub dm_uuid_path {
    _not_a_method($_[0]);
    my ($wwid) = @_;
    return undef if !defined $wwid || $wwid !~ /\A[0-9a-f]{10,}\z/i;
    return '/dev/disk/by-id/dm-uuid-mpath-' . lc($wwid);
}

# The kernel's own name for the map behind a WWID — `dm-9`, not `mpathc`. The
# readlink is bounded because a stat under /dev on a dead multipath device is
# uninterruptible sleep.
sub _dm_basename {
    my ($wwid) = @_;
    my $link = dm_uuid_path($wwid) or return undef;

    my $target = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        my $t = readlink($link);
        alarm(0);
        $t;
    };
    alarm(0);
    return undef if !defined $target;

    my ($dm) = $target =~ m{([^/]+)\z} or return undef;   # e.g. dm-9
    return $dm =~ /\A[A-Za-z0-9_-]+\z/ ? $dm : undef;
}

# The map's device-mapper name (mpathc, or the wwid, or an alias — whatever the
# node's policy produced). Read from the link rather than assumed.
sub map_name_for_wwid {
    _not_a_method($_[0]);
    my ($wwid) = @_;
    my $dm = _dm_basename($wwid) or return undef;
    my $name = sysfs_read_with_timeout("/sys/block/$dm/dm/name", 3);
    return undef if !defined $name;
    chomp $name;
    return length($name) ? $name : undef;
}

# ---------------------------------------------------------------------------
# What size the KERNEL is presenting
# ---------------------------------------------------------------------------
#
# `/sys/block/<dev>/size` is in 512-byte sectors whatever the device's logical
# block size is — that unit is the sysfs interface's, not the disk's. This
# matters more on QNAP than on the related arrays: `add_lun` takes a
# `LUNSectorSize` of 512 or 4096, so a 4Kn LUN is entirely ordinary here, and a
# reader that assumed the sysfs unit followed the disk would be out by eight.
#
# undef means the size could not be read, which is never the same as
# "unchanged".

sub _sysfs_size_bytes {
    my ($base) = @_;
    return undef if !defined $base || $base !~ /\A[A-Za-z0-9_-]+\z/;
    my $sectors = sysfs_read_with_timeout("/sys/block/$base/size", 3);
    return undef if !defined $sectors;
    chomp $sectors;
    return undef if $sectors !~ /\A[0-9]+\z/;
    return $sectors * 512;
}

# For one path (`sdb`, or `/dev/sdb`).
sub device_size_bytes {
    _not_a_method($_[0]);
    my ($dev) = @_;
    return undef if !defined $dev;
    my ($base) = $dev =~ m{([^/]+)\z} or return undef;
    return _sysfs_size_bytes($base);
}

# For the map behind a WWID.
sub map_size_bytes {
    _not_a_method($_[0]);
    my ($wwid) = @_;
    my $dm = _dm_basename($wwid) or return undef;
    return _sysfs_size_bytes($dm);
}

# How long to wait for a resize to reach the map. Generous, because the cost of
# being wrong is asymmetric: a few seconds added to a `qm resize` against a
# failed one the operator has to unpick by hand.
use constant RESIZE_SETTLE_TIMEOUT => 60;

# MAKE THE MAP MATCH THE PATHS, AND ANSWER WITH WHAT ACTUALLY HAPPENED.
#
# `multipathd resize map` takes the new size from multipathd's OWN udev view of
# the first path. That view is refreshed by the uevent the capacity change
# raises — which has not been processed yet, microseconds after the sysfs write
# that caused it. multipathd then compares the stale size against the map's
# size, finds them equal, logs "map is still the same size" and exits **0**. The
# map never grows and nothing reports a problem.
#
# Measured in the related project: the NAS grew the LUN and sdb picked it up —
# `detected capacity change from 67108864 to 69206016` — while dm-0 stayed at
# 67108864. So: poll the paths until they carry the new size, re-issue the map
# resize until the map does too. A retry is cheap and idempotent — `resize map`
# on a map already at the right size is a no-op — and it is what actually rides
# out the udev delay.
#
# Returns { size => <bytes or undef>, ok => 0|1, paths_ready => 0|1 }. `ok` is
# the only thing a caller should branch on, and it is never true on a size that
# could not be read.
sub grow_map {
    _not_a_method($_[0]);
    my ($wwid, $map, $want, $slaves, %opt) = @_;
    $slaves //= [];

    my $timeout = defined $opt{timeout} ? $opt{timeout} : RESIZE_SETTLE_TIMEOUT;
    my $pause   = defined $opt{pause}   ? $opt{pause}   : 0.2;
    my $deadline = time + $timeout;

    my ($seen, $paths_ready, $cmd_error);
    while (1) {
        $seen = map_size_bytes($wwid);
        last if defined $seen && $seen >= $want;

        # The paths first. multipathd cannot grow a map past what a path
        # reports, so asking before they have caught up is the no-op above.
        $paths_ready = @$slaves ? 1 : 0;
        for my $sd (@$slaves) {
            my $sz = device_size_bytes($sd);
            if (!defined $sz || $sz < $want) { $paths_ready = 0; last }
        }
        if ($paths_ready && !resize_map($map)) {
            # STOP. multipathd could not be RUN — a missing binary, a daemon
            # that is not there. Retrying that for a minute is a minute spent
            # not telling anyone.
            $cmd_error = last_resize_error();
            last;
        }

        $seen = map_size_bytes($wwid);
        last if defined $seen && $seen >= $want;
        last if time >= $deadline;
        select(undef, undef, undef, $pause);
    }

    return {
        size        => $seen,
        ok          => (defined $seen && $seen >= $want) ? 1 : 0,
        paths_ready => $paths_ready ? 1 : 0,
        cmd_error   => $cmd_error,
    };
}

# What a caller should open. Returns undef when the map is not there — which is
# an answer, not an error.
sub device_path_for_wwid {
    _not_a_method($_[0]);
    my ($wwid) = @_;
    my $link = dm_uuid_path($wwid) or return undef;
    my $ok = is_block_device($link);
    # undef means the stat never came back. That is NOT "no device": returning
    # a path nobody could confirm is how a caller writes to the wrong thing.
    return undef if !defined $ok || !$ok;
    return $link;
}

# ---------------------------------------------------------------------------
# Confirming a device really is the LUN that was asked for
# ---------------------------------------------------------------------------

# The LUN number inside a target is reused, so the by-path name that led here
# proves nothing. The kernel's own identification is what decides.
sub wwid_of_device {
    _not_a_method($_[0]);
    my ($dev) = @_;
    return undef if !defined $dev || !length $dev;

    my ($base) = $dev =~ m{([^/]+)\z};
    if (defined $base) {
        my $w = sysfs_read_with_timeout("/sys/block/$base/device/wwid", 3);
        if (defined $w) {
            chomp $w;
            # 'naa.60123456...' — the same identifier multipath uses with a
            # leading 3 instead of the naa. prefix, and the same 32 hex digits
            # QTS returns as `LUNNAA`.
            if ($w =~ /naa\.([0-9a-f]+)/i) {
                return '3' . lc($1);
            }
        }
    }

    for my $prog ('/lib/udev/scsi_id', '/usr/lib/udev/scsi_id') {
        next if !-x $prog;
        my $out = eval { run_cmd([ $prog, '-g', '-u', '-d', $dev ],
                                 timeout => 10, allow_nonzero => 1) };
        next if !defined $out;
        chomp $out;
        return lc($out) if $out =~ /\A3[0-9a-f]+\z/i;
    }

    return undef;
}

# The check every caller must pass before touching a device. Returns 1, 0, or
# **undef** for "could not establish" — and undef must never be treated as yes.
sub device_is_lun {
    _not_a_method($_[0]);
    my ($dev, $wwid) = @_;
    return undef if !defined $wwid;
    my $found = wwid_of_device($dev);
    return undef if !defined $found;
    return lc($found) eq lc($wwid) ? 1 : 0;
}

# The sd devices underneath a map.
#
# These are what carry a new size up to the map: rescanning the MAP itself does
# nothing, because /sys/block/dm-N has no device/rescan — and a rescan helper
# that silently returns 0 for a missing file makes that look like it worked.
#
# Also what a delete path needs: the slave list has to be captured BEFORE the
# map is flushed, because afterwards there is nothing left to ask.
sub slaves_of_map {
    my ($wwid) = @_;
    _not_a_method($_[0]) if @_ && defined $_[0] && $_[0] eq __PACKAGE__;

    my $dm = _dm_basename($wwid) or return [];

    # Bounded together with the file tests that follow it, not just the glob.
    my @slaves = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        my @s = glob("/sys/block/$dm/slaves/*");
        alarm(0);
        @s;
    };
    alarm(0);

    my @devs;
    for my $entry (@slaves) {
        # The name used is the one the match RETURNED, not the one read from the
        # directory: it is the taint discipline and the correctness check in one.
        my ($name) = $entry =~ m{/([a-z0-9]+)\z} or next;
        push @devs, "/dev/$name";
    }
    return \@devs;
}

# ---------------------------------------------------------------------------
# Acting on ONE map
# ---------------------------------------------------------------------------

# Make sure a map EXISTS for this WWID, whatever the node's policy is.
#
# This is not optional and it is not tuning. `find_multipaths` decides whether
# multipath will build a map for a device at all, and it is a per-node setting an
# administrator chose:
#
#   * `no`/`off`  — a map for every device.
#   * `yes`/`on`  — a map ONLY for a device with two or more paths, or one whose
#                   WWID is already in /etc/multipath/wwids. With a single
#                   portal there is then no map at all: the session is up, the
#                   by-path device is there, and the path this plugin hands out
#                   points at nothing.
#   * `strict`    — a map ONLY for a WWID already in /etc/multipath/wwids,
#                   HOWEVER MANY healthy paths there are. This is
#                   multipath-tools' own default, so it is what a node nobody
#                   has configured runs with — and on it a LUN this plugin has
#                   just created never gets a map unless its WWID is put in
#                   that file first. The related Dell plugin met exactly this.
#
# A QNAP is very often cabled with one data address, and `strict` is the
# default, so needing the entry is the COMMON case here rather than the
# exception.
#
# `multipath -a <wwid>` is the documented way to say "accept this one device",
# and it appends exactly one WWID to /etc/multipath/wwids. Never `-A` (adds
# every device it can find) and never `-w`/`-W`, which REWRITE that file and
# would drop other vendors' entries.
sub ensure_map {
    _not_a_method($_[0]);
    my ($wwid, $dev, %opt) = @_;
    return 0 if !defined $wwid;

    # Already there: nothing to do, and this is the common path.
    return 1 if device_path_for_wwid($wwid);

    # One WWID, appended, and BEFORE the path is offered to multipathd. This is
    # what makes find_multipaths `strict` build a map at all, and `yes` build
    # one for a single-path device.
    eval { run_cmd([ 'multipath', '-a', lc $wwid ],
                   timeout => 20, allow_nonzero => 1) };

    # And ask for the map now rather than waiting for a udev event that may not
    # come. Named by WWID, so it cannot touch another device.
    eval { run_cmd([ 'multipath', lc $wwid ],
                   timeout => 30, allow_nonzero => 1) };

    # If the device node is known, claiming its path is the other half: it is
    # what attaches a path to an existing map.
    claim_path($dev) if defined $dev;

    # `multipathd add path` is asynchronous and returns before the map exists,
    # so the map is waited for rather than looked for once.
    my $deadline = time + ($opt{timeout} // 15);
    while (time <= $deadline) {
        return 1 if device_path_for_wwid($wwid);
        select(undef, undef, undef, 0.25);
    }
    return 0;
}

# The name multipathd knows a path by — `sdb` — from whatever a caller holds.
#
# activate_volume holds `/dev/sdb`, because that is what
# ISCSI::wait_for_by_path resolves a by-path link to. For as long as claim_path
# accepted only the bare name, its calls from there returned 0 without running
# anything and nothing said so: the path was never offered to multipathd, and
# the code read as though it had been. undef for anything that is not a plain
# device name, so nothing odd reaches a command line.
sub path_name {
    _not_a_method($_[0]);
    my ($dev) = @_;
    return undef if !defined $dev;
    return $dev =~ m{\A(?:/dev/)?([a-z]+[0-9]*)\z} ? $1 : undef;
}

sub claim_path {
    _not_a_method($_[0]);
    my ($dev) = @_;
    my $sd = path_name($dev);
    return 0 if !defined $sd;
    # One named path. Not a node-wide reconfigure, which is how a related
    # project came to reconfigure another vendor's storage every few minutes
    # while looking for a disk of its own.
    eval { run_cmd([ 'multipathd', 'add', 'path', $sd ],
                   timeout => 20, allow_nonzero => 1) };
    return $@ ? 0 : 1;
}

# The reason the last resize_map call did not run, or undef. File-scoped rather
# than returned, because the 1/0 contract has other callers and a second return
# value in scalar context is exactly the kind of quiet wrong answer this module
# exists to avoid. One process resizes one map at a time.
my $last_resize_error;

sub last_resize_error { return $last_resize_error }

sub resize_map {
    _not_a_method($_[0]);
    my ($name) = @_;
    $last_resize_error = undef;
    if (!defined $name || !length $name) {
        $last_resize_error = 'no map name given';
        return 0;
    }
    # Refreshes an existing map's size. NOT a host scan: a scan discovers new
    # devices, it does not refresh the ones already there.
    #
    # `allow_nonzero` covers multipathd DECLINING. It does not cover multipathd
    # never being reached, and the difference is not academic: for as long as
    # this returned a bare 0 for both, a `multipathd` that could not even be
    # executed looked identical to one that had looked and found nothing to do.
    my $ok = eval {
        run_cmd([ 'multipathd', 'resize', 'map', $name ],
                timeout => 30, allow_nonzero => 1);
        1;
    };
    return 1 if $ok;

    $last_resize_error = $@ // 'unknown error';
    $last_resize_error =~ s/\s+\z//;
    return 0;
}

# IS THIS MAP OURS AT ALL? Asked of the kernel, before anything is flushed.
#
# Returns 1 / 0 / undef, and undef means "could not establish" — which the flush
# path treats as no, because a cleanup that cannot tell whose disk it is holding
# must not remove it.
#
# The reaper only ever considers WWIDs from this node's own tracking file, which
# the plugin wrote itself, so a foreign WWID cannot get in there in normal
# operation. This is the second line: if one ever did — a hand-edited file, a
# restored backup of one, a future bug — the flush would otherwise act on another
# vendor's map. The vendor comes from `/sys/block/<sd>/device/vendor`, which is
# the kernel's own record of the SCSI INQUIRY rather than a tool's choice of
# words.
sub map_is_ours {
    _not_a_method($_[0]);
    my ($wwid) = @_;
    return undef if !defined $wwid || !length $wwid;

    my $slaves = slaves_of_map($wwid);
    return undef if ref $slaves ne 'ARRAY' || !@$slaves;

    my $seen_any = 0;
    for my $sd (@$slaves) {
        my ($base) = $sd =~ m{([^/]+)\z} or next;
        next if $base !~ /\A[a-z0-9]+\z/;
        my $v = sysfs_read_with_timeout("/sys/block/$base/device/vendor", 3);
        next if !defined $v;
        $v =~ s/\s+\z//; $v =~ s/\A\s+//;
        $seen_any = 1;
        # One foreign path is enough to refuse: a map this plugin owns has none.
        return 0 if uc($v) ne VENDOR;
    }
    return $seen_any ? 1 : undef;
}

sub flush_map {
    _not_a_method($_[0]);
    my ($name, %opt) = @_;
    return 0 if !defined $name || !length $name;

    # Optional, and what makes the verification below possible. Callers that
    # have it should pass it; the WWID is how this module identifies anything.
    my $wwid = $opt{wwid};

    # WHOSE MAP IS THIS. Checked before the first destructive command, not
    # after: `disablequeueing` and `fail_if_no_path` already change how another
    # vendor's map behaves under a path failure. Refused on undef as well as on
    # 0 — a cleanup that cannot tell whose disk it is holding must not remove it.
    if (defined $wwid) {
        my $ours = map_is_ours($wwid);
        if (!defined $ours || !$ours) {
            warn "refusing to flush map '$name': "
               . (defined $ours ? "its device does not report vendor " . VENDOR
                                : "could not establish which vendor it belongs to")
               . ". Nothing was changed.\n";
            return 0;
        }
    }

    # Stop queueing first, or the flush waits forever for I/O that can never
    # complete once the paths are gone.
    eval { run_cmd([ 'multipathd', 'disablequeueing', 'map', $name ],
                   timeout => 15, allow_nonzero => 1) };
    eval { run_cmd([ 'dmsetup', 'message', $name, '0', 'fail_if_no_path' ],
                   timeout => 15, allow_nonzero => 1) };

    # THE MAP NAME, NOT A /dev/mapper PATH. Measured in the related project:
    # `multipath -f /dev/mapper/<wwid>` answers **device not found** and exits 1,
    # while `multipath -f <wwid>` exits 0 and removes the map. The symlink exists
    # and points at the right dm device; multipath simply does not accept that
    # form.
    #
    # And the wrong form was invisible, twice over. The code below treats
    # "device not found" as SUCCESS — correctly, for the case it was written for:
    # after `fail_if_no_path`, multipathd may have removed the map already. So a
    # flush that never happened was indistinguishable from one that was already
    # done. This one does not take the command's word for it: the map is looked
    # up again afterwards.
    my ($out, $err, $rc) = eval {
        run_cmd([ 'multipath', '-f', $name ], timeout => 30, allow_nonzero => 1);
    };
    my $failure = $@;

    # The map is gone or it is not, and that is checkable. `map_is_gone` is
    # three-valued, so read `defined` first — undef means the stat never came
    # back, which is not "removed".
    # Declared unconditionally: `my $x = ... if ...` keeps its value between
    # calls in Perl, which is a real trap and not a style opinion.
    my $gone;
    $gone = map_is_gone($wwid) if defined $wwid;
    return 1 if defined $gone && $gone;

    # No WWID to check with: fall back to what the command said, including the
    # "already removed" text that is a legitimate success.
    if (!defined $wwid) {
        my $text = join(' ', grep { defined } ($out, $err, $failure));
        return 1 if $text =~ /device not found|map not found/i;
        return 0 if $failure;
        return ($rc // 0) == 0 ? 1 : 0;
    }

    return 0;
}

# Host cache symmetry, which the related projects had to learn the hard way.
#
# **Flush BEFORE a snapshot**, or the snapshot records what reached the NAS
# rather than what the guest believes it wrote.
#
# **Flush BEFORE a rollback and invalidate AFTER**, and the first of those is the
# one that is easy to leave out: dirty pages written back after the NAS has
# restored the snapshot land pre-rollback content on top of it, and the result
# looks like a rollback that half worked. The second was demonstrated in the
# related project directly — reading the device straight after a successful
# rollback returned the OLD bytes until the cache was invalidated, so a caller
# that checked its own work would have concluded the rollback had failed.
#
# THREE-VALUED, and the middle case is the one that matters:
#
#   1     flushed
#   0     a device IS here and the flush failed
#   undef no device on this node, so there was nothing to flush
#
# The last two must not be the same `0`: PVE requires a VM to be STOPPED before
# a disk rollback, and a stopped VM has been deactivated, so the device is gone
# from this node. That is the safest state there is — no device, therefore no
# dirty pages, therefore nothing that could land on top of the restored
# snapshot — and reporting it as "the flush failed" refuses every rollback from
# a clean stop.
sub flush_device_cache {
    _not_a_method($_[0]);
    my ($wwid) = @_;
    my $path = device_path_for_wwid($wwid);
    return undef if !defined $path;
    my $ok = eval { run_cmd([ 'blockdev', '--flushbufs', $path ],
                            timeout => 30, allow_nonzero => 1); 1 };
    return $ok ? 1 : 0;
}

# Drop what the host has cached for ONE device. Not `/proc/sys/vm/drop_caches`,
# which throws away every cache on the node including other storages'.
# Same three-valued contract as flush_device_cache above, for the same reason.
sub invalidate_device_cache {
    _not_a_method($_[0]);
    my ($wwid) = @_;
    my $path = device_path_for_wwid($wwid);
    return undef if !defined $path;

    # BLKFLSBUF via blockdev discards the buffer cache for this device only.
    my $ok = eval { run_cmd([ 'blockdev', '--flushbufs', $path ],
                            timeout => 30, allow_nonzero => 1); 1 };

    # And re-read the partition table, which is what makes the kernel drop its
    # cached view of the contents. Harmless on a device with no partitions.
    $ok &&= eval { run_cmd([ 'blockdev', '--rereadpt', $path ],
                           timeout => 30, allow_nonzero => 1); 1 };
    return $ok ? 1 : 0;
}

# fuser lives in different places on different distributions, and a hardcoded
# path that does not exist makes the check return undef forever — which is safe,
# but means every delete refuses and nothing works. One resolver, in the command
# runner, so a command added later cannot be the one that forgets.
sub _fuser {
    return tool_path('fuser') // 'fuser';
}

# ---------------------------------------------------------------------------
# Is anything using this device?
# ---------------------------------------------------------------------------
#
# PORTED from the related projects, where its absence was a defect and its
# every-check-can-fail behaviour was a second one. The contract is what matters:
#
#   **1 / 0 / undef**, and the destructive paths refuse on undef.
#
# Every check inside can fail without proving anything — the stat can time out,
# sysfs can be unreadable, `fuser` can be killed by its own timeout. And `fuser`
# is the only one that sees a running QEMU, which holds the device open with no
# mount and no holder: if it did not run, nothing else has ruled that out.

sub _resolve_block_device_name {
    my ($device) = @_;
    return undef unless defined $device;

    if (-l $device) {
        my $target = readlink($device);
        if (defined $target) {
            if ($target !~ m|^/|) {
                $target = dirname($device) . "/$target";
            }
            while ($target =~ s|/[^/]+/\.\./|/|g) { }
            $device = $target;
        }
    }

    return _untaint_device_name(basename($device));
}

sub _read_tables {
    my $mounts = sysfs_read_with_timeout('/proc/mounts', 5);
    my $swaps  = sysfs_read_with_timeout('/proc/swaps', 5);
    return ($mounts, $swaps);
}

# A dm name that belongs to a partition of a multipath map rather than to
# something stacked on it. Kernel and kpartx spell these several ways
# depending on configuration:
#   <wwid>-part1, <wwid>p1, <wwid>1, <alias>-part1, sdf1
sub _dm_name_of {
    my ($kernel_name) = @_;
    my $file = "/sys/block/$kernel_name/dm/name";
    return '' unless -r $file;
    my $name = sysfs_read_with_timeout($file, 3) // '';
    chomp $name;
    return $name;
}

sub _is_partition_dm_name {
    my ($dm_name) = @_;
    return 0 unless defined $dm_name && length $dm_name;
    return 1 if $dm_name =~ /part\d+$/;
    return 1 if $dm_name =~ /^[0-9a-f]{20,}p?\d+$/;
    return 1 if $dm_name =~ /^sd[a-z]+\d+$/;
    return 0;
}

# A name read out of /sys or from a path is used only AFTER the match returns
# it — the captured value, never the one that went in. It is the taint
# discipline and the correctness check in one, and it makes a wrong pattern fail
# as "nothing found" in one place rather than in three.
sub _untaint_device_name {
    my ($name) = @_;
    return undef unless defined $name;
    return $1 if $name =~ /^([a-zA-Z0-9_\-]+)$/;
    return undef;
}

sub _untaint_device_path {
    my ($path) = @_;
    return undef unless defined $path;
    return $1 if $path =~ m|^(/dev/[a-zA-Z0-9_\-/\.]+)$|;
    return undef;
}

# Is the device mounted, used as swap, held by something, or open by a process?
#
# Partition devices created from the guest's own partition table are the one
# exception: they exist on every VM disk that has an OS installed, nothing on
# the host uses them. They only count as in-use when they have holders of their
# own (host LVM having auto-activated a VG from inside the guest disk) or are
# themselves mounted or in use as swap.
#
# 1 = in use, 0 = confirmed not in use, undef = COULD NOT TELL.
#
# The third answer matters. Two destructive paths ask this question — a delete
# and a rollback — and for them "cannot tell" has to mean "do not". Reading an
# unknown as "free" is how a volume gets unmapped and deleted underneath a
# running VM, or rolled back while the guest is writing to it.
sub is_device_in_use {
    my ($device, %opts) = @_;

    return 0 unless $device;

    my $is_block = is_block_device($device);

    # A path that is not there, or is not a block device, is definitely not in
    # use — stat on a missing path fails immediately and touches no driver.
    # Only a stat that never came back leaves the question open.
    return undef unless defined $is_block;
    return 0 unless $is_block;

    my $dev_name = _resolve_block_device_name($device);
    return undef unless $dev_name;

    my ($mounts, $swaps) = _read_tables();

    for my $table ($mounts, $swaps) {
        next unless $table;
        for my $line (split /\n/, $table) {
            return 1 if $line =~ /^\Q$device\E\s/;
            return 1 if $line =~ m|^/dev/\Q$dev_name\E\s|;
        }
    }

    # Holders must be checked on the resolved kernel name (dm-N). Checking the
    # /dev/mapper name instead silently finds nothing, and free_image would
    # then delete a volume that host LVM is actively using.
    my $holders_dir = "/sys/block/$dev_name/holders";
    if (-d $holders_dir) {
        opendir(my $dh, $holders_dir) or return undef;
        my @holders = grep { !/^\./ } readdir($dh);
        closedir($dh);

        for my $h (@holders) {
            my $dm_name = _dm_name_of($h);

            # Anything that is not a partition (LVM LV, dm-crypt, MD) means
            # the device is genuinely in use.
            return 1 unless _is_partition_dm_name($dm_name);

            # A partition with its own holders means something is stacked on
            # it, e.g. a VG activated from inside the guest disk.
            if (opendir(my $sdh, "/sys/block/$h/holders")) {
                my @sub = grep { !/^\./ } readdir($sdh);
                closedir($sdh);
                return 1 if @sub;
            }

            # /proc/mounts records whichever path was used to mount, so check
            # both spellings.
            my $part_dev    = "/dev/$h";
            my $part_mapper = length($dm_name) ? "/dev/mapper/$dm_name" : '';
            for my $table ($mounts, $swaps) {
                next unless $table;
                return 1 if $table =~ /^\Q$part_dev\E\s/m;
                return 1 if $part_mapper && $table =~ /^\Q$part_mapper\E\s/m;
            }
        }
    }

    my $safe_device = _untaint_device_path($device);
    return undef unless $safe_device;

    my (undef, undef, $exit) = eval {
        run_cmd([ _fuser(), '-s', $safe_device],
            timeout => 10, allow_nonzero => 1, ignore_errors => 1);
    };
    my $fuser_error = $@;

    # fuser is the only check here that sees a process holding the device
    # open with no mount and no holder — which is exactly what a running QEMU
    # looks like. If it could not run, nothing above it has ruled that out.
    return undef if $fuser_error || !defined $exit;

    return 1 if $exit == 0;

    return 0;
}

# Is the map gone? Confirmed, not assumed.
sub map_is_gone {
    _not_a_method($_[0]);
    my ($wwid) = @_;

    # An unusable WWID was never asked about, so nothing is known about it.
    # Returning "gone" here would let a delete path conclude the device had
    # been cleaned up when it had not even looked.
    my $link = dm_uuid_path($wwid);
    return undef if !defined $link;

    my $ok = is_block_device($link);
    # undef is "the stat never came back", which is also not "gone".
    return undef if !defined $ok;
    return $ok ? 0 : 1;
}

1;
