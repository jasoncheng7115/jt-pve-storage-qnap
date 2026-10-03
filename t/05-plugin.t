#!/usr/bin/perl
# The plugin's own contract with Proxmox VE: names, features, options.
#
# Everything here is pure — no NAS, no devices. What it protects is the set of
# answers PVE acts on before it calls anything else.

use strict;
use warnings;
use Test::More;
use File::Temp;

BEGIN {
    eval { require PVE::Storage::Plugin; 1 }
        or plan skip_all => 'Proxmox VE is not installed on this machine';
}

plan tests => 70;

use PVE::Storage;
use PVE::Storage::Custom::QNAPSANPlugin;
my $P = 'PVE::Storage::Custom::QNAPSANPlugin';

is($P->type, 'qnapsan', 'the storage type');

# ---------------------------------------------------------------------------
# The API version is NEGOTIATED, never hardcoded
# ---------------------------------------------------------------------------
#
# The two directions are not symmetric. Claiming HIGHER than the node's APIVER
# makes PVE reject the plugin outright and every storage of this type disappears
# from the node; claiming lower but in range only warns. PVE 9 raised APIVER
# twice inside its 9.1 point releases, so a fixed number is wrong somewhere by
# construction.
my $api = $P->api;
cmp_ok($api, '>=', $P->APIVERSION_MIN, 'the negotiated version is not below the floor');
cmp_ok($api, '<=', $P->APIVERSION_MAX, 'and not above what is implemented');
cmp_ok($api, '<=', PVE::Storage::APIVER(), "and never above the node's own");

# ---------------------------------------------------------------------------
# parse_volname
# ---------------------------------------------------------------------------
#
# Element 1 is the LEAF, so a linked clone reports vm-101-disk-0 and not
# base-100-disk-0/vm-101-disk-0 — which is what RBDPlugin does, and what
# storage_migrate builds a target volume name out of.
my @r = $P->parse_volname('vm-100-disk-0');
is($r[0], 'images', 'an ordinary disk is an image');
is($r[1], 'vm-100-disk-0', 'the leaf');
is($r[2], '100', 'the owning vmid');
is($r[5], 0, 'not a base');

@r = $P->parse_volname('base-100-disk-0');
is($r[5], 1, 'a template is a base');

@r = $P->parse_volname('base-100-disk-0/vm-101-disk-0');
is($r[1], 'vm-101-disk-0', 'a linked clone reports its LEAF');
is($r[2], '101', 'and is owned by the clone, not the template');
is($r[3], 'base-100-disk-0', 'with the template recorded beside it');
is($r[5], 0, 'a linked clone is not itself a base');

eval { $P->parse_volname('nonsense') };
like($@, qr/unable to parse/, 'a name that is not a volume is refused');

# ---------------------------------------------------------------------------
# volume_has_feature
# ---------------------------------------------------------------------------
#
# Nothing here decides base vs current by looking at the volname STRING:
# `base-100-disk-0/vm-101-disk-0` starts with `base-` and is a linked clone.
my $scfg = {};
ok($P->volume_has_feature($scfg, 'snapshot', 's', 'vm-100-disk-0'),
   'a disk can be snapshotted');
ok($P->volume_has_feature($scfg, 'snapshot', 's', 'base-1-disk-0/vm-2-disk-0'),
   'and so can a LINKED CLONE, whose name begins with base-');
ok($P->volume_has_feature($scfg, 'rename', 's', 'base-1-disk-0/vm-2-disk-0'),
   'a linked clone can be renamed too');

