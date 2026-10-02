package PVE::Storage::Custom::QNAP::Health;

# What `status()` answers, and how an outage is reported.
#
# `status()` runs roughly every ten seconds, per node, per storage, and PVE runs
# them sequentially — so anything slow here delays every other storage on the
# node. Two rules follow, and both are inherited:
#
#   * The health path uses the short-timeout client. The next poll is the retry.
#   * **No per-object call.** Capacity comes from one pool read; the LUN count
#     from one listing. (objects × nodes) requests every ten seconds is what
#     collapses a management interface — and on QTS a per-LUN read is a whole
#     round trip, because `extra_lun_index` carries no capacity at all.
#
# There is a second reason the numbers here are not the whole story, and it is
# why `lun_pressure` exists: this storage's real ceiling may be the LUN COUNT
# rather than space. A NAS with 40 TB free and 256 of 256 LUNs is full, and PVE
# has no way to express that — `pvesm status` would show terabytes available.

use strict;
use warnings;

use PVE::Storage::Custom::QNAP::API;

use constant CGI_DISK => 'disk/disk_manage.cgi';

# A storage whose NAS cannot be reached must report inactive quickly and say why
# once, not on every poll. PVE stops polling a storage it has marked inactive,
# so a consecutive-failure counter would never fire — the report has to happen
# on the first failure.
my %warned;

sub _warn_once {
    my ($key, $msg) = @_;
    return if $warned{$key};
    $warned{$key} = 1;
    warn $msg;
    return;
}

# The same once-only warning, for callers outside this module.
sub warn_once_for {
    my ($storeid, $key, $msg) = @_;
    _warn_once("$storeid:$key", $msg);
    return;
}

sub clear_warnings {
    my ($storeid) = @_;
    delete $warned{$_} for grep { /\A\Q$storeid\E:/ } keys %warned;
    PVE::Storage::Custom::QNAP::API::clear_warnings($storeid);
    return;
}

# ---------------------------------------------------------------------------
# Pools
# ---------------------------------------------------------------------------

# Every storage pool on the NAS, as ids. One call.
sub pool_list {
    my ($api) = @_;
    my $r = $api->call(CGI_DISK, func => 'extra_get', extra_pool_index => 1);
    return undef if $r->{transport};
    my $rows = PVE::Storage::Custom::QNAP::API::rows($r, '//Pool_Index/row');
    return [ grep { defined && length } map { $_->{poolID} } @$rows ];
}

# One pool, in full. Returns undef when the NAS could not be asked, and an empty
# hash is never returned in its place: "could not ask" and "there is no such
# pool" are different answers and only one of them is worth checking a network
# cable over.
sub pool_info {
    my ($api, $pool_id) = @_;
    return undef if !defined $pool_id;

    my $r = $api->call(CGI_DISK,
        func => 'extra_get', Pool_Info => 1, poolID => $pool_id);
    return undef if $r->{transport};

    my ($row) = @{ PVE::Storage::Custom::QNAP::API::rows($r, '//Pool_Index/row') };
    return undef if !$row;
    return undef if defined $row->{poolID} && $row->{poolID} ne "$pool_id";

    return {
        id        => $row->{poolID},
        status    => $row->{pool_status},
        # Bytes. The NAS also returns these figures formatted for a human, and
        # those are never parsed: "1.5 TB" is a rounding of the truth, and PVE
        # needs the truth.
        total     => _int($row->{capacity_bytes}),
        free      => _int($row->{freesize_bytes}),
        allocated => _int($row->{allocated_bytes}),
        # `real_freesize_bytes` is what a new allocation can ACTUALLY draw on.
        # It is preferred over `freesize_bytes` where present, because the
        # difference is the space the NAS has set aside for snapshots — space
        # this plugin's own snapshots will consume.
        real_free => _int($row->{real_freesize_bytes}),
        threshold => $row->{pool_threshold},
        over_threshold => $row->{pool_over_threshold},
        type      => $row->{pool_type},
    };
}

sub _int {
    my ($v) = @_;
    return undef if !defined $v || $v !~ /\A\d+\z/;
    return $v + 0;
}

# ---------------------------------------------------------------------------
# status()
# ---------------------------------------------------------------------------

