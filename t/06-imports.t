#!/usr/bin/perl

# Every function each module calls must be one it can actually reach.
#
# `perl -c` compiles a call to an undefined subroutine without a word, so the
# syntax target cannot catch this. In the related Synology project it reached a
# running VM once: the ported in-use guard called dirname() with no
# `use File::Basename`, and the only reason it was not worse is that the failure
# refused the delete rather than allowing it. The related Dell project met it
# again, in a multipath claim that would have died on the activation path.
#
# Ported from the Synology project, where it is t/07-imports.t.
#
# B::Lint's undefined-subs check would do this properly, but it is not installed
# on a Proxmox VE node and requiring it would add a dependency for a test. So the
# source is scanned — and the scan strips comments, strings and heredocs FIRST,
# because the first version of this test reported twenty findings that were all
# words inside prose. A guard with false positives is a guard people learn to
# ignore.

use strict;
use warnings;
use Test::More;
use lib 'lib';

my @modules = qw(
    PVE::Storage::Custom::QNAP::API
    PVE::Storage::Custom::QNAP::Command
    PVE::Storage::Custom::QNAP::LUN
    PVE::Storage::Custom::QNAP::Target
    PVE::Storage::Custom::QNAP::Naming
    PVE::Storage::Custom::QNAP::ISCSI
    PVE::Storage::Custom::QNAP::Multipath
    PVE::Storage::Custom::QNAP::WwidState
    PVE::Storage::Custom::QNAP::Deferred
    PVE::Storage::Custom::QNAP::Health
);

# THE PLUGIN ITSELF WAS NOT ON THIS LIST, and it is the largest file in the
# project. It was left off because it needs Proxmox VE to load, and this test
# resolves a name with `$mod->can`. The cost of that omission was measured in
# the Synology project: a call to `_warn_once` was added to `activate_volume`,
# `perl -c` compiled it without a word, this test passed, and the sub lives only
# in Health.pm where it is private. It would have died at runtime, on the
# activation path, during a rollback.
#
# So the plugin is scanned when Proxmox VE is present and skipped when it is
# not. A check that runs on the developer's node and not in CI is worth far more
# than one that runs nowhere.
my $plugin = 'PVE::Storage::Custom::QNAPSANPlugin';
my $have_pve = eval { require PVE::Storage::Plugin; 1 } ? 1 : 0;

require_ok($_) for @modules;

if ($have_pve && eval { require PVE::Storage::Custom::QNAPSANPlugin; 1 }) {
    push @modules, $plugin;
    pass("$plugin is scanned too");
} else {
    diag("$plugin skipped: no Proxmox VE on this machine");
}

# Perl's own named operators and keywords, which look like calls to a regex.
my %not_a_sub = map { $_ => 1 } qw(
    if elsif unless while until for foreach do sub my our local return last next
    redo goto and or not xor eq ne lt gt le ge cmp x qw q qq qr m s tr y
    defined ref exists delete scalar wantarray bless can isa
    print printf sprintf warn die eval
    length int lc uc lcfirst ucfirst substr index rindex reverse join split
    push pop shift unshift splice keys values each sort grep map
    open close read readline binmode eof seek tell fileno flock truncate
    sysread syswrite sysseek select
    opendir readdir closedir rewinddir mkdir rmdir unlink rename glob
    stat lstat readlink symlink link chmod chown utime
    sleep time times localtime gmtime alarm
    fork wait waitpid kill exit system exec pipe
    chr ord hex oct abs atan2 cos exp log rand sin sqrt srand pack unpack vec
    quotemeta chomp chop sprintf require caller local
);

