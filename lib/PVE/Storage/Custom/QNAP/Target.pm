package PVE::Storage::Custom::QNAP::Target;

# iSCSI targets on QTS.
#
# Four properties of the iSCSI API shape this module, and
# each of them makes the obvious implementation wrong:
#
#   1. **A target's IQN is built by the NAS, not by the client.** `iSCSI_portal` returns a `targetIQNPrefix` that embeds the NAS's model and
#      hostname, and a `targetIQNPostfix` that is a per-NAS suffix; QTS
#      concatenates prefix + the target's name + postfix. A NAS that has been
#      renamed therefore carries targets with two different prefixes. So an IQN
#      is never constructed here and never used to look a target up — targets
#      are found by NAME, and their IQN is read out of the answer.
#
#   2. **`bTargetClusterEnable` is what lets more than one node connect.** A
#      Proxmox VE cluster shares its storage from every node; a target without
#      clustered access admits one initiator and the second node's failure looks
#      like a fabric problem rather than a setting. Every target created here is
#      created with it on.
#
#      AND IT CANNOT BE READ BACK. `targetInfo` returns the digests, the
#      status and the ACL — and not this flag. So there is nothing to compare
#      against, and a plugin cannot reconcile on the hot path what the array
#      will not report. It is written when the target is CREATED, and again
#      whenever the operator runs `pvesm set` on the storage. It is deliberately
#      NOT written on every activation: that would be a write to the NAS every
#      time a VM starts, to correct a value that is almost never wrong.
#
#   3. **This plugin does not manage per-initiator access.** `add_init` and
#      `edit_init` are sent with a target index, initiator index 0 and CHAP
#      settings — the target's default policy entry, which is the one every
#      initiator comes under. Restricting a LUN to named hosts is done in the
#      QTS web interface, not here.
#
#      **CHAP is therefore the access control this plugin relies on.** It is
#      why `qnap-chap-username` exists and why the documentation recommends it
#      for any NAS that is not on a storage-only network.
#
#   4. **`add_target` answers with the new target's index, not with 0.** A
#      generic "result == 0 means success" would read target index 0 — the first
#      target on a fresh NAS — as a failure, and every other index as one too.

use strict;
use warnings;

use PVE::Storage::Custom::QNAP::API;

use constant {
    CGI_TARGET => 'disk/iscsi_target_setting.cgi',
    CGI_PORTAL => 'disk/iscsi_portal_setting.cgi',

    # The ACL row `add_init`/`edit_init` act on — note 3. QTS's "Default
    # Policy".
    DEFAULT_INITIATOR_INDEX => 0,

    # `edit_target`'s targetStatus, which is a COMMAND and not the status the
    # listing reports. The listing answers -1 offline / 0 ready / 1 connected;
    # this call takes 0 to activate and -1 to deactivate.
    ACTIVATE   => 0,
    DEACTIVATE => -1,
};

sub new {
    my ($class, $api) = @_;
    return bless { api => $api }, $class;
}

sub api { return $_[0]->{api} }
sub _storeid { return $_[0]->{api}->storeid }

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

# Every target on the NAS. One call.
sub list {
    my ($self) = @_;

    my $r = $self->api->call(CGI_PORTAL, func => 'extra_get', targetList => 1);
    die "storage '" . $self->_storeid . "': could not list iSCSI targets:"
      . " $r->{transport}\n" if $r->{transport};

    my $rows = PVE::Storage::Custom::QNAP::API::rows($r,
        '//iSCSITargetList/targetInfo');

    # Same reasoning as LUN::list: an answer with neither a result nor any rows
    # is a call the firmware did not understand, and reading it as "this NAS has
    # no targets" would let `on_delete_hook` conclude there is nothing to clean
    # up and `ensure` create a duplicate of a target that already exists.
    die "storage '" . $self->_storeid . "': the NAS answered the target listing"
      . " with neither a result nor any rows. Refusing to read that as a NAS"
      . " with no targets.\n" if !defined $r->{result} && !@$rows;

    my @out;
    for my $t (@$rows) {
        next if !defined $t->{targetIndex};
        push @out, {
            index  => $t->{targetIndex},
            name   => $t->{targetName},
            # Read, never built — note 1.
            iqn    => _clean_iqn($t->{targetIQN}),
            alias  => $t->{targetAlias},
            status => $t->{targetStatus},
        };
    }
    return \@out;
}