# A CLONE IS OFFERED ON QuTS HERO ONLY, and only where that is KNOWN.
#
# On QTS the call copies the whole disk and PVE aborts it after 60 seconds. The
# kind of NAS is kept on file per node; with nothing on file and no NAS to ask,
# the answer is "not offered", never a guess.
{
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    local $PVE::Storage::Custom::QNAPSANPlugin::STATE_DIR = $dir;
    # No NAS behind these tests: asking one fails, as it would for a NAS that
    # is down.
    no warnings 'redefine';
    local *PVE::Storage::Custom::QNAPSANPlugin::_api = sub { die "no NAS\n" };
    my $kind = sub {
        open(my $fh, '>', "$dir/s.nas") or die $!; print $fh "$_[0]\n"; close($fh);
    };

    is($P->_nas_is_zfs('s', $scfg), undef,
       'with nothing on file and no NAS to ask, the kind is unknown');
    ok(!$P->volume_has_feature($scfg, 'clone', 's', 'base-100-disk-0'),
       'and a clone is NOT offered on an unknown NAS');

    $kind->('zfs');
    is($P->_nas_is_zfs('s', $scfg), 1, 'QuTS hero on file is read as QuTS hero');
    ok($P->volume_has_feature($scfg, 'clone', 's', 'base-100-disk-0'),
       'QuTS hero: a template can be cloned');
    ok($P->volume_has_feature($scfg, 'clone', 's', 'vm-100-disk-0', 'snap1'),
       'QuTS hero: and so can a snapshot');
    ok($P->volume_has_feature($scfg, 'clone', 's', 'vm-100-disk-0'),
       'QuTS hero: and the current state');

    $kind->('lvm');
    is($P->_nas_is_zfs('s', $scfg), 0, 'QTS on file is read as QTS');
    ok(!$P->volume_has_feature($scfg, 'clone', 's', 'base-100-disk-0'),
       'QTS: a template is NOT offered as a linked clone');
    ok(!$P->volume_has_feature($scfg, 'clone', 's', 'vm-100-disk-0', 'snap1'),
       'QTS: nor is a clone from a snapshot');
    ok(!$P->volume_has_feature($scfg, 'clone', 's', 'vm-100-disk-0'),
       'QTS: nor of the current state');
    ok($P->volume_has_feature($scfg, 'snapshot', 's', 'vm-100-disk-0'),
       'QTS: snapshots are still offered');
    ok($P->volume_has_feature($scfg, 'copy', 's', 'base-100-disk-0'),
       'QTS: and a template can still be FULLY cloned, which PVE does itself');
    ok($P->volume_has_feature($scfg, 'template', 's', 'vm-100-disk-0'),
       'QTS: a disk can still become a template');

    # QuTS hero h6: disks only, until the rest is measured there.
    $kind->('zfs6');
    is($P->_nas_kind('s', $scfg), 'zfs6', 'QuTS hero h6 on file is read as h6');
    ok(!$P->volume_has_feature($scfg, 'snapshot', 's', 'vm-100-disk-0')
       && !$P->volume_has_feature($scfg, 'template', 's', 'vm-100-disk-0')
       && !$P->volume_has_feature($scfg, 'rename', 's', 'vm-100-disk-0')
       && !$P->volume_has_feature($scfg, 'clone', 's', 'vm-100-disk-0'),
       'h6: no snapshot, template, rename or clone is offered');
    ok($P->volume_has_feature($scfg, 'copy', 's', 'vm-100-disk-0'),
       'h6: a full clone is, because PVE copies it itself');

    $kind->('lvm');
    # Stale, and the NAS cannot be asked: yesterday's answer stands.
    my $old = time - 2 * 86400;
    utime($old, $old, "$dir/s.nas");
    is($P->_nas_is_zfs('s', $scfg), 0,
       'a stale record is still used when the NAS cannot be asked');

    $kind->('nonsense');
    is($P->_nas_is_zfs('s', $scfg), undef,
       'a record that says neither is not read as either');
}
ok($P->volume_has_feature($scfg, 'template', 's', 'vm-100-disk-0'),
   'a disk can become a template');

# NO `copy` AT A SNAPSHOT, and that is a correction rather than an omission.
#
# `copy` means PVE reads the source data ITSELF, through
# `path($scfg, $volname, $storeid, $snapname)` — and that call dies, because a
# QNAP LUN has no device at a snapshot. Declaring it makes PVE start an
# operation and fail partway with a message about addressing; refusing makes it
# say "Full clone feature is not supported for a snapshot of ...", which an
# operator can act on.
ok(!$P->volume_has_feature($scfg, 'copy', 's', 'vm-100-disk-0', 'snap1'),
   'a full copy FROM a snapshot is refused up front');
ok($P->volume_has_feature($scfg, 'copy', 's', 'vm-100-disk-0'),
   'while a full copy of the current state is fine');

is($P->volume_has_feature($scfg, 'nonsense', 's', 'vm-100-disk-0'), undef,
   'an unknown feature is undef');
is($P->volume_has_feature($scfg, 'snapshot', 's', 'not-a-volume'), 0,
   'and an unparseable name is 0 rather than an exception');

