#!/usr/bin/perl
# Names and the ownership gate.
#
# The gate is the one thing in this plugin that, wrong in the permissive
# direction, destroys someone else's data. Everything here is about the boundary
# between "this storage's object" and "somebody else's".

use strict;
use warnings;
use Test::More tests => 53;

use PVE::Storage::Custom::QNAP::Naming;
my $N = 'PVE::Storage::Custom::QNAP::Naming';

# ---------------------------------------------------------------------------
# These are functions, not methods
# ---------------------------------------------------------------------------
#
# Called as a method the arguments shift by one and the gate answers "not
# owned" for an object that IS owned — safe, but silently wrong, and a listing
# would come back empty with no error to explain it.
eval { $N->is_pve_managed_volume('pve-x-vm-100-disk-0', 'x') };
like($@, qr/functions, not methods/, 'a method call on the gate dies loudly');

# ---------------------------------------------------------------------------
# fold_storeid
# ---------------------------------------------------------------------------

is(PVE::Storage::Custom::QNAP::Naming::fold_storeid('qnap1'), 'qnap1',
   'an ordinary storage id survives unchanged');

# THE DIFFERENCE FROM THE SYNOLOGY PLUGIN. An underscore is legal in a QTS LUN
# name and does NOT have to be folded —
# which removes that project's worst structural hazard, where `a_b` and `a-b`
# became the same prefix.
is(PVE::Storage::Custom::QNAP::Naming::fold_storeid('qnap_1'), 'qnap_1',
   'an underscore survives the fold, because QTS accepts one');
isnt(PVE::Storage::Custom::QNAP::Naming::fold_storeid('qnap_1'),
     PVE::Storage::Custom::QNAP::Naming::fold_storeid('qnap-1'),
     '_ and - therefore stay distinguishable');

is(PVE::Storage::Custom::QNAP::Naming::fold_storeid('QNAP1'), 'qnap1',
   'case is folded');
is(PVE::Storage::Custom::QNAP::Naming::fold_storeid('a b/c'), 'a-b-c',
   'illegal characters become a hyphen');
is(PVE::Storage::Custom::QNAP::Naming::fold_storeid('a///b'), 'a-b',
   'a run of illegal characters is one hyphen');
is(PVE::Storage::Custom::QNAP::Naming::fold_storeid('---a---'), 'a',
   'leading and trailing separators go');
is(length(PVE::Storage::Custom::QNAP::Naming::fold_storeid('x' x 100)),
   PVE::Storage::Custom::QNAP::Naming::MAX_STOREID_FOLD,
   'a long storage id is truncated');
unlike(PVE::Storage::Custom::QNAP::Naming::fold_storeid('a' x 15 . '-b'), qr/-\z/,
   'truncation never leaves a trailing hyphen');

# ---------------------------------------------------------------------------
# Collisions
# ---------------------------------------------------------------------------
#
# Rarer than on Synology now that `_` survives, but NOT impossible: the fold
# still lower-cases and truncates.
ok(PVE::Storage::Custom::QNAP::Naming::fold_collides_with('Qnap1', 'qnap1'),
   'two ids differing only in case collide');
ok(PVE::Storage::Custom::QNAP::Naming::fold_collides_with(
       'a' x 16 . '1', 'a' x 16 . '2'),
   'two ids differing only past the truncation point collide');
ok(!PVE::Storage::Custom::QNAP::Naming::fold_collides_with('qnap1', 'qnap2'),
   'ordinary distinct ids do not collide');
ok(!PVE::Storage::Custom::QNAP::Naming::fold_collides_with('qnap1', 'qnap1'),
   'a storage does not collide with itself');

# ---------------------------------------------------------------------------
# Every volume name Proxmox VE constructs
# ---------------------------------------------------------------------------
#
# Read out of PVE rather than guessed. A pattern ending in `\w*` covers neither
# a hyphen nor three of these forms, and the cost is a snapshot with a hyphen in
# its name being refused as "not a Proxmox VE disk name".
for my $good (qw(
    vm-100-disk-0 base-100-disk-0 vm-100-disk-11
    vm-100-cloudinit vm-100-efi-enroll vm-100-fleece-0 vm-100-tpmstate0
    vm-146-state-open-ap vm-146-state-open_ap
)) {
    ok(PVE::Storage::Custom::QNAP::Naming::is_pve_disk_name($good),
       "'$good' is a Proxmox VE disk name");
}

for my $bad ('', 'random', 'vm-100', 'disk-0', 'vm-abc-disk-0',
             "vm-100-disk-0\n") {
    ok(!PVE::Storage::Custom::QNAP::Naming::is_pve_disk_name($bad),
       "'" . ($bad =~ s/\n/\\n/r) . "' is not");
}

# ---------------------------------------------------------------------------
# leaf_of
# ---------------------------------------------------------------------------

is(PVE::Storage::Custom::QNAP::Naming::leaf_of('base-100-disk-0/vm-101-disk-0'),
   'vm-101-disk-0', 'a linked clone resolves to its leaf');
is(PVE::Storage::Custom::QNAP::Naming::leaf_of('vm-101-disk-0'),
   'vm-101-disk-0', 'a plain name is its own leaf');

# ---------------------------------------------------------------------------
# lun_name and the ownership gate
# ---------------------------------------------------------------------------

