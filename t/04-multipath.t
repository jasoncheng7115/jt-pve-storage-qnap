#!/usr/bin/perl
# The multipath drop-in and the three-valued safety contract.
#
# Nothing here touches a device. What it pins is the shape of the configuration
# this plugin writes to every node, and the rule that a check which cannot
# answer must not answer.

use strict;
use warnings;
use Test::More tests => 26;

use PVE::Storage::Custom::QNAP::Multipath;
my $MP = 'PVE::Storage::Custom::QNAP::Multipath';

# ---------------------------------------------------------------------------
# These are functions, not methods
# ---------------------------------------------------------------------------
#
# Called as a method the arguments shift by one and a caller's no_path_retry is
# silently ignored — which is exactly the value that must not be defaulted.
eval { $MP->conf_content(no_path_retry => 5) };
like($@, qr/functions, not methods/, 'a method call dies loudly');

# ---------------------------------------------------------------------------
# The drop-in
# ---------------------------------------------------------------------------
my $conf = PVE::Storage::Custom::QNAP::Multipath::conf_content();

# The DIRECTIVES only. The generated file's own comments explain why
# `no_path_retry "queue"` is not used, and a guard that reads prose as content
# would condemn the very sentence that documents the rule — the family's
# recurring "strip, scope, or anchor: never just grep the word".
my $directives = join("\n", grep { !/^\s*#/ } split /\n/, $conf);

# `no_path_retry queue` is what multipath's generic defaults give a QNAP LUN on
# a node with no entry for it, and with queueing on, losing every path is an
# unkillable hang rather than an I/O error. That is the whole reason this file
# is written at all.
like($conf, qr/no_path_retry\s+18/, 'no_path_retry has a numeric default');
unlike($directives, qr/no_path_retry\s+"?queue/,
   'and is NEVER queue — an unrecoverable hang is not a failure mode');
unlike($directives, qr/dev_loss_tmo\s+"?infinity/, 'dev_loss_tmo is never infinity');

my $custom = PVE::Storage::Custom::QNAP::Multipath::conf_content(no_path_retry => 42);
like($custom, qr/no_path_retry\s+42/, 'the option reaches the file');

like($conf, qr/vendor\s+"QNAP"/, 'the stanza is scoped to QNAP...');
# The product is matched with `.*` rather than a literal. A literal that is
# slightly wrong makes the whole stanza silently not apply, and the fallback is
# the generic default with `no_path_retry queue`.
like($conf, qr/product\s+"\.\*"/, '...and to every product of that vendor');

# multibus and `prio const`: a QNAP is a single-controller array and every
# portal reaches the same LUN through the same backend, so all paths are equal.
like($conf, qr/path_grouping_policy\s+multibus/, 'all paths carry I/O');
like($conf, qr/path_checker\s+tur/, 'TEST UNIT READY is the checker');

# ---------------------------------------------------------------------------
# The stable device path
# ---------------------------------------------------------------------------
#
# NOT /dev/mapper/<wwid>: on a node with `user_friendly_names yes` multipath
# names the map mpathX and that path does not exist at all. The dm-uuid link is
# always there, whatever naming policy the administrator chose.
is(PVE::Storage::Custom::QNAP::Multipath::dm_uuid_path('360123456789abcdef0123456789abcde'),
   '/dev/disk/by-id/dm-uuid-mpath-360123456789abcdef0123456789abcde',
   'the dm-uuid link is what a caller opens');
is(PVE::Storage::Custom::QNAP::Multipath::dm_uuid_path('360123456789ABCDEF0123456789ABCDE'),
   '/dev/disk/by-id/dm-uuid-mpath-360123456789abcdef0123456789abcde',
   'case is normalised, because udev creates the lower-case name');
is(PVE::Storage::Custom::QNAP::Multipath::dm_uuid_path('nonsense'), undef,
   'a WWID that is not one produces no path rather than a wrong one');
is(PVE::Storage::Custom::QNAP::Multipath::dm_uuid_path(undef), undef,
   'and undef produces none');

# ---------------------------------------------------------------------------
# THE THREE-VALUED CONTRACT
# ---------------------------------------------------------------------------
#
# 1 / 0 / **undef**, where undef means "could not establish". Two destructive
# paths ask these questions — a delete and a rollback — and for them "cannot
# tell" has to mean "do not". Reading an unknown as "free" is how a volume gets
# deleted underneath a running VM.
is(PVE::Storage::Custom::QNAP::Multipath::map_is_gone(undef), undef,
   'map_is_gone on an unusable WWID is undef, NOT "gone" — a delete path that'
 . ' read it as gone would conclude the device was cleaned up without looking');
is(PVE::Storage::Custom::QNAP::Multipath::map_is_gone('nonsense'), undef,
   'and the same for a malformed one');

is(PVE::Storage::Custom::QNAP::Multipath::device_is_lun('/dev/sdzz', undef), undef,
   'device_is_lun with no WWID to compare against cannot answer');

# A WWID nothing on this machine has. The map is genuinely absent, so this is a
# definite 1 rather than an undef — the distinction the reaper depends on.
is(PVE::Storage::Custom::QNAP::Multipath::map_is_gone('3' . '0' x 32), 1,
   'a WWID with no map is definitely gone');

is_deeply(PVE::Storage::Custom::QNAP::Multipath::slaves_of_map('3' . '0' x 32), [],
   'and has no slaves, as an empty list rather than undef');

# ---------------------------------------------------------------------------
# A path is claimed by the name multipathd knows it by
# ---------------------------------------------------------------------------
#
# activate_volume holds `/dev/sdb`, which is what a by-path link resolves to.
# claim_path once accepted only `sdb`, so those calls returned 0 without running
# anything and nothing reported it: the code read as though the path had been
# offered to multipathd, and it never was.
is(PVE::Storage::Custom::QNAP::Multipath::path_name('/dev/sdb'), 'sdb',
   'the form activate_volume actually holds is accepted');
is(PVE::Storage::Custom::QNAP::Multipath::path_name('sdb'), 'sdb',
   'and so is the bare name');
is(PVE::Storage::Custom::QNAP::Multipath::path_name('/dev/sdaa'), 'sdaa',
   'past sdz as well');
is(PVE::Storage::Custom::QNAP::Multipath::path_name(
       '/dev/disk/by-path/ip-192.0.2.10:3260-iscsi-iqn.2004-04.com.qnap:x-lun-1'),
   undef, 'a by-path link that was never resolved is not a path name');
is(PVE::Storage::Custom::QNAP::Multipath::path_name('/dev/dm-3'), undef,
   'a map is not one of its own paths');
is(PVE::Storage::Custom::QNAP::Multipath::path_name('sdb; reboot'), undef,
   'and nothing with a space or a semicolon reaches a command line');
is(PVE::Storage::Custom::QNAP::Multipath::path_name(undef), undef,
   'undef produces none');

# ---------------------------------------------------------------------------
# No node-wide flush, anywhere
# ---------------------------------------------------------------------------
#
# `multipath -F` is never generated: it flushes EVERY unused map on the node,
# including other vendors' storage and an operator's own hand-built maps. The
# build checks this too; it is here so that a bare `prove` run catches it.
my $src = do {
    open(my $fh, '<', 'lib/PVE/Storage/Custom/QNAP/Multipath.pm') or die $!;
    local $/; <$fh>;
};
my @bad = grep { /multipath\s+-[A-Za-z]*F\b|multipath\s+--flush/ && !/never|NEVER/ }
          split /\n/, $src;
is(scalar @bad, 0, 'no node-wide multipath flush is generated')
    or diag("offending lines:\n" . join("\n", @bad));
