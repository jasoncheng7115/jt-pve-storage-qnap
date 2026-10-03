#!/usr/bin/perl
# LUN arithmetic and identity.
#
# Two things here decide whether the plugin works at all: the GiB rounding,
# because QTS cannot allocate anything finer, and the WWID, because it is the
# only thing that connects a LUN on the NAS to a block device on a node.

use strict;
use warnings;
use Test::More tests => 47;

use PVE::Storage::Custom::QNAP::LUN;
use JSON;
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

# ---------------------------------------------------------------------------
# QuTS hero h6: the writes go through the JSON interface, the reads do not
# ---------------------------------------------------------------------------
#
# Each request is checked for its shape, because the shape is the part that was
# measured on h6.0.1. And no CGI write may be sent on h6 at all: there the LUN
# CGI refuses everything.
{
    package FakeH6Api;
    sub new { my ($c, %o) = @_; return bless { rest => [], cgi => [], answers => [], %o }, $c }
    sub is_h6 { return $_[0]{h6} // 1 }
    sub storeid { return 's' }
    sub limits { return {} }
    sub rest {
        my ($self, $m, $path, $body) = @_;
        push @{ $self->{rest} }, [ $m, $path, $body ];
        my $a = shift @{ $self->{answers} };
        return $a // { error_code => 0 };
    }
    sub rest_ok {
        my ($self, $m, $path, $body, %o) = @_;
        my $r = $self->rest($m, $path, $body);
        die "$o{_what} failed: " . PVE::Storage::Custom::QNAP::API::rest_error_text($r) . ".\n"
            if ($r->{error_code} // -1) != 0;
        return $r;
    }
    sub call    { push @{ $_[0]{cgi} }, $_[1]; return { result => 0 } }
    sub call_id { push @{ $_[0]{cgi} }, $_[1]; return 0 }
    sub call_ok { push @{ $_[0]{cgi} }, $_[1]; return { result => 0 } }
}
{
    no warnings 'redefine';
    my $api = FakeH6Api->new(answers => [
        { error_code => 0, single => { volume_id => 19 } },          # POST volumes
        { error_code => 0, single => { volume_id => 19 } },          # GET: no LUN yet
        { error_code => 0, single => { volume_id => 19, lun_index => 9 } },
    ]);
    my $lun = $L->new($api);
    local *PVE::Storage::Custom::QNAP::LUN::list = sub { [] };
    local *PVE::Storage::Custom::QNAP::LUN::wait_ready = sub {
        return { index => $_[1], name => 'pve-s-vm-100-disk-0', naa => '60123456789abcdef0123456789abcde' };
    };
    local *PVE::Storage::Custom::QNAP::LUN::assert_room_for_lun = sub { 1 };

    my $got = $lun->create(name => 'pve-s-vm-100-disk-0', size => $GIB + 1, pool_id => '1');
    my ($m, $path, $body) = @{ $api->{rest}[0] };
    is("$m $path", 'POST api/storage/v1/volumes', 'h6: a LUN is created as a volume');
    is($body->{capacity}, 2 * $GIB, 'in BYTES, still a whole number of GiB, rounded up');
    ok($body->{pool_id} == 1 && !ref $body->{pool_id} && $body->{pool_id} !~ /\D/,
       'the pool id is sent as a number');
    is_deeply([ @$body{qw(label provision_type type threshold)} ],
              [ 'pve-s-vm-100-disk-0', 'thin', 'zvol', 80 ],
              'with its label, thin, a zvol, and the usual threshold');
    ok(JSON::is_bool($body->{iscsi}{create_lun}) && $body->{iscsi}{create_lun},
       'and asks for its LUN as a JSON true, not a string');
    is(scalar(grep { $_->[1] eq 'api/storage/v1/volumes/19' } @{ $api->{rest} }), 2,
       'the volume is asked about until its LUN is there');
    is($got->{index}, 9, 'and the LUN it reports is the one handed back');
    is(scalar @{ $api->{cgi} }, 0, 'no CGI write was sent');

    # Created, but under another name: it would never be found again.
    $api = FakeH6Api->new(answers => [
        { error_code => 0, single => { volume_id => 20 } },
        { error_code => 0, single => { volume_id => 20, lun_index => 10 } },
    ]);
    local *PVE::Storage::Custom::QNAP::LUN::wait_ready = sub {
        return { index => $_[1], name => 'something-else', naa => '60123456789abcdef0123456789abcde' };
    };
    eval { $L->new($api)->create(name => 'pve-s-vm-100-disk-1', size => $GIB, pool_id => 1) };
    like($@, qr/created LUN 10 for 'pve-s-vm-100-disk-1' but calls it 'something-else'/,
         'a LUN the NAS named differently is refused, by index, so it can be removed');

    $api = FakeH6Api->new;
    eval { $L->new($api)->create(name => 'pve-s-vm-1-disk-0', size => $GIB, pool_id => 1, thin => 0) };
    like($@, qr/a thick LUN cannot be created on QuTS hero h6/, 'h6: a thick LUN is refused');
    eval { $L->new($api)->create(name => 'pve-s-vm-1-disk-0', size => $GIB, pool_id => 1, sector_size => 4096) };
    like($@, qr/sector size other than 512/, 'and so is a 4096-byte sector size');
    is(scalar @{ $api->{rest} }, 0, 'both before anything is sent');

    # Delete: the volume behind the LUN, found by its lun_index.
    my @present = (1);
    local *PVE::Storage::Custom::QNAP::LUN::get_by_index = sub { return shift @present ? { index => $_[1] } : undef };
    $api = FakeH6Api->new(answers => [
        { error_code => 0, collection => [ { volume_id => 3, lun_index => 2 }, { volume_id => 19, lun_index => 9 } ] },
        { error_code => 0 },
    ]);
    @present = ();
    ok($L->new($api)->delete(9), 'h6: a LUN is deleted');
    is(join(' | ', map { "$_->[0] $_->[1]" } @{ $api->{rest} }),
       'GET api/storage/v1/volumes | DELETE api/storage/v1/volumes/19',
       'by deleting the volume that claims it');

    $api = FakeH6Api->new(answers => [
        { error_code => 0, collection => [ { volume_id => 3, lun_index => 9 }, { volume_id => 19, lun_index => 9 } ] },
    ]);
    eval { $L->new($api)->delete(9) };
    like($@, qr/2 volumes on the NAS claim LUN 9\. Refusing to pick one/,
         'and two volumes claiming one LUN is refused, not guessed at');

    # Attach: two steps, in this order.
    $api = FakeH6Api->new;
    $L->new($api)->map_to_target(9, 4);
    is(join(' | ', map { "$_->[0] $_->[1]" } @{ $api->{rest} }),
       'POST api/iscsi/v1/targets/4/luns/9 | PUT api/iscsi/v1/targets/4/luns/9',
       'h6: a LUN is attached, then enabled');
    ok(JSON::is_bool($api->{rest}[1][2]{lun_enable}) && $api->{rest}[1][2]{lun_enable},
       'enabled with a JSON true');

    $api = FakeH6Api->new;
    $L->new($api)->unmap_from_target(9, 4);
    is("$api->{rest}[0][0] $api->{rest}[0][1]", 'DELETE api/iscsi/v1/targets/4/luns/9',
       'and detached with one request');

    # What has not been measured is refused, before anything is sent.
    $api = FakeH6Api->new;
    my $l = $L->new($api);
    my @refused = grep { !eval { $_->(); 1 } && $@ =~ /not available on QuTS hero h6/ } (
        sub { $l->resize({ index => 9 }, 2 * $GIB) },
        sub { $l->rename({ index => 9 }, 'x') },
        sub { $l->snapshot_create(lun_index => 9, name => 'x') },
        sub { $l->snapshot_rollback(lun_index => 9, snapshot_id => 1) },
        sub { $l->clone_from_snapshot(snapshot_id => 1, name => 'x') },
    );
    is(scalar @refused, 5, 'h6: growing, renaming, snapshots, rollback and clones are refused');
    ok(!@{ $api->{rest} } && !@{ $api->{cgi} } && !@{ $l->snapshot_list(9) },
       'without a request, and the plugin lists no snapshots of its own there');
}