# ---------------------------------------------------------------------------
# A snapshot has no device
# ---------------------------------------------------------------------------
eval { $P->path({}, 'vm-100-disk-0', 'store', 'snap1') };
like($@, qr/cannot be addressed at a snapshot/,
   'path() refuses a snapname loudly rather than handing back the current state');

# ---------------------------------------------------------------------------
# Options and secrets
# ---------------------------------------------------------------------------
my $data = $P->plugindata;

# WITHOUT THIS THE NAS PASSWORD IS WRITTEN INTO /etc/pve/storage.cfg, which is
# readable by www-data and returned by the API to any user with Datastore.Audit.
# `sensitive_properties` falls back to a hardcoded list that contains none of
# these names, so omitting one fails silently and in the least safe direction.
for my $secret (qw(qnap-password qnap-chap-password qnap-mutual-chap-password)) {
    ok($data->{'sensitive-properties'}{$secret},
       "$secret is declared sensitive, so PVE keeps it out of storage.cfg");
}

# OPTIONAL, and not a relaxation: `extract_sensitive_params` removes every
# sensitive property BEFORE `check_config` validates them, so a required
# password is already gone by the time PVE looks for it and `pvesm add` fails
# for a password that WAS supplied. on_add_hook refuses a missing one instead.
ok($P->options->{'qnap-password'}{optional},
   'the password is optional to PVE, and required by on_add_hook');

ok(grep({ $_ eq 'qnapsan' } @PVE::Storage::Plugin::SHARED_STORAGE),
   'the storage is registered as shared — a LUN on a NAS is reachable from'
 . ' every node by construction');

# ---------------------------------------------------------------------------
# Is something else already using this storage's names on the NAS?
# ---------------------------------------------------------------------------
#
# Two Proxmox VE clusters attached to one NAS and both calling a storage `qnap1`
# share every LUN name: each lists the other's disks, and deleting from one can
# delete from the other. The fold check reads the LOCAL storage.cfg and cannot
# see a second cluster, so the NAS is asked when the storage is added — the one
# moment the id is still free to change.
my @luns = map { { LUNName => $_ } } (
    'pve-qnap1-vm-100-disk-0',
    'pve-qnap1-base-200-disk-0',
    'pve-qnap10-vm-100-disk-0',     # ANOTHER storage whose id begins the same
    'pve-qnap1-something-else',     # the prefix, and not a PVE disk name
    'operator_lun',                        # the operator's own
);
my $w = $P->_existing_volumes_warning('qnap1', \@luns);
like($w, qr/already has 2 LUN\(s\)/,
   'disks under this storage\'s prefix are counted');
like($w, qr/pve-qnap1-base-200-disk-0, pve-qnap1-vm-100-disk-0/, 'and named');
unlike($w, qr/qnap10|operator_lun|something-else/,
   'a prefix identifies the STORAGE: qnap10 and the operator\'s own LUNs are'
 . ' not this storage\'s');
like($w, qr/added here before.*DIFFERENT Proxmox VE cluster/s,
   'both readings are spelled out, because only the operator can tell them apart');

is($P->_existing_volumes_warning('qnap1', [ { LUNName => 'operator_lun' } ]), undef,
   'a NAS with nothing of ours says nothing');
is($P->_existing_volumes_warning('qnap1', []), undef, 'nor does an empty one');
# "Could not ask" must not become "somebody else's disks are there".
is($P->_existing_volumes_warning('qnap1', undef), undef,
   'and a listing that could not be read is silence, not a warning');

# ---------------------------------------------------------------------------
# A CHAP secret that is not on disk yet still reaches the target
# ---------------------------------------------------------------------------
#
# on_add_hook writes the credential store LAST, after every check that could
# refuse the storage. So while it creates the target, the secret the operator
# just typed exists only in the hook's arguments — and reading the store found
# nothing, which the "username with no secret" guard then refused. Every
# `pvesm add` that set CHAP failed. Found by driving the hook against a fake
# NAS; nothing here reached it before.
{
    package FakeTarget;
    sub new { return bless {}, shift }
    sub ensure { my ($self, %o) = @_; return \%o }
}
{
    require File::Temp;
    no warnings 'redefine';
    local *PVE::Storage::Custom::QNAPSANPlugin::_tgt = sub { FakeTarget->new };
    # An empty store, which is what a storage being added for the first time has.
    local $PVE::Storage::Custom::QNAPSANPlugin::CRED_DIR = File::Temp::tempdir(CLEANUP => 1);
    my $cfg = { 'qnap-chap-username' => 'pve' };

    my $got = $P->_ensure_target(undef, 'qnap1', $cfg, undef, { 'chap-password' => 'typed-just-now' });
    is($got->{chap_password}, 'typed-just-now',
       'the secret handed to the hook is the one the target is created with');
    is($got->{chap_user}, 'pve', 'beside the username from the configuration');

    $got = $P->_ensure_target(undef, 'qnap1', $cfg, undef);
    is($got->{chap_password}, undef,
       'without it the store is read, and before the first add the store is empty');
}