is(PVE::Storage::Custom::QNAP::Naming::lun_name('qnap1', 'vm-100-disk-0'),
   'pve-qnap1-vm-100-disk-0', 'a LUN name is prefix + leaf');
is(PVE::Storage::Custom::QNAP::Naming::lun_name('qnap1', 'base-1-disk-0/vm-2-disk-0'),
   'pve-qnap1-vm-2-disk-0', 'a linked clone is named after its leaf');

eval { PVE::Storage::Custom::QNAP::Naming::lun_name('qnap1', 'nonsense') };
like($@, qr/not a Proxmox VE disk name/,
     'a name PVE never generates is refused before it reaches the NAS');

ok(PVE::Storage::Custom::QNAP::Naming::is_pve_managed_volume(
       'pve-qnap1-vm-100-disk-0', 'qnap1'), 'the gate passes our own disk');

# THE GATE TAKES THE STORAGE ID, not merely a shape. A prefix identifies the
# STORAGE, never the kind of object.
ok(!PVE::Storage::Custom::QNAP::Naming::is_pve_managed_volume(
       'pve-qnap2-vm-100-disk-0', 'qnap1'),
   "the gate refuses another storage's disk");
ok(!PVE::Storage::Custom::QNAP::Naming::is_pve_managed_volume(
       'operator_lun', 'qnap1'), "the gate refuses an operator's own LUN");
ok(!PVE::Storage::Custom::QNAP::Naming::is_pve_managed_volume(
       'pve-qnap1-something-else', 'qnap1'),
   'the prefix alone is not enough — the remainder must be a PVE disk name');
ok(!PVE::Storage::Custom::QNAP::Naming::is_pve_managed_volume(
       'pve-qnap1-tgt', 'qnap1'),
   "the storage's own target name does not pass the LUN gate");

is(PVE::Storage::Custom::QNAP::Naming::volname_from_lun_name(
       'pve-qnap1-vm-100-disk-0', 'qnap1'), 'vm-100-disk-0',
   'a LUN name maps back to a volume name');
is(PVE::Storage::Custom::QNAP::Naming::volname_from_lun_name(
       'pve-qnap2-vm-100-disk-0', 'qnap1'), undef,
   "another storage's LUN maps back to nothing, so a listing filters it out");

# ---------------------------------------------------------------------------
# What may be sent to QTS
# ---------------------------------------------------------------------------

eval { PVE::Storage::Custom::QNAP::Naming::assert_qts_legal('has space') };
like($@, qr/contains ' '/, 'an illegal character is named in the refusal');
eval { PVE::Storage::Custom::QNAP::Naming::assert_qts_legal('x' x 200) };
like($@, qr/longer than/, 'an over-long name is refused with its length');
is(PVE::Storage::Custom::QNAP::Naming::assert_qts_legal('pve-a_b.c-1'),
   'pve-a_b.c-1', 'letters, digits, - . and _ pass');

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------
#
# A target name becomes part of an IQN, whose grammar is much narrower than a
# LUN name's — QTS concatenates its own prefix and postfix around it.
is(PVE::Storage::Custom::QNAP::Naming::target_name('qnap_1'), 'pve-qnap-1-tgt',
   'an underscore is NOT legal in a target name, because it becomes an IQN');
like(PVE::Storage::Custom::QNAP::Naming::target_name('qnap1', 'vm-100-disk-0'),
     qr/\Apve-qnap1-tgt-vm-100-disk-0\z/, 'per-volume mode names the disk');
unlike(PVE::Storage::Custom::QNAP::Naming::target_name('QNAP1'), qr/[A-Z]/,
     'a target name is lower case, as an IQN must be');

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------
#
# A QTS LUN snapshot carries no record of who took it, so ownership lives
# entirely in the name. This is the only thing standing between `qm destroy` and
# an operator's own scheduled snapshot of the same LUN.
is(PVE::Storage::Custom::QNAP::Naming::snapshot_name('before-upgrade'),
   'pve-before-upgrade', 'a snapshot is named with the plugin prefix');
is(PVE::Storage::Custom::QNAP::Naming::snapname_from_snapshot_name('pve-before-upgrade'),
   'before-upgrade', 'and maps back');
is(PVE::Storage::Custom::QNAP::Naming::snapname_from_snapshot_name('nightly-0300'),
   undef, "an operator's own snapshot is invisible to PVE, so PVE cannot delete it");

# A temporary snapshot is scaffolding — `clone_image` and `create_base` leave
# one behind. It must not be reported to PVE as a restore point: it would appear
# in the GUI as something to roll back to, and deleting it would break the
# linked clone that depends on it.
my $tmp = PVE::Storage::Custom::QNAP::Naming::temp_snapshot_name('base', 7);
ok(PVE::Storage::Custom::QNAP::Naming::is_temp_snapshot_name($tmp),
   'a temp snapshot is recognisable as one');
is(PVE::Storage::Custom::QNAP::Naming::snapname_from_snapshot_name($tmp), undef,
   'and is never reported to PVE as a snapshot of the disk');

eval { PVE::Storage::Custom::QNAP::Naming::snapshot_name('x' x 41) };
like($@, qr/longer than 40/, "PVE's own 40-character limit is respected");
