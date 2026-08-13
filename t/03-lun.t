#!/usr/bin/perl
# LUN arithmetic and identity.
#
# Two things here decide whether the plugin works at all: the GiB rounding,
# because QTS cannot allocate anything finer, and the WWID, because it is the
# only thing that connects a LUN on the NAS to a block device on a node.

use strict;
use warnings;
use Test::More tests => 27;

use PVE::Storage::Custom::QNAP::LUN;
my $L = 'PVE::Storage::Custom::QNAP::LUN';
my $GIB = 1024 * 1024 * 1024;

# ---------------------------------------------------------------------------
# QTS ALLOCATES IN WHOLE GiB
# ---------------------------------------------------------------------------
#
# `add_lun` takes a whole number, and one unit of it is 2^30 bytes — a GiB.
# Proxmox VE allocates in KiB, so every size rounds UP.
#
# Never down, and never to zero. A volume smaller than the one PVE believes it
# created gets filled and then fails; a zero-byte LUN is not a thing QTS makes.
is(PVE::Storage::Custom::QNAP::LUN::bytes_to_gib_up($GIB), 1,
   'exactly one GiB is one GiB');
is(PVE::Storage::Custom::QNAP::LUN::bytes_to_gib_up($GIB + 1), 2,
   'one byte over rounds up to two');
is(PVE::Storage::Custom::QNAP::LUN::bytes_to_gib_up($GIB - 1), 1,
   'one byte under still needs a whole GiB');
is(PVE::Storage::Custom::QNAP::LUN::bytes_to_gib_up(1), 1,
   'a single byte becomes the minimum QTS can make');
is(PVE::Storage::Custom::QNAP::LUN::bytes_to_gib_up(0), 1,
   'and so does zero — a zero-byte LUN is not a thing');
is(PVE::Storage::Custom::QNAP::LUN::bytes_to_gib_up(undef), 1,
   'an undefined size does not silently become nothing');
is(PVE::Storage::Custom::QNAP::LUN::bytes_to_gib_up(-5), 1,
   'nor does a negative one');
is(PVE::Storage::Custom::QNAP::LUN::bytes_to_gib_up(32 * $GIB), 32,
   'a round figure stays round');
# 8 GiB + 1 MiB, which is what `qm resize +1M` on an 8 GiB disk produces.
is(PVE::Storage::Custom::QNAP::LUN::bytes_to_gib_up(8 * $GIB + 1024 * 1024), 9,
   'a one-megabyte grow costs a whole GiB, because QTS has no finer step');

# THE SMALLEST VOLUMES PROXMOX VE ASKS FOR, read out of PVE rather than
# remembered: an EFI disk is 540672 bytes, a TPM state and a cloud-init drive
# are 4 MiB each. A granularity and a minimum are two constraints — the related
# Dell plugin rounded a 540672-byte EFI disk to its array's granularity, got the
# same number back, and had the create refused for being under the minimum. Here
# the floor and the rounding are one step, and this is what says so.
is(PVE::Storage::Custom::QNAP::LUN::bytes_to_gib_up(540672), 1,
   'an EFI disk becomes one GiB');
is(PVE::Storage::Custom::QNAP::LUN::bytes_to_gib_up(4 * 1024 * 1024), 1,
   'and so do a TPM state and a cloud-init drive');
cmp_ok(PVE::Storage::Custom::QNAP::LUN::bytes_to_gib_up(540672) * $GIB, '>=', 540672,
   'which is never smaller than what PVE asked for');

# ---------------------------------------------------------------------------
# THE WWID
# ---------------------------------------------------------------------------
#
# `LUNNAA` is the 32 hex digits of an NAA IEEE Registered Extended identifier.
# multipath's name for the same thing is that string with a leading `3` — the
# NAA designator type — and the kernel independently reports `naa.<same digits>`
# in /sys/block/<sd>/device/wwid, which is what device_is_lun compares against.
#
# The value below is made up; any 32 hex digits beginning with 6 would do.
is(PVE::Storage::Custom::QNAP::LUN::wwid_for_naa('60123456789abcdef0123456789abcde'),
   '360123456789abcdef0123456789abcde',
   "a LUNNAA becomes a multipath WWID");
is(PVE::Storage::Custom::QNAP::LUN::wwid_for_naa('60123456789ABCDEF0123456789ABCDE'),
   '360123456789abcdef0123456789abcde', 'case is normalised');
is(PVE::Storage::Custom::QNAP::LUN::wwid_for_naa('naa.60123456789abcdef0123456789abcde'),
   '360123456789abcdef0123456789abcde',
   "the kernel's own spelling is accepted too");

# A WWID that cannot be derived must be undef, never a guess: every destructive
# path in this plugin is gated on comparing one.
is(PVE::Storage::Custom::QNAP::LUN::wwid_for_naa(''), undef, 'empty is undef');
is(PVE::Storage::Custom::QNAP::LUN::wwid_for_naa(undef), undef, 'undef is undef');
is(PVE::Storage::Custom::QNAP::LUN::wwid_for_naa('not hex'), undef,
   'a value that is not hex is undef rather than a mangled string');
is(PVE::Storage::Custom::QNAP::LUN::wwid_for_naa('6e84'), undef,
   'and one that is far too short is refused');

# ---------------------------------------------------------------------------
# The fields, named once
# ---------------------------------------------------------------------------
my $row = {
    LUNIndex => '3', LUNName => 'pve-q1-vm-100-disk-0',
    LUNPath => 'pve-q1-vm-100-disk-0',
    capacity_bytes => '1073741824', LUNStatus => '2', LUNEnable => '1',
    LUNNAA => '60123456789abcdef0123456789abcde', LUNThinAllocate => '1',
    isRemoving => '0', bMap => '1', poolID => '1', VolumeBase => 'yes',
    _LUNTargetList => [],
};
my $lun = PVE::Storage::Custom::QNAP::LUN::_normalise($row);
is($lun->{index}, '3', 'index');
is($lun->{size}, 1073741824, 'size is a number, not the formatted string');
is(PVE::Storage::Custom::QNAP::LUN::wwid_of($lun),
   '360123456789abcdef0123456789abcde', 'and the WWID comes off it');

# ---------------------------------------------------------------------------
# LUNNumber is NOT LUNIndex
# ---------------------------------------------------------------------------
#
# `LUNIndex` identifies the LUN on the whole NAS; `LUNNumber` is its number
# WITHIN one target and is what appears in the by-path device name. Confusing
# them produces a path that either does not exist or belongs to a different
# disk — and QTS reuses the second one.
my $mapped = PVE::Storage::Custom::QNAP::LUN::_normalise({
    %$row,
    _LUNTargetList => [],
});
$mapped->{targets} = [ { target_index => '0', lun_number => '1', enabled => '1' } ];

is(PVE::Storage::Custom::QNAP::LUN::lun_number_on_target($mapped, 0), 1,
   'the number within the target is 1, while the LUN index is 3');
isnt(PVE::Storage::Custom::QNAP::LUN::lun_number_on_target($mapped, 0),
     $mapped->{index}, 'the two are genuinely different numbers');
is(PVE::Storage::Custom::QNAP::LUN::lun_number_on_target($mapped, 7), undef,
   'a target the LUN is not on has no number');
ok(PVE::Storage::Custom::QNAP::LUN::is_mapped_to($mapped, 0), 'mapped to 0');
ok(!PVE::Storage::Custom::QNAP::LUN::is_mapped_to($mapped, 7), 'not to 7');