# ---------------------------------------------------------------------------
# One rollback or clone at a time: the claim
# ---------------------------------------------------------------------------
#
# The cluster storage lock is held only to look for a claim and write one. PVE
# aborts whatever runs under that lock after 60 seconds, and a rollback on QTS
# takes as long as writing the disk back.
{
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    local $PVE::Storage::Custom::QNAPSANPlugin::FORK_DIR = $dir;
    no warnings qw(redefine once);
    my $locked = 0;
    local *PVE::Storage::Custom::QNAPSANPlugin::cluster_lock_storage = sub {
        my ($class, $storeid, $shared, $timeout, $code) = @_;
        $locked++;
        return $code->();
    };
    my $f = $P->_fork_file('s');

    is($P->_fork_busy('s'), undef, 'no claim, nothing running');
    ok($P->_fork_claim('s', {}, "rolling 'vm-1-disk-0' back to 'a'"), 'a claim is taken');
    ok(-f $f && $locked == 1, 'it is a file, written under the storage lock');
    like($P->_fork_busy('s')->{text}, qr/rolling 'vm-1-disk-0' back to 'a', started on node \S+ at /,
         'and it says what is running, where and since when');

    eval { $P->_fork_claim('s', {}, "rolling 'vm-2-disk-0' back to 'b'") };
    like($@, qr/cannot start, because this plugin runs one rollback or clone on a NAS at a time/,
         'a second one is refused while the first is running');
    like($@, qr/remove \Q$f\E/, 'and the refusal names the file');

    $P->_fork_release('s');
    ok(!-e $f, 'the claim is removed when the work returns');

    # Somebody else's claim is not ours to remove.
    open(my $fh, '>', $f) or die $!;
    print $fh "node=othernode\npid=1\ntime=" . time . "\nwhat=rolling back\n"; close($fh);
    $P->_fork_release('s');
    ok(-e $f, 'a claim written by another node is left alone');

    # Abandoned: ignored once it is older than any rollback is waited for.
    open($fh, '>', $f) or die $!;
    print $fh "node=othernode\npid=1\ntime=" . (time - 7200) . "\nwhat=rolling back\n"; close($fh);
    my @w; { local $SIG{__WARN__} = sub { push @w, @_ }; is($P->_fork_busy('s'), undef,
        'a claim older than the longest rollback is ignored'); }
    like($w[0] // '', qr/ignoring a claim left by node othernode 120 minutes ago/, 'with a warning');

    # Unreadable: not read as free.
    open($fh, '>', $f) or die $!; print $fh "garbage\n"; close($fh);
    like(($P->_fork_busy('s') // {})->{text} // '', qr/cannot be read/,
         'a claim that cannot be read still refuses');
    unlink $f;

    # A rollback holds the claim for exactly as long as the NAS may be working.
    my $outcome;
    local *PVE::Storage::Custom::QNAPSANPlugin::_do_rollback = sub {
        die "no claim while the rollback runs\n" if !-e $f;
        die $outcome if defined $outcome;
        return 1;
    };
    ok($P->volume_snapshot_rollback({}, 's', 'vm-1-disk-0', 'a') && !-e $f,
       'a rollback that succeeded leaves no claim');
    $outcome = "storage 's': rolling back failed: -1\n";
    eval { $P->volume_snapshot_rollback({}, 's', 'vm-1-disk-0', 'a') };
    ok($@ eq $outcome && !-e $f, 'nor does one the NAS refused');
    $outcome = "storage 's': it has been running for 1800s. It has NOT failed: check the NAS.\n";
    eval { $P->volume_snapshot_rollback({}, 's', 'vm-1-disk-0', 'a') };
    ok($@ eq $outcome && -e $f,
       'one the NAS has not finished KEEPS its claim: the NAS is still working');
    unlink $f;
}