# An IQN can arrive wrapped across a line break inside the element, so the
# text content has newlines and indentation in the middle of it.
# An IQN with a space in it matches no session and creates no node record, and
# the failure is one nobody would think to look for.
sub _clean_iqn {
    my ($iqn) = @_;
    return undef if !defined $iqn;
    $iqn =~ s/\s+//g;
    return length($iqn) ? $iqn : undef;
}

sub find_by_name {
    my ($self, $name, %opt) = @_;
    return undef if !defined $name;
    my $all = $opt{listing} // $self->list;
    my ($t) = grep { ($_->{name} // '') eq $name } @$all;
    return $t;
}

# One target in full: the digests, the ACL, and which LUNs are on it.
sub info {
    my ($self, $index) = @_;
    return undef if !defined $index;

    my $r = $self->api->call(CGI_PORTAL,
        func => 'extra_get', targetInfo => 1, targetIndex => $index);
    die "storage '" . $self->_storeid . "': could not read target $index:"
      . " $r->{transport}\n" if $r->{transport};

    my ($row) = @{ PVE::Storage::Custom::QNAP::API::rows($r, '//targetInfo/row') };
    return undef if !$row;

    my %t = (
        index         => $row->{targetIndex},
        name          => $row->{targetName},
        iqn           => _clean_iqn($row->{targetIQN}),
        alias         => $row->{targetAlias},
        status        => $row->{targetStatus},
        data_digest   => $row->{bTargetDataDigest},
        header_digest => $row->{bTargetHeaderDigest},
    );

    # The LUNs mapped to this target, as their NAS-wide indexes. Note that these
    # are `LUNIndex` values and NOT the per-target LUN numbers the by-path
    # device name carries — those come from the LUN's own info.
    $t{lun_indexes} = [];
    for my $node (@{ $row->{_targetLUNList} // [] }) {
        push @{ $t{lun_indexes} },
            @{ PVE::Storage::Custom::QNAP::API::sub_texts($node, 'LUNIndex') };
    }

    # The ACL, which in practice is the single Default Policy row — note 3.
    # `auth` is what a CHAP reconcile can actually compare against.
    $t{initiators} = [];
    for my $node (@{ $row->{_targetACL} // [] }) {
        for my $i (@{ PVE::Storage::Custom::QNAP::API::sub_rows($node, 'targetInitInfo') }) {
            push @{ $t{initiators} }, {
                index       => $i->{initiatorIndex},
                iqn         => _clean_iqn($i->{initiatorIQN}),
                alias       => $i->{initiatorAlias},
                chap        => $i->{bCHAPEnable},
                mutual_chap => $i->{bMutualCHAPEnable},
            };
        }
    }

    # How many initiators are connected right now. `on_delete_hook` uses it to
    # refuse to remove a target another node is still using.
    $t{connected} = 0;
    for my $node (@{ $row->{_initiatorConnList} // [] }) {
        $t{connected} += scalar @{ PVE::Storage::Custom::QNAP::API::sub_rows($node, 'initiatorConnInfo') };
    }

    return \%t;
}

# ---------------------------------------------------------------------------
# Ceilings
# ---------------------------------------------------------------------------

# Refuse BEFORE the NAS does. At the ceiling QTS answers with a negative
# `<result>`, which reaches an operator as a failure with a number in it.
sub assert_room_for_target {
    my ($self, %opt) = @_;

    my $max = $self->api->limits->{targets};
    return 1 if !defined $max;

    my $have = defined $opt{count} ? $opt{count} : scalar @{ $self->list };
    return 1 if $have < $max;

    die "storage '" . $self->_storeid . "': the NAS already has $have iSCSI"
      . " targets, which is this model's maximum ($max). With"
      . " qnap-target-mode=per-volume each disk needs its own target, so this"
      . " ceiling can be reached long before the LUN one:"
      . " qnap-target-mode=shared uses one target for the whole storage and is"
      . " the default for that reason. The count includes targets this storage"
      . " does not own.\n";
}

# ---------------------------------------------------------------------------
# Creating
# ---------------------------------------------------------------------------

# Idempotent: a target that already exists is returned, not re-created. Both a
# duplicate-name refusal and a successful create end in the same lookup, because
# two nodes may reach this at the same moment and PVE's storage lock does not
# cover an activation.
sub ensure {
    my ($self, %opt) = @_;

    my $name = $opt{name};
    die "a target needs a name\n" if !defined $name || !length $name;

    # ONE listing, used for the lookup and for the ceiling count. Two calls
    # would fetch the same data twice on a path that runs for every VM start.
    my $all = $self->list;
    my $existing = $self->find_by_name($name, listing => $all);

    if ($existing) {
        # Reactivate a target somebody deactivated. `targetStatus` -1 is
        # offline, and an offline target accepts no login at all — a VM would
        # fail to start with an iSCSI error and nothing would say why.
        $self->activate($existing) if ($existing->{status} // '0') eq '-1';
        $self->reconcile_chap($existing, %opt);
        return $existing;
    }

    $self->assert_room_for_target(count => scalar @$all)
        if !$opt{skip_limit_check};

    # Note 2: clustered access on, always. Note 4: the answer is the new index.
    my $index = $self->api->call_id(CGI_TARGET,
        func                 => 'add_target',
        targetName           => $name,
        targetAlias          => ($opt{alias} // $name),
        bTargetDataDigest    => 0,
        bTargetHeaderDigest  => 0,
        bTargetClusterEnable => 1,
        _what => "creating iSCSI target '$name'");

    # The ACL row has to exist before CHAP can be set on it, and QTS creates a
    # target without one, so it is written straight after `add_target`.
    $self->_write_acl($index, %opt);

    # Read it back. A create that reports success is not a handle, and the IQN —
    # the one thing a node actually needs — is only in the listing.
    my $t = $self->find_by_name($name);
    die "storage '" . $self->_storeid . "': target '$name' was reported created"
      . " as index $index but cannot be found in the target list\n" if !$t;
    die "storage '" . $self->_storeid . "': the NAS created target '$name' but"
      . " reports no IQN for it, so no node could log in to it\n"
        if !defined $t->{iqn};

    return $t;
}

sub activate {
    my ($self, $target) = @_;
    return $self->_edit_target($target, targetStatus => ACTIVATE,
        _what => "activating target '" . ($target->{name} // '?') . "'");
}

sub deactivate {
    my ($self, $target) = @_;
    return $self->_edit_target($target, targetStatus => DEACTIVATE,
        _what => "deactivating target '" . ($target->{name} // '?') . "'");
}

# QTS's `edit_target` takes the target's whole description rather than a delta,
# so everything is resent and only the named field changes. A partial edit is
# how a target silently loses its alias or its clustered access.
sub _edit_target {
    my ($self, $target, %change) = @_;

    my $what = delete $change{_what};

    my %p = (
        func                => 'edit_target',
        targetIndex         => $target->{index},
        targetName          => $target->{name},
        targetAlias         => ($target->{alias} // $target->{name}),
        targetStatus        => ACTIVATE,
        bTargetDataDigest   => ($target->{data_digest}   // 0),
        bTargetHeaderDigest => ($target->{header_digest} // 0),
        # Note 2. It cannot be read back, so it is asserted rather than
        # preserved: every edit this plugin makes reaffirms that its own target
        # admits more than one node.
        bTargetClusterEnable => 1,
        %change,
    );
    delete $p{$_} for grep { !defined $p{$_} } keys %p;

    $self->api->call_id(CGI_TARGET, %p,
        _what => ($what // "editing target $target->{index}"));
    return 1;
}

# Re-assert everything about a target that this plugin owns but cannot read
# back. Called from the storage's add and update hooks — an operator-initiated
# path, where a write per target is the right trade — and never from the
# activation path.
sub push_settings {
    my ($self, $target, %opt) = @_;
    $self->_edit_target($target,
        _what => "re-applying clustered access to target '"
               . ($target->{name} // '?') . "'");
    $self->_write_acl($target->{index}, %opt);
    return 1;
}

# ---------------------------------------------------------------------------
# CHAP
# ---------------------------------------------------------------------------

# Note 3: this writes the Default Policy row, because that is the only row the
# API can address.
sub _write_acl {
    my ($self, $index, %opt) = @_;

    my $user = $opt{chap_user};
    my $on   = (defined $user && length $user) ? 1 : 0;

    # There is no safe default for a shared secret. `// ''` here would turn a
    # missing password into an EMPTY CHAP secret — access control that appears
    # configured and protects nothing, which is strictly worse than none because
    # nobody goes looking for it.
    die "storage '" . $self->_storeid . "': qnap-chap-username is set but there"
      . " is no CHAP secret. Set qnap-chap-password, or unset the username: a"
      . " target with an empty secret accepts anyone while reporting that CHAP"
      . " is on.\n"
        if $on && (!defined $opt{chap_password} || !length $opt{chap_password});

    my $mon = (defined $opt{mutual_chap_user} && length $opt{mutual_chap_user}) ? 1 : 0;
    die "storage '" . $self->_storeid . "': a mutual CHAP username is set with"
      . " no secret.\n"
        if $mon && (!defined $opt{mutual_chap_password} || !length $opt{mutual_chap_password});
    die "storage '" . $self->_storeid . "': mutual CHAP requires one-way CHAP"
      . " as well. Set qnap-chap-username and qnap-chap-password too.\n"
        if $mon && !$on;

    my %p = (
        targetIndex        => $index,
        initiatorIndex     => DEFAULT_INITIATOR_INDEX,
        bCHAPEnable        => $on,
        CHAPUserName       => ($on ? $opt{chap_user} : ''),
        CHAPPasswd         => ($on ? $opt{chap_password} : ''),
        bMutualCHAPEnable  => $mon,
        mutualCHAPUserName => ($mon ? $opt{mutual_chap_user} : ''),
        mutualCHAPPasswd   => ($mon ? $opt{mutual_chap_password} : ''),
        # A credential. POST only, never the GET fallback — see API::call.
        _secret            => 1,
    );

    # `add_init` creates the row; `edit_init` changes it. `add_init` is tried
    # first and `edit_init` is the fallback rather than the other way round.
    my $r = $self->api->call(CGI_TARGET, func => 'add_init', %p);
    return 1 if !$r->{transport} && defined $r->{result}
             && $r->{result} =~ /\A\d+\z/ && $r->{result} == 0;

    $self->api->call_ok(CGI_TARGET, func => 'edit_init', %p,
        _what => ($on ? "setting CHAP on target $index"
                      : "clearing CHAP on target $index"));
    return 1;
}

# CHAP on a target that already exists.
#
# Two things this must NOT do:
#
#   * Send a write on every call. This runs on the activation path, so it
#     compares first — `bCHAPEnable` comes back in `targetInfo` — and only
#     writes when the array disagrees.
#   * Decide anything from the secret. The NAS does not return it, so a CHANGED
#     password is invisible here. The plugin's update hook pushes it
#     unconditionally, which is the one moment a new secret is known; this
#     reconciles the part the array will actually report.
sub reconcile_chap {
    my ($self, $target, %opt) = @_;
    return if ref $target ne 'HASH';

    my $want_user = $opt{chap_user};
    my $want_on   = (defined $want_user && length $want_user) ? 1 : 0;

    die "storage '" . $self->_storeid . "': qnap-chap-username is set but there"
      . " is no CHAP secret. Set qnap-chap-password, or unset the username: a"
      . " target with an empty secret accepts anyone while reporting that CHAP"
      . " is on.\n"
        if $want_on && (!defined $opt{chap_password} || !length $opt{chap_password});

    my $info = eval { $self->info($target->{index}) };
    # Could not ask. Do NOT write speculatively: this is the hot path, and a
    # write per VM start to correct something nobody has established is wrong is
    # exactly what this comparison exists to avoid.
    return if !$info;

    my ($acl) = grep { ($_->{index} // '') eq "" . DEFAULT_INITIATOR_INDEX }
                     @{ $info->{initiators} // [] };
    my $have_on = ($acl && ($acl->{chap} // 0)) ? 1 : 0;

    return if $have_on == $want_on;

    # Turning access control OFF is never silent even though it is what the
    # operator asked for. Leaving it on would be worse: the target would demand
    # a secret the node no longer sends, and every login would fail.
    warn "storage '" . $self->_storeid . "': removing CHAP from target"
       . " '" . ($target->{name} // '?') . "' because qnap-chap-username is no"
       . " longer set.\n" if $have_on && !$want_on;

    $self->_write_acl($target->{index}, %opt);
    return;
}

# ---------------------------------------------------------------------------
# Removing
# ---------------------------------------------------------------------------

sub delete {
    my ($self, $index) = @_;

    my $r = $self->api->call(CGI_TARGET,
        func => 'remove_target', targetIndex => $index);

    # `remove_target` answers with the target index, so a non-negative result is
    # success — note 4. Absence is confirmed by a listing either way, because a
    # listing is the only thing that proves it.
    my $gone = !defined $self->find_by_name_index($index);
    return 1 if $gone;

    die "storage '" . $self->_storeid . "': could not remove iSCSI target"
      . " $index: "
      . ($r->{transport}
         // PVE::Storage::Custom::QNAP::API::error_text($r->{result})) . "\n";
}

sub find_by_name_index {
    my ($self, $index) = @_;
    return undef if !defined $index;
    my ($t) = grep { ($_->{index} // '') eq "$index" } @{ $self->list };
    return $t;
}

1;
