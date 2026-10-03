package PVE::Storage::Custom::QNAP::LUN;

# iSCSI LUNs and their snapshots, on top of QNAP::API.
#
# Five facts about QTS shape this module, because each of them makes an obvious
# implementation wrong:
#
#   1. **A LUN is created in whole GiB.** `add_lun` takes `LUNCapacity` as a
#      whole number, and one unit of it is 2^30 bytes — GiB, not GB — so there
#      is no finer granularity available. Proxmox VE allocates in KiB. Every size is
#      therefore rounded UP to the next GiB, and `volume_size_info` reports what
#      the NAS actually has rather than what PVE asked for: a volume that
#      reports less than the configuration claims is one QEMU will refuse to
#      start.
#
#   2. **Three different calls are spelled `func=edit_lun`.** On
#      `iscsi_lun_setting.cgi` it changes the LUN itself (name, capacity). On
#      `iscsi_target_setting.cgi` it enables or disables the LUN *on a target*.
#      Same word, different CGI, opposite meaning. Every call here names the CGI
#      in full for that reason.
#
#   3. **`LUNIndex` is not `LUNNumber`.** `LUNIndex` identifies the LUN on the
#      whole NAS; `LUNNumber`, from `lun_info`'s `LUNTargetList`, is its
#      number *within one target* and is what appears in the by-path device
#      name. They are different numbers and QTS reuses the second one.
#
#   4. **QTS has no LUN-to-LUN clone.** `clone_qsnapshot` clones a SNAPSHOT and
#      it is the only clone there is, so cloning a live disk means taking a
#      snapshot first. On QuTS hero the same call without `poolID` is an INSTANT
#      clone, which is what makes a Proxmox VE linked clone actually cheap — and
#      the snapshot it hangs off must then be kept, not tidied away.
#
#   5. **A snapshot carries no record of who took it.** The snapshot listing
#      returns id, name, create time and status and nothing else. So ownership
#      lives entirely in the NAME — see Naming — and it is the only thing
#      standing between `qm destroy` and an operator's own scheduled snapshot of
#      the same LUN.

use strict;
use warnings;

use JSON;

use PVE::Storage::Custom::QNAP::API;
use PVE::Storage::Custom::QNAP::Naming;

use constant {
    CGI_LUN    => 'disk/iscsi_lun_setting.cgi',
    CGI_PORTAL => 'disk/iscsi_portal_setting.cgi',
    CGI_TARGET => 'disk/iscsi_target_setting.cgi',
    CGI_SNAP   => 'disk/snapshot.cgi',

    GIB => 1024 * 1024 * 1024,

    # `add_lun` answers as soon as the LUN exists, but `lun_info` reports
    # `LUNStatus` 0 while the NAS is still working on it. A thick LUN of any
    # size takes real time, so the bound is generous and the caller is told what
    # is being waited for.
    READY_WAIT_DEFAULT => 600,

    # A clone or a rollback reports through `get_return`, which has no progress
    # of its own beyond `processing`. Half an hour covers a full clone of a
    # large disk on a spinning pool.
    FORK_WAIT_DEFAULT => 1800,
};

sub new {
    my ($class, $api) = @_;
    return bless { api => $api }, $class;
}

sub api { return $_[0]->{api} }
sub _storeid { return $_[0]->{api}->storeid }

# ---------------------------------------------------------------------------
# Sizes
# ---------------------------------------------------------------------------

# Note 1 at the top of this file. Rounded UP, never down, and never to zero: a
# volume smaller than the one PVE believes it created gets filled and then
# fails, and a zero-byte LUN is not a thing QTS will make.
sub bytes_to_gib_up {
    my ($bytes) = @_;
    $bytes = 0 if !defined $bytes || $bytes < 0;
    my $gib = int(($bytes + GIB - 1) / GIB);
    return $gib < 1 ? 1 : $gib;
}

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

# Every LUN on the NAS, cheaply: one call, and the answer carries names and
# indexes but NO capacity.
#
# Unfiltered on purpose. There is no server-side filter to ask for, and even if
# there were, the ceiling this plugin has to respect is per-NAS — it includes
# the operator's own LUNs and any Virtual Machine Manager disks. A listing that
# hid those would under-count against the very limit it is checking.
sub list {
    my ($self) = @_;

    my $r = $self->api->call(CGI_PORTAL, func => 'extra_get', extra_lun_index => 1);
    die "storage '" . $self->_storeid . "': could not list LUNs: $r->{transport}\n"
        if $r->{transport};

    my $result = $r->{result};
    die "storage '" . $self->_storeid . "': could not list LUNs: "
      . PVE::Storage::Custom::QNAP::API::error_text($result) . "\n"
        if defined $result && $result =~ /\A-\d+\z/;

    my $rows = PVE::Storage::Custom::QNAP::API::rows($r, '//LUNInfo/row');

    # A NAS with no LUNs answers with an empty list, and that is a legitimate
    # answer. What is NOT legitimate is an answer with no `<result>` and no
    # rows: that is the shape of a call the firmware did not understand, and
    # treating it as "there are no LUNs" would make every LUN on the NAS an
    # orphan to the reaper.
    die "storage '" . $self->_storeid . "': the NAS answered the LUN listing"
      . " with neither a result nor any rows. Refusing to read that as an empty"
      . " NAS.\n" if !defined $result && !@$rows;

    return [ grep { defined $_->{LUNIndex} && length $_->{LUNIndex} } @$rows ];
}

