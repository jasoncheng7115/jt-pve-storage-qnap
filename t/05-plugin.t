#!/usr/bin/perl
# The plugin's own contract with Proxmox VE: names, features, options.
#
# Everything here is pure — no NAS, no devices. What it protects is the set of
# answers PVE acts on before it calls anything else.

use strict;
use warnings;
use Test::More;

BEGIN {
    eval { require PVE::Storage::Plugin; 1 }
        or plan skip_all => 'Proxmox VE is not installed on this machine';
}

plan tests => 40;

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

ok($P->volume_has_feature($scfg, 'clone', 's', 'base-100-disk-0'),
   'a template can be cloned');
ok($P->volume_has_feature($scfg, 'clone', 's', 'vm-100-disk-0', 'snap1'),
   'and so can a snapshot');
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