# Returns **($total, $available, $used, $active)** in bytes — PVE's own order,
# which is what `PVE::Storage::Plugin::status` returns and NOT the intuitive
# one. Getting it backwards shows the NAS's free space in the Used column, and
# worse: `qnap-min-free` would then compare against used space, so the guard
# meant to stop a pool filling up would be reading the wrong number entirely.
#
# Dies for nothing: an unreachable NAS is reported as inactive, because that is
# what PVE does with the answer, and a die here would make `pvesm status` fail
# for every storage on the node rather than one.
sub status {
    my ($api, $lun, %opt) = @_;
    my $pool_id = $opt{pool_id};
    my $storeid = $api->storeid;

    my $pool = eval { pool_info($api, $pool_id) };
    my $threw = $@;

    if ($threw) {
        chomp $threw;
        _warn_once("$storeid:unreachable",
            "storage '$storeid': the NAS did not answer: $threw\n");
        return (0, 0, 0, 0);
    }

    if (!defined $pool) {
        # The NAS answered and described no such pool, OR could not be reached.
        # Both end here because QTS gives no code that separates them, so the
        # message names both possibilities rather than picking one and being
        # wrong half the time.
        _warn_once("$storeid:nopool",
            "storage '$storeid': the NAS did not describe storage pool"
          . " '$pool_id'. Either qnap-pool names a pool that does not exist"
          . " (Storage & Snapshots shows the number) or the NAS could not be"
          . " reached.\n");
        return (0, 0, 0, 0);
    }

    my $total = $pool->{total};
    if (!defined $total) {
        _warn_once("$storeid:nosize",
            "storage '$storeid': the NAS described pool '$pool_id' without a"
          . " capacity, so nothing can be said about its free space.\n");
        return (0, 0, 0, 0);
    }

    my $free = $pool->{real_free} // $pool->{free} // 0;
    my $used = $total - $free;
    $used = 0 if $used < 0;

    # A pool that is not READY cannot be allocated into, whatever its free space
    # says. Anything negative is
    # an error state and 0 is READY. A positive value is an operation in
    # progress — rebuilding, expanding, resyncing — which is not an error and is
    # not a reason to take the storage away from a running cluster, so it warns
    # and stays active.
    my $st = $pool->{status};
    if (defined $st && $st =~ /\A-\d+\z/) {
        _warn_once("$storeid:poolstatus",
            "storage '$storeid': storage pool '$pool_id' reports status $st,"
          . " which is an error state. Check Storage & Snapshots on the NAS.\n");
        return ($total, 0, $used, 0);
    }
    if (defined $st && $st =~ /\A[1-9]\d*\z/) {
        _warn_once("$storeid:poolbusy",
            "storage '$storeid': storage pool '$pool_id' reports status $st:"
          . " the NAS is working on it (rebuilding, expanding or resyncing)."
          . " The storage is still usable and performance may be reduced.\n");
    }

    if ($pool->{over_threshold} && $pool->{over_threshold} ne '0') {
        _warn_once("$storeid:threshold",
            "storage '$storeid': storage pool '$pool_id' is over its own"
          . " threshold of " . ($pool->{threshold} // '?') . "%. Thin LUNs can"
          . " overcommit a pool, and a full pool affects every VM on it.\n");
    }

    # Reported, not deducted: PVE has one number for available space and it
    # should stay the truth about space. The count is what a warning is for.
    lun_pressure($api, $lun, $storeid);

    return ($total, $free, $used, 1);
}

# Warn as the LUN ceiling approaches. One VM disk is one LUN, and no amount of
# free space answers this — so an operator who only ever looks at `pvesm status`
# would get no notice at all.
sub lun_pressure {
    my ($api, $lun, $storeid) = @_;
    return if !$lun;

    my $max = eval { $api->limits->{luns} } or return;

    my $luns = eval { $lun->list };
    return if !$luns;
    my $have = scalar @$luns;
    my $left = $max - $have;

    if ($left <= 0) {
        _warn_once("$storeid:lunfull",
            "storage '$storeid': the NAS holds $have LUNs, this model's maximum"
          . " ($max). No further disks can be created however much space is"
          . " free. The count includes LUNs this storage does not own.\n");
    } elsif ($left <= 16) {
        _warn_once("$storeid:lunnear",
            "storage '$storeid': $have of $max LUNs used on this NAS: $left"
          . " left. One VM disk is one LUN.\n");
    }
    return;
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

# What makes a storage usable at all, checked when it is ADDED rather than
# discovered at the first allocation or, worse, at the first snapshot.
sub assert_usable {
    my ($api, %opt) = @_;
    my $storeid = $api->storeid;
    my $pool_id = $opt{pool_id};

    my $info = $api->sysinfo;
    my $model = $info->{model} // 'this NAS';
    my $fw    = $info->{firmware} // '?';

    # Storage Manager V2 is the API surface this plugin implements. The legacy
    # one is a different set of calls entirely, so this is a refusal rather than
    # a branch — and it is refused HERE, with the firmware version in the
    # message, instead of surfacing later as a listing that is mysteriously
    # empty.
    die "storage '$storeid': $model is running firmware $fw, which reports the"
      . " LEGACY Storage Manager rather than Storage Manager V2. This plugin"
      . " implements the V2 API only. QTS 4.5.1 or later, or QuTS hero h5.x,"
      . " provides V2.\n" if !$api->is_storage_v2;

    # QuTS hero h6.0 and later. Refused for the same reason and at the same
    # moment: measured on h6.0.1, the storage could be described but neither a
    # target nor a LUN could be created, so adding it would leave a storage that
    # reports its capacity and can hold nothing.
    my $unsupported = $api->unsupported_firmware;
    die "storage '$storeid': $model is running $unsupported. This plugin does"
      . " not work on QuTS hero h6.0 or later: measured on h6.0.1, the NAS"
      . " refuses the calls this plugin uses to create targets and LUNs. Use"
      . " QuTS hero h5.x or QTS.\n" if defined $unsupported;

    # The iSCSI service being off is the single most likely reason a correctly
    # configured storage does nothing at all, and QTS ships it off.
    my $portal = $api->portal_info;
    my $on = $portal->{service_enabled};
    die "storage '$storeid': the iSCSI target service is turned off on $model."
      . " Turn it on in Storage & Snapshots > iSCSI & Fibre Channel, then add"
      . " the storage again.\n" if defined $on && $on eq '0';

    die "storage '$storeid': no storage pool is configured. Set qnap-pool to"
      . " the pool number Storage & Snapshots shows.\n"
        if !defined $pool_id || $pool_id !~ /\A\d+\z/;

    my $pools = pool_list($api);
    die "storage '$storeid': the NAS would not list its storage pools, so"
      . " qnap-pool cannot be checked. Nothing else can be trusted without"
      . " it.\n" if !defined $pools;

    die "storage '$storeid': there is no storage pool $pool_id on $model."
      . " The pools it has are: "
      . (@$pools ? join(', ', @$pools) : '(none)')
      . ". Storage & Snapshots shows the number.\n"
        if !grep { $_ eq "$pool_id" } @$pools;

    my $pool = pool_info($api, $pool_id);
    die "storage '$storeid': storage pool $pool_id is listed but could not be"
      . " described.\n" if !defined $pool;

    my $st = $pool->{status};
    die "storage '$storeid': storage pool $pool_id reports status $st, which is"
      . " an error state. Fix it in Storage & Snapshots before adding the"
      . " storage.\n" if defined $st && $st =~ /\A-\d+\z/;

    # SNAPSHOTS ARE NOT UNIVERSAL, and finding that out at the first `qm
    # snapshot` is far too late — by then there are VMs on the storage.
    #
    # A snapshot of an iSCSI LUN needs a block-based LUN in a storage pool, and
    # QNAP's entry-level models ship without snapshot support at all. This
    # cannot be established in advance: there is no capability flag this plugin
    # reads for it. So it is a warning with a specific
    # instruction rather than a refusal — refusing on a guess would lock out
    # models that work.
    warn "storage '$storeid': snapshots of iSCSI LUNs need a model that"
       . " supports them and a block-based LUN in a storage pool. This plugin"
       . " has no way to check that in advance."
       . " Take one snapshot of a test disk before you rely on"
       . " it.\n" if !$opt{quiet};

    # QTS: said once, when the storage is added, because the first place an
    # operator would otherwise meet it is a refused `qm clone` of a template.
    warn "storage '$storeid': $model runs QTS. On QTS this plugin makes no"
       . " linked clones and no clones from a snapshot: clone a template with a"
       . " full clone (qm clone <vmid> <newid> --full 1). Snapshots and"
       . " rollback work, and a rollback takes as long as the NAS needs to"
       . " write the disk back. QuTS hero h5.x has instant clones.\n"
        if !$opt{quiet} && !$api->is_zfs;

    return 1;
}

# The NAS's own identity, for `get_identity`. Pinned to something intrinsic
# rather than to an address, because an address can be re-pointed at a different
# NAS — and PVE uses this to decide whether two storages are the same one.
#
# The iSCSI target IQN postfix is that identity here: QTS derives it per NAS and
# it appears in every target's IQN. No serial number is available from the
# calls this plugin makes.
sub nas_identity {
    my ($api) = @_;
    my $p = eval { $api->portal_info } // {};
    my $post = $p->{iqn_postfix};
    return $post if defined $post && length $post;

    my $i = eval { $api->sysinfo } // {};
    my $host = $i->{hostname};
    return defined $host && length $host ? "host:$host" : undef;
}

1;