# Strip anything that is not code, so a word inside prose is never a finding.
sub code_only {
    my ($src) = @_;

    # POD.
    $src =~ s/^=\w+.*?^=cut\s*$//gms;

    # Heredocs, body and all. conf_content's body contains `device {` and
    # `vendor "QNAP"`, which would otherwise be read as code.
    $src =~ s/<<"?'?(\w+)"?'?;.*?^\1$//gms;

    my @out;
    for my $line (split /\n/, $src) {
        # Remove a comment, but only when the # is not inside a quote. Walked
        # rather than regexed, because `$x = "a#b"; # real comment` needs both.
        my ($clean, $q) = ('', '');
        my @c = split //, $line;
        for my $i (0 .. $#c) {
            my $ch = $c[$i];
            my $prev = $i ? $c[$i - 1] : '';
            if ($q) {
                $q = '' if $ch eq $q && $prev ne '\\';
            } elsif ($ch eq '"' || $ch eq "'") {
                $q = $ch;
            } elsif ($ch eq '#') {
                last;
            }
            $clean .= $ch;
        }
        # Now the string literals themselves.
        $clean =~ s/"(?:\\.|[^"\\])*"/""/g;
        $clean =~ s/'(?:\\.|[^'\\])*'/''/g;
        push @out, $clean;
    }
    return join "\n", @out;
}

my @problems;
for my $mod (@modules) {
    (my $rel = $mod) =~ s{::}{/}g;
    my $path = "lib/$rel.pm";

    open(my $fh, '<', $path) or do { push @problems, "cannot read $path"; next };
    my $src = do { local $/; <$fh> };
    close($fh);

    my $code = code_only($src);

    my %called;
    # A bare `name(` — not $obj->name(, not Package::name(, not &name(, not a
    # definition, and not a hash key followed by (.
    while ($code =~ /(?<![\$\w:>&\-])\b([a-z_][a-z0-9_]*)\s*\(/g) {
        $called{$1} = 1;
    }

    for my $fn (sort keys %called) {
        next if $not_a_sub{$fn};
        next if $code =~ /^\s*sub \Q$fn\E\b/m;   # defined in this file
        next if $code =~ /^\s*use constant\b[^;]*\b\Q$fn\E\s*=>/ms;  # a constant
        next if $mod->can($fn);                  # imported, or inherited
        push @problems, "$path calls $fn() but cannot reach it";
    }
}

diag($_) for @problems;
is(scalar @problems, 0,
   'every bare function call in every module resolves to something callable');

# AND EVERY FULLY QUALIFIED ONE, which in this project is nearly all of them.
#
# The plugin and the modules call each other as
# `PVE::Storage::Custom::QNAP::Multipath::ensure_map(...)` rather than through
# imports, so the scan above — written for bare names — sees almost none of the
# calls that matter here. A misspelt name after the last `::` compiles exactly
# as silently as a missing import does, and dies at the same moment: the first
# time that line runs, which for a cleanup path is the day something else has
# already gone wrong.
#
# The bin scripts are scanned too. They are read, not loaded: they need a NAS.
my @qualified_problems;
my @sources = map { (my $r = $_) =~ s{::}{/}g; "lib/$r.pm" } @modules;
push @sources, grep { -f } glob('bin/*');

for my $path (@sources) {
    open(my $fh, '<', $path) or do { push @qualified_problems, "cannot read $path"; next };
    my $code = code_only(do { local $/; <$fh> });
    close($fh);

    my %seen;
    while ($code =~ /\b(PVE::Storage::Custom::QNAP::[A-Za-z]+)::([A-Za-z_][A-Za-z0-9_]*)\s*\(/g) {
        my ($pkg, $fn) = ($1, $2);
        next if $seen{"$pkg\::$fn"}++;
        # A package this run could not load is the plugin without Proxmox VE,
        # and is skipped for the reason given above.
        next if !grep { $_ eq $pkg } @modules;
        no strict 'refs';
        push @qualified_problems, "$path calls ${pkg}::$fn() and there is no such sub"
            if !defined &{"${pkg}::$fn"};
    }
}

diag($_) for @qualified_problems;
is(scalar @qualified_problems, 0,
   'every fully qualified call names a sub that exists');

done_testing();