# One LUN, in full: capacity, NAA, status, and the targets it is mapped to.
#
# Returns undef for a LUN that is not there, and DIES when the NAS could not be
# asked. Those are different answers and only the first may be reported to PVE
# as a completed delete — reporting the second as success makes PVE drop the
# disk from the VM configuration while the LUN stays on the NAS with nothing
# pointing at it.
sub get_by_index {
    my ($self, $index) = @_;
    return undef if !defined $index || $index !~ /\A\d+\z/;

    my $r = $self->api->call(CGI_PORTAL,
        func => 'extra_get', lun_info => 1, lunID => $index);

    die "storage '" . $self->_storeid . "': could not read LUN $index:"
      . " $r->{transport}\n" if $r->{transport};

    my ($row) = @{ PVE::Storage::Custom::QNAP::API::rows($r, '//LUNInfo/row') };
    return undef if !$row;
    # An answer about a different LUN is worse than no answer.
    return undef if defined $row->{LUNIndex} && $row->{LUNIndex} ne "$index";

    return _normalise($row);
}

# By NAME, which is what the plugin actually holds.
#
# QTS offers no lookup by name, so this is a listing and a match. It is one
# extra round trip per operation and there is no way around it; `list` is a
# single call, so the cost is a listing rather than a scan.
sub get {
    my ($self, $name, %opt) = @_;
    return undef if !defined $name || !length $name;

    my $all = $opt{listing} // $self->list;
    my ($row) = grep { ($_->{LUNName} // '') eq $name } @$all;
    return undef if !$row;

    return $self->get_by_index($row->{LUNIndex});
}

# The fields this plugin uses, named once, so nothing downstream has to know
# which of QTS's spellings carries what.
sub _normalise {
    my ($row) = @_;
    return undef if ref $row ne 'HASH';

    my %l = (
        index      => $row->{LUNIndex},
        name       => $row->{LUNName},
        path       => $row->{LUNPath},
        naa        => lc($row->{LUNNAA} // ''),
        serial     => $row->{LUNSerialNum},
        size       => (defined $row->{capacity_bytes} && $row->{capacity_bytes} =~ /\A\d+\z/)
                        ? $row->{capacity_bytes} + 0 : undef,
        allocated  => $row->{lv_allocated},
        status     => $row->{LUNStatus},
        enabled    => $row->{LUNEnable},
        thin       => $row->{LUNThinAllocate},
        removing   => $row->{isRemoving},
        mapped     => $row->{bMap},
        pool_id    => $row->{poolID},
        vol_no     => $row->{volno},
        sector     => $row->{LUNSectorSize},
        threshold  => $row->{LUNThreshold},
        ssd_cache  => $row->{ssd_cache},
        block_base => $row->{VolumeBase},
        progress   => $row->{LUNOPPercent},
    );

    # Where the LUN is mapped, and under which number in each target. Note 3:
    # `LUNNumber`, not `LUNIndex`, is the one the by-path device name carries.
    $l{targets} = [];
    for my $node (@{ $row->{_LUNTargetList} // [] }) {
        for my $t (@{ PVE::Storage::Custom::QNAP::API::sub_rows($node, 'row') }) {
            push @{ $l{targets} }, {
                target_index => $t->{targetIndex},
                lun_number   => $t->{LUNNumber},
                enabled      => $t->{LUNEnable},
            };
        }
    }

    return \%l;
}

# The multipath WWID for a LUN, from the NAA the NAS reports.
#
# `LUNNAA` is the 32 hex digits of an NAA IEEE Registered Extended identifier,
# and multipath's own name for the same thing is that string with a leading `3`
# — the NAA designator type. So this is a translation of the NAS's own answer
# and not a derivation from anything: the kernel independently reports
# `naa.<same digits>` in /sys/block/<sd>/device/wwid, which is what
# Multipath::device_is_lun compares against.
sub wwid_for_naa {
    my ($naa) = @_;
    return undef if !defined $naa;
    $naa =~ s/\Anaa\.//i;
    return undef if $naa !~ /\A([0-9a-fA-F]{16,32})\z/;
    return '3' . lc($1);
}

sub wwid_of {
    my ($lun) = @_;
    return undef if ref $lun ne 'HASH';
    return wwid_for_naa($lun->{naa});
}

# ---------------------------------------------------------------------------
# Waiting
# ---------------------------------------------------------------------------

# `LUNStatus` 0 means the NAS is still working. Anything else — 1 ready, 2 "see
# LUNEnable", -1 error — means it has stopped.
sub wait_ready {
    my ($self, $index, %opt) = @_;
    my $limit = $opt{timeout} // READY_WAIT_DEFAULT;
    my $what  = $opt{what} // 'the operation';

    my $t0 = time;
    while (time - $t0 < $limit) {
        my $lun = $self->get_by_index($index);
        # Gone is not busy. A caller that deleted it races us legitimately.
        return undef if !defined $lun;

        my $st = $lun->{status};
        if (defined $st && $st eq '-1') {
            die "storage '" . $self->_storeid . "': the NAS reports LUN $index"
              . " in an ERROR state after $what. Check Storage & Snapshots on"
              . " the NAS.\n";
        }
        return $lun if !defined $st || $st ne '0';

        # Sub-second. `sleep 1` on a path inside PVE's cluster lock costs a
        # whole second for an operation that usually completes in a fraction of
        # one, and every allocation on the storage waits behind it.
        select(undef, undef, undef, 0.25);
    }

    # A timeout means the NAS is still working, not that it failed. Saying
    # "failed" invites a retry, and a retried create makes a second LUN.
    die "storage '" . $self->_storeid . "': the NAS is still busy with $what on"
      . " LUN $index after ${limit}s. It has NOT failed: check Storage &"
      . " Snapshots on the NAS before retrying, because retrying may duplicate"
      . " it.\n";
}

# ---------------------------------------------------------------------------
# Ceilings
# ---------------------------------------------------------------------------

# Refuse BEFORE the NAS does, so the message names the real reason.
#
# At the ceiling QTS answers with a negative `<result>`, which reaches an
# operator as an allocation failure with a number in it. What they need to be
# told is that the NAS holds its model's maximum number of LUNs — because no
# amount of free space will fix it, and `pvesm status` will happily go on
# showing terabytes free.
sub assert_room_for_lun {
    my ($self, %opt) = @_;

    my $max = $self->api->limits->{luns};
    # The NAS did not say. Stop guarding rather than invent a number.
    return 1 if !defined $max;

    my $have = defined $opt{count} ? $opt{count} : scalar @{ $self->list };
    return 1 if $have < $max;

    die "storage '" . $self->_storeid . "': the NAS already holds $have LUNs,"
      . " which is this model's maximum ($max). Free space is not the problem"
      . " and adding capacity will not help. Delete LUNs, or use a second NAS."
      . " The count includes LUNs this storage does not own, such as Virtual"
      . " Machine Manager disks.\n";
}

# Warn while there is still time to act, once per object rather than on every
# allocation.
sub warn_if_near_lun_limit {
    my ($self, %opt) = @_;
    my $max = $self->api->limits->{luns} or return;
    my $have = defined $opt{count} ? $opt{count} : scalar @{ $self->list };
    my $left = $max - $have;
    return if $left > ($opt{margin} // 16);
    return if $self->{warned_lun_limit};
    $self->{warned_lun_limit} = 1;
    warn "storage '" . $self->_storeid . "': $have of $max LUNs used on this"
       . " NAS: $left left. One VM disk is one LUN.\n";
}

# ---------------------------------------------------------------------------
# Creating
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# QuTS hero h6
# ---------------------------------------------------------------------------
#
# What follows is the h6 path, and it is deliberately narrow.
#
# MEASURED on h6.0.1, and implemented: creating a LUN, deleting one, attaching
# one to a target and detaching it. Each request here is one whose shape and
# answer were seen on that firmware.
#
# NOT MEASURED, and therefore REFUSED rather than guessed at: growing a LUN,
# renaming one, and everything to do with snapshots and clones. A request sent
# in a shape nobody has seen the NAS accept is how a disk ends up half-changed.
use constant {
    REST_VOLUMES => 'api/storage/v1/volumes',
    REST_TARGETS => 'api/iscsi/v1/targets',

    # How long a new volume is waited for before its LUN shows.
    H6_CREATE_WAIT => 300,
};

sub refuse_on_h6 {
    my ($self, $what) = @_;
    return if !$self->api->is_h6;
    die "storage '" . $self->_storeid . "': $what is not available on QuTS hero"
      . " h6 with this plugin yet. On h6 it creates, deletes, attaches and"
      . " detaches disks.\n";
}

# The storage volume behind a LUN. On h6 a LUN is deleted by deleting its
# volume, and the volume has an id of its own that is not the LUN's index.
sub _h6_volume_id {
    my ($self, $index) = @_;

    my $r = $self->api->rest_ok('GET', REST_VOLUMES, undef,
        _what => "listing the NAS's volumes");
    my $all = $r->{collection};
    die "storage '" . $self->_storeid . "': the NAS answered the volume listing"
      . " without a list. Refusing to read that as a NAS with no volumes.\n"
        if ref $all ne 'ARRAY';

    my @hit = grep {
        ref $_ eq 'HASH' && defined $_->{lun_index}
            && "$_->{lun_index}" eq "$index" && defined $_->{volume_id}
    } @$all;
    return undef if !@hit;
    die "storage '" . $self->_storeid . "': " . scalar(@hit) . " volumes on the"
      . " NAS claim LUN $index. Refusing to pick one.\n" if @hit > 1;
    return $hit[0]{volume_id};
}

sub _create_h6 {
    my ($self, $name, $gib, $pool, %opt) = @_;
    my $sid = $self->_storeid;

    die "storage '$sid': a thick LUN cannot be created on QuTS hero h6 with"
      . " this plugin yet. Leave qnap-thin at its default.\n"
        if !(($opt{thin} // 1) ? 1 : 0);
    die "storage '$sid': a sector size other than 512 cannot be set on QuTS"
      . " hero h6 with this plugin yet. Leave qnap-sector-size at its"
      . " default.\n" if ($opt{sector_size} // 512) != 512;

    # Bytes here, where the CGI took whole GiB. The size is still a whole
    # number of GiB, so that a disk is the same size on either firmware.
    my $r = $self->api->rest_ok('POST', REST_VOLUMES, {
        capacity       => $gib * GIB,
        pool_id        => $pool + 0,
        label          => $name,
        provision_type => 'thin',
        type           => 'zvol',
        threshold      => ($opt{threshold} // 80) + 0,
        iscsi          => { create_lun => JSON::true },
    }, _what => "creating LUN '$name' ($gib GiB) in pool $pool");

    my $vol = ref $r->{single} eq 'HASH' ? $r->{single}{volume_id} : undef;
    die "storage '$sid': the NAS reported creating '$name' but named no volume"
      . " for it. Do not retry blindly: check Storage & Snapshots first.\n"
        if !defined $vol || $vol !~ /\A\d+\z/;

    # The LUN comes into being after the volume does, so its index is asked
    # for until it is there.
    my ($index, $t0) = (undef, time);
    while (time - $t0 < H6_CREATE_WAIT) {
        my $v = $self->api->rest('GET', REST_VOLUMES . "/$vol");
        my $li = (!$v->{transport} && ref $v->{single} eq 'HASH')
            ? $v->{single}{lun_index} : undef;
        if (defined $li && $li =~ /\A\d+\z/) { $index = $li; last }
        select(undef, undef, undef, 1);
    }
    die "storage '$sid': the NAS created volume $vol for '$name' but no LUN"
      . " appeared on it within " . H6_CREATE_WAIT . "s. It has NOT been"
      . " removed: check Storage & Snapshots before retrying.\n"
        if !defined $index;

    return $index;
}

sub create {
    my ($self, %opt) = @_;

    $self->assert_room_for_lun(count => $opt{known_lun_count})
        if !$opt{skip_limit_check};

    my $name = $opt{name};
    PVE::Storage::Custom::QNAP::Naming::assert_qts_legal($name);

    my $pool = $opt{pool_id};
    die "storage '" . $self->_storeid . "': no storage pool is configured"
      . " (qnap-pool)\n" if !defined $pool || $pool !~ /\A\d+\z/;

    my $gib = bytes_to_gib_up($opt{size});

    # LOOK FIRST, so that anything cleaned up afterwards is provably an object
    # this call created.
    #
    # This costs one extra listing per allocation and buys certainty. PVE holds
    # `cluster_lock_storage` across the whole allocation, so the check-then-
    # create pair is not racing another node.
    my $listing = $opt{listing} // $self->list;
    if (grep { ($_->{LUNName} // '') eq $name } @$listing) {
        die "storage '" . $self->_storeid . "': a LUN named '$name' already"
          . " exists on the NAS. Not creating, and not touching it. If Proxmox"
          . " VE chose this name it means its view of the storage is"
          . " incomplete: check Storage & Snapshots for a LUN this storage"
          . " does not know about.\n";
    }

    # `FileIO=no` is a block-based LUN, which is the only kind that lives in a
    # pool and the only kind this plugin creates: a file-based LUN sits inside a
    # shared folder, and its snapshots are the folder's rather than the disk's.
    #
    # `LUNPath` for a block-based LUN is the LUN's own name, which reads like a
    # quirk and is one.
    #
    # Thin by default. A thick LUN reserves the whole capacity at creation, and
    # on a NAS where one VM disk is one LUN that makes over-subscription — the
    # thing every hypervisor storage relies on — impossible.
    my %p = (
        func            => 'add_lun',
        LUNThinAllocate => ($opt{thin} // 1) ? 1 : 0,
        LUNName         => $name,
        LUNPath         => $name,
        LUNCapacity     => $gib,
        LUNSectorSize   => ($opt{sector_size} // 512),
        FileIO          => 'no',
        poolID          => $pool,
        lv_ifssd        => ($opt{ssd_cache} ? 'yes' : 'no'),
    );
    # Only meaningful for a thin LUN, and ignored by QTS
    # otherwise. Sent only when it applies, so a thick LUN's request carries
    # nothing that has to be explained.
    $p{lv_threshold} = $opt{threshold} // 80 if $p{LUNThinAllocate};

    my $h6 = $self->api->is_h6;
    my $index = $h6
        ? $self->_create_h6($name, $gib, $pool, %opt)
        : $self->api->call_id(CGI_LUN, %p,
            _what => "creating LUN '$name' ($gib GiB) in pool $pool");

    # `add_lun` answers as soon as the LUN has an index; the NAS may still be
    # laying it out.
    my $lun = $self->wait_ready($index, what => 'creating the LUN');

    # h6 was given a LABEL, and everything else in this plugin finds a LUN by
    # its NAME. If the NAS called the LUN something else, the disk would be
    # created and then never found again.
    die "storage '" . $self->_storeid . "': the NAS created LUN $index for"
      . " '$name' but calls it '" . ($lun->{name} // '?') . "'. This plugin"
      . " finds a disk by that name, so it would not find this one again."
      . " Remove LUN $index on the NAS.\n"
        if $h6 && defined $lun && ($lun->{name} // '') ne $name;

    die "storage '" . $self->_storeid . "': QTS reported creating LUN '$name'"
      . " as index $index, but it cannot be read back. Do not retry blindly:"
      . " check Storage & Snapshots first.\n" if !defined $lun;

    # Without an NAA there is no way to find this disk on a node, and a LUN that
    # cannot be found is worse than one that was never made — PVE would record
    # a volume nothing can open. Said here, once, rather than at every
    # activation.
    die "storage '" . $self->_storeid . "': the NAS created LUN '$name' but"
      . " reports no LUNNAA for it, so no node could identify its device."
      . " Refusing to hand back a volume that cannot be attached; remove LUN"
      . " index $index on the NAS.\n" if !defined wwid_of($lun);

    return $lun;
}

# ---------------------------------------------------------------------------
# Modifying
# ---------------------------------------------------------------------------

# `iscsi_lun_setting.cgi?func=edit_lun` — note 2: NOT the target CGI's call of
# the same name.
#
# QTS's edit takes the LUN's whole description rather than a delta, so every
# field is read back and resent unchanged except the one being altered. Sending
# a partial edit is how a LUN silently loses its thin provisioning or its
# threshold.
sub _edit {
    my ($self, $lun, %change) = @_;

    # Pulled out BEFORE the merge. Left in `%change` it would be flattened into
    # the parameter list alongside the copy `call_ok` is meant to consume, and
    # which of the two won would depend on hash ordering — so the NAS would
    # sometimes be sent a `_what` parameter it has never heard of.
    my $what = delete $change{_what};

    my %p = (
        func            => 'edit_lun',
        LUNIndex        => $lun->{index},
        LUNName         => $lun->{name},
        LUNPath         => $lun->{path},
        LUNStatus       => $lun->{status},
        LUNThinAllocate => $lun->{thin},
        lv_ifssd        => ($lun->{ssd_cache} // 'no'),
        LUNCapacity     => bytes_to_gib_up($lun->{size}),
    );
    $p{lv_threshold} = $lun->{threshold} if defined $lun->{threshold};

    %p = (%p, %change);

    # A field the NAS did not report cannot be resent, and guessing one is how
    # an edit changes something nobody asked it to.
    for my $k (keys %p) {
        delete $p{$k} if !defined $p{$k};
    }

    return $self->api->call_ok(CGI_LUN, %p,
        _what => ($what // "editing LUN $lun->{index}"));
}

sub resize {
    my ($self, $lun, $new_bytes) = @_;
    $self->refuse_on_h6('growing a disk');

    my $want_gib = bytes_to_gib_up($new_bytes);
    my $have     = $lun->{size};

    die "storage '" . $self->_storeid . "': the NAS reports no capacity for LUN"
      . " $lun->{index}; not resizing it\n" if !defined $have;

    # Idempotent. PVE pads a requested size up to a multiple of 1024 before
    # calling, and this plugin rounds up to a GiB after that, so a repeated
    # resize to "the same" figure is ordinary rather than exceptional.
    return $lun if $want_gib * GIB <= $have;

    # SMALLER IS REFUSED, LOUDLY, and it must not fall into the branch above.
    #
    # PVE writes the REQUESTED size into the VM configuration regardless of what
    # a plugin returns, so a silent no-op would leave the configuration claiming
    # a size the NAS does not have, the guest seeing the smaller disk, and the
    # next grow-by-N computed from a figure that was never real. `qm resize`
    # refuses a shrink itself — but a plugin that relies on its caller to hold
    # the line is making the same mistake as one that trusts PVE to stop a
    # rollback on a running VM.
    if (defined $new_bytes && $new_bytes < $have) {
        die "storage '" . $self->_storeid . "': refusing to shrink LUN"
          . " $lun->{index} from $have to $new_bytes bytes. Shrinking a LUN"
          . " under a filesystem destroys data, and reporting success without"
          . " doing it would leave the VM configuration claiming a size the NAS"
          . " does not have.\n";
    }

    $self->_edit($lun, LUNCapacity => $want_gib,
        _what => "resizing LUN $lun->{index} to $want_gib GiB");

    my $after = $self->wait_ready($lun->{index}, what => 'resizing the LUN');
    die "storage '" . $self->_storeid . "': LUN $lun->{index} disappeared"
      . " during the resize\n" if !defined $after;
    return $after;
}

sub rename {
    my ($self, $lun, $new_name) = @_;
    $self->refuse_on_h6('renaming a disk');
    PVE::Storage::Custom::QNAP::Naming::assert_qts_legal($new_name);

    # `LUNPath` for a block-based LUN is the LUN name — `add_lun` sends it that
    # way — and an edit that renamed the LUN while leaving the old path
    # behind would leave the two disagreeing about the same object.
    #
    # `LUNPath` is left ALONE for a file-based LUN, where it is a real
    # filesystem path and rewriting it would point the LUN at a file that does
    # not exist. This plugin only creates block-based LUNs, but it can be
    # pointed at a NAS that already has others.
    my %change = (LUNName => $new_name);
    $change{LUNPath} = $new_name
        if ($lun->{block_base} // 'yes') eq 'yes';

    $self->_edit($lun, %change,
        _what => "renaming LUN $lun->{index} to '$new_name'");

    my $after = $self->get_by_index($lun->{index});
    die "storage '" . $self->_storeid . "': LUN $lun->{index} could not be read"
      . " back after being renamed\n" if !defined $after;
    die "storage '" . $self->_storeid . "': QTS reported renaming LUN"
      . " $lun->{index} to '$new_name' but it is still called"
      . " '" . ($after->{name} // '?') . "'\n"
        if ($after->{name} // '') ne $new_name;
    return $after;
}

sub delete {
    my ($self, $index) = @_;

    return $self->_delete_h6($index) if $self->api->is_h6;

    my $r = $self->api->call(CGI_LUN, func => 'remove_lun', LUNIndex => $index);
    die "storage '" . $self->_storeid . "': could not delete LUN $index:"
      . " $r->{transport}\n" if $r->{transport};

    # Confirm absence rather than trusting the answer. QTS's `<result>` for this
    # call is 0 for success, but "could not ask" must never be reported as a
    # completed delete: PVE removes the disk from the VM configuration on
    # success, and the LUN would stay on the NAS with nothing pointing at it.
    my $still = $self->get_by_index($index);
    return 1 if !defined $still;

    my $result = $r->{result};
    die "storage '" . $self->_storeid . "': QTS reported deleting LUN $index"
      . " but it is still there\n"
        if defined $result && $result =~ /\A\d+\z/ && $result == 0;

    die "storage '" . $self->_storeid . "': could not delete LUN $index: "
      . PVE::Storage::Custom::QNAP::API::error_text($result) . ".\n";
}

# h6: the LUN goes when its volume does. Absence is confirmed by the same
# listing as on any other firmware, for the same reason.
sub _delete_h6 {
    my ($self, $index) = @_;

    my $vol = $self->_h6_volume_id($index);
    if (!defined $vol) {
        return 1 if !defined $self->get_by_index($index);
        die "storage '" . $self->_storeid . "': LUN $index is on the NAS but no"
          . " volume claims it, so there is nothing this plugin knows how to"
          . " delete. Remove it in Storage & Snapshots.\n";
    }

    my $r = $self->api->rest('DELETE', REST_VOLUMES . "/$vol");
    return 1 if !defined $self->get_by_index($index);

    die "storage '" . $self->_storeid . "': the NAS reported deleting LUN"
      . " $index but it is still there\n"
        if !$r->{transport} && defined $r->{error_code} && $r->{error_code} == 0;

    die "storage '" . $self->_storeid . "': could not delete LUN $index: "
      . PVE::Storage::Custom::QNAP::API::rest_error_text($r) . ".\n";
}

# ---------------------------------------------------------------------------
# Mapping
# ---------------------------------------------------------------------------
#
# All three of these live on `iscsi_target_setting.cgi`, not on the LUN CGI —
# note 2. They are here rather than in Target.pm because they are things done TO
# a LUN; Target.pm owns the target's own lifecycle.

sub map_to_target {
    my ($self, $index, $target_index) = @_;

    # h6: two steps. Attached first, then enabled; enabling a LUN that is not
    # attached is refused.
    if ($self->api->is_h6) {
        my $path = REST_TARGETS . "/$target_index/luns/$index";
        $self->api->rest_ok('POST', $path, undef,
            _what => "mapping LUN $index to target $target_index");
        $self->api->rest_ok('PUT', $path, { lun_enable => JSON::true },
            _what => "enabling LUN $index on target $target_index");
        return 1;
    }

    # `add_lun` on the TARGET cgi answers with the target index, not 0.
    $self->api->call_id(CGI_TARGET,
        func => 'add_lun', LUNIndex => $index, targetIndex => $target_index,
        _what => "mapping LUN $index to target $target_index");
    return 1;
}

sub unmap_from_target {
    my ($self, $index, $target_index) = @_;

    my $h6 = $self->api->is_h6;
    my $r = $h6
        ? $self->api->rest('DELETE', REST_TARGETS . "/$target_index/luns/$index")
        : $self->api->call(CGI_TARGET,
            func => 'remove_lun', LUNIndex => $index, targetIndex => $target_index);
    return 1 if $h6 && !$r->{transport}
             && defined $r->{error_code} && $r->{error_code} == 0;
    return 1 if !$h6 && !$r->{transport}
             && defined $r->{result} && $r->{result} =~ /\A\d+\z/
             && $r->{result} == 0;

    # A LUN that is not mapped to that target is the state being asked for.
    my $lun = eval { $self->get_by_index($index) };
    return 1 if $@ || !defined $lun;
    return 1 if !grep { ($_->{target_index} // '') eq "$target_index" }
                      @{ $lun->{targets} };

    die "storage '" . $self->_storeid . "': could not unmap LUN $index from"
      . " target $target_index: "
      . ($h6 ? PVE::Storage::Custom::QNAP::API::rest_error_text($r)
             : ($r->{transport}
                // PVE::Storage::Custom::QNAP::API::error_text($r->{result})))
      . "\n";
}

sub set_enabled_on_target {
    my ($self, $index, $target_index, $on) = @_;

    if ($self->api->is_h6) {
        $self->api->rest_ok('PUT', REST_TARGETS . "/$target_index/luns/$index",
            { lun_enable => ($on ? JSON::true : JSON::false) },
            _what => ($on ? "enabling" : "disabling")
                   . " LUN $index on target $target_index");
        return 1;
    }

    $self->api->call_ok(CGI_TARGET,
        func => 'edit_lun', LUNIndex => $index, targetIndex => $target_index,
        LUNEnable => ($on ? 1 : 0),
        _what => ($on ? "enabling" : "disabling")
               . " LUN $index on target $target_index");
    return 1;
}

# The LUN's number WITHIN a target — note 3. undef when it is not mapped there.
sub lun_number_on_target {
    my ($lun, $target_index) = @_;
    return undef if ref $lun ne 'HASH';
    for my $t (@{ $lun->{targets} // [] }) {
        next if ($t->{target_index} // '') ne "$target_index";
        my $n = $t->{lun_number};
        return (defined $n && $n =~ /\A\d+\z/) ? $n + 0 : undef;
    }
    return undef;
}

sub is_mapped_to {
    my ($lun, $target_index) = @_;
    return defined lun_number_on_target($lun, $target_index) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

# Only this plugin's own, by name — note 5. An operator's scheduled snapshot of
# the same LUN is invisible to PVE and therefore cannot be deleted by a VM
# operation.
#
# Returns [ { id, name, snapname, create_time, status, raw } ]. `snapname` is
# what PVE calls it; `name` is what the NAS does.
sub snapshot_list {
    my ($self, $index, %opt) = @_;

    # h6: this plugin takes no snapshots there, so there are none of its own to
    # list, and the listing call has not been measured on that firmware.
    return [] if $self->api->is_h6;

    my $r = $self->api->call(CGI_SNAP,
        func => 'extra_get', snapshot_list => 1, LUNIndex => $index);

    die "storage '" . $self->_storeid . "': could not list snapshots of LUN"
      . " $index: $r->{transport}\n" if $r->{transport};

    my $rows = PVE::Storage::Custom::QNAP::API::rows($r, '//SnapshotList/row');

    my @out;
    for my $s (@$rows) {
        my $name = $s->{snapshot_name};
        next if !defined $name;
        my $snapname = PVE::Storage::Custom::QNAP::Naming::snapname_from_snapshot_name($name);
        next if !$opt{all} && !defined $snapname;
        push @out, {
            id          => $s->{snapshot_id},
            name        => $name,
            snapname    => $snapname,
            create_time => $s->{create_time},
            status      => $s->{status},
            raw         => $s,
        };
    }
    return \@out;
}

# Every snapshot on the LUN, including the operator's. Used only where the
# question is "how many are there" rather than "which are ours" — a ceiling is
# shared with whatever schedule the owner has set up, so counting only ours
# would under-count against the very limit being checked.
sub snapshot_list_all {
    my ($self, $index) = @_;
    return $self->snapshot_list($index, all => 1);
}

sub snapshot_create {
    my ($self, %opt) = @_;
    $self->refuse_on_h6('a snapshot');

    my $index = $opt{lun_index};
    my $name  = $opt{name};
    die "a snapshot needs a name\n" if !defined $name || !length $name;

    # Whether QTS refuses a duplicate snapshot name within a LUN is unmeasured,
    # and a name is the ONLY handle this plugin has on a
    # snapshot — two with the same name and a rollback becomes a coin toss.
    # Checked here rather than hoped for.
    my $existing = $self->snapshot_list($index, all => 1);
    die "storage '" . $self->_storeid . "': LUN $index already has a snapshot"
      . " named '$name' on the NAS.\n"
        if grep { ($_->{name} // '') eq $name } @$existing;

    # `vital` keeps the snapshot out of the NAS's own recycling, and
    # `expire_min` 0 gives it no expiry. A Proxmox VE snapshot that the NAS
    # quietly recycled would be one PVE still lists and cannot roll back to.
    #
    # `snapshot_type` 0 is crash-consistent, which is what a hypervisor snapshot
    # of a block device is. The application-consistent variant needs an agent
    # inside the guest, which is not something a storage plugin can arrange.
    my $id = $self->api->call_id(CGI_SNAP,
        func                 => 'create_snapshot',
        lunID                => $index,
        snapshot_name        => $name,
        snapshot_description => ($opt{description} // 'Proxmox VE'),
        snapshot_type        => 0,
        expire_min           => 0,
        vital                => 1,
        _what => "taking snapshot '$name' of LUN $index");

    # `call_id` accepts any non-negative result, because for `add_target` and
    # `add_lun` **0 is a valid identifier** — the first target on a fresh NAS is
    # index 0. This call is the exception: a snapshot id is strictly
    # greater than zero and everything else is a failure, so zero here is a
    # FAILURE that `call_id` cannot distinguish from success on its own.
    #
    # Left unchecked, a failed snapshot would be reported to PVE as taken. The
    # VM configuration would then carry a snapshot that does not exist on the
    # NAS, and the rollback that eventually followed would refuse with "no
    # snapshot named ..." — long after the moment anything could be done about
    # it.
    die "storage '" . $self->_storeid . "': the NAS refused to take snapshot"
      . " '$name' of LUN $index: it answered 0, which this call reports as a"
      . " failure rather than as an identifier.\n" if $id == 0;

    return $id;
}

sub snapshot_delete {
    my ($self, $snapshot_id) = @_;
    $self->refuse_on_h6('deleting a snapshot');

    my $r = $self->api->call(CGI_SNAP,
        func => 'del_snapshot', snapshotID => $snapshot_id);

    return 1 if !$r->{transport}
             && defined $r->{result} && $r->{result} =~ /\A\d+\z/
             && $r->{result} == 0;

    die "storage '" . $self->_storeid . "': could not delete snapshot"
      . " $snapshot_id: "
      . ($r->{transport}
         // PVE::Storage::Custom::QNAP::API::error_text($r->{result})) . "\n";
}

# Roll a LUN back to one of its snapshots.
#
# `by_lun=1` is what makes this act on this LUN alone. It is never sent any
# other way.
#
# `map_lun` asks QTS to put the mapping back afterwards. It is sent because the
# alternative is a LUN that has been restored and is no longer reachable from
# any node, which looks exactly like a rollback that destroyed the disk.
#
# THE CALLER MUST HOLD THE CLUSTER STORAGE LOCK. This forks on the NAS and its
# result is collected through a channel keyed by CGI name — see API::wait_for_fork.
sub snapshot_rollback {
    my ($self, %opt) = @_;
    $self->refuse_on_h6('a rollback');

    my $index = $opt{lun_index};
    my $snapshot_id = $opt{snapshot_id};

    my $before = $self->get_by_index($index)
        or die "storage '" . $self->_storeid . "': LUN $index is gone; not"
             . " rolling back\n";

    my $r = $self->api->call(CGI_SNAP,
        func         => 'recover_snapshot',
        by_lun       => 1,
        snapshotID   => $snapshot_id,
        stop_service => 'no',
        take_snapshot => 'no',
        map_lun      => 1,
    );

    die "storage '" . $self->_storeid . "': rolling LUN $index back to snapshot"
      . " $snapshot_id failed: $r->{transport}\n" if $r->{transport};

    my $result = $r->{result};
    my $forked = PVE::Storage::Custom::QNAP::API::text($r, 'fork');

    if (defined $forked && $forked eq '1') {
        $result = $self->api->wait_for_fork(CGI_SNAP,
            timeout => ($opt{timeout} // FORK_WAIT_DEFAULT),
            what    => "rolling LUN $index back to snapshot $snapshot_id");
    }

    if (!defined $result || $result !~ /\A-?\d+\z/ || $result != 0) {
        my $extra = '';
        # Two of this call's failure codes say something an
        # operator can act on, and neither is in the generic table.
        $extra = ' The NAS could not unmount the volume: something is still'
               . ' using it.' if defined $result && $result eq '-14';
        $extra = ' The NAS could not take the safety snapshot it makes before'
               . ' reverting.' if defined $result && $result eq '-103';
        die "storage '" . $self->_storeid . "': rolling LUN $index back to"
          . " snapshot $snapshot_id failed: "
          . PVE::Storage::Custom::QNAP::API::error_text($result) . ".$extra\n";
    }

    my $after = $self->wait_ready($index, what => 'rolling the LUN back');
    die "storage '" . $self->_storeid . "': LUN $index could not be read back"
      . " after the rollback\n" if !defined $after;

    # IF THIS EVER FIRES, the device identity changed underneath every node and
    # the assumption this plugin's device handling rests on is wrong. The WWID
    # is what every node uses to find this disk; a rollback that changed it
    # would leave every other node pointing at nothing, or worse, at something
    # else.
    my ($w1, $w2) = (wwid_of($before), wwid_of($after));
    die "storage '" . $self->_storeid . "': the rollback changed the LUN's NAA"
      . " (" . ($w1 // 'none') . " -> " . ($w2 // 'none') . "). Every node now"
      . " sees a different disk. Please report this with your QTS version.\n"
        if ($w1 // '') ne ($w2 // '');

    return $after;
}

# Clone a snapshot into a NEW LUN — note 4, and the only clone QTS has.
#
# On QuTS hero, omitting `poolID` asks for an INSTANT clone: the new LUN shares
# blocks with the snapshot instead of copying it, which is what makes a Proxmox
# VE linked clone cheap. The snapshot then becomes the clone's backing store and
# must not be deleted.
#
# On QTS the same call WITH `poolID` copies. It is the same code path because it
# is the same call; only the presence of `poolID` differs, and `instant` is the
# caller saying which it wants.
#
# THE CALLER MUST HOLD THE CLUSTER STORAGE LOCK — see snapshot_rollback.
sub clone_from_snapshot {
    my ($self, %opt) = @_;
    $self->refuse_on_h6('a clone');

    my $name = $opt{name};
    PVE::Storage::Custom::QNAP::Naming::assert_qts_legal($name);

    my %p = (
        func       => 'clone_qsnapshot',
        by_lun     => 1,
        snapshotID => $opt{snapshot_id},
        new_name   => $name,
    );
    # An instant clone takes no destination pool: it cannot move blocks between
    # pools, which is precisely what makes it instant.
    $p{poolID} = $opt{pool_id} if !$opt{instant};
    # Mapping the clone straight onto a target saves a round trip and a window
    # in which the LUN exists and is unreachable.
    $p{targetIndex} = $opt{target_index} if defined $opt{target_index};

    my $r = $self->api->call(CGI_SNAP, %p);
    die "storage '" . $self->_storeid . "': cloning snapshot $opt{snapshot_id}"
      . " to '$name' failed: $r->{transport}\n" if $r->{transport};

    my $result = $r->{result};
    my $forked = PVE::Storage::Custom::QNAP::API::text($r, 'fork');

    if (defined $forked && $forked eq '1') {
        $result = $self->api->wait_for_fork(CGI_SNAP,
            timeout => ($opt{timeout} // FORK_WAIT_DEFAULT),
            what    => "cloning snapshot $opt{snapshot_id} to '$name'");
    }

    die "storage '" . $self->_storeid . "': cloning snapshot"
      . " $opt{snapshot_id} to '$name' failed: "
      . PVE::Storage::Custom::QNAP::API::error_text($result) . "\n"
        if !defined $result || $result !~ /\A-?\d+\z/ || $result != 0;

    # The clone's index is not in the answer, so it is looked up by the name it
    # was given. A clone that cannot be found afterwards is not a clone.
    my $lun = $self->get($name);
    die "storage '" . $self->_storeid . "': QTS reported cloning snapshot"
      . " $opt{snapshot_id} to '$name' but there is no LUN of that name on the"
      . " NAS. Check Storage & Snapshots before retrying: a retry would make a"
      . " second clone.\n" if !defined $lun;

    return $lun;
}

1;
