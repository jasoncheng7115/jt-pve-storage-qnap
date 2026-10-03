#!/usr/bin/perl

# The QNAP API calls this plugin makes, all of them, and no others.
#
# THIS LIST IS NOT A CONVENIENCE. The set of calls is deliberately fixed, and a
# call that is not on this list does not get merged by being added to it.
#
# So when this test fails, the fix is not to add a line here. Open an issue,
# say which call and why, and wait for the maintainer's decision. Removing a
# call needs nobody's permission — delete its line and carry on.
#
# The source is scanned rather than the modules loaded: a call is what the code
# sends, wherever it is written, and a scan sees the command-line tools too.

use strict;
use warnings;
use Test::More tests => 10;

# CGI programs under /cgi-bin.
my @CGIS = qw(
    authLogin.cgi
    authLogout.cgi
    disk/disk_manage.cgi
    disk/iscsi_lun_setting.cgi
    disk/iscsi_portal_setting.cgi
    disk/iscsi_target_setting.cgi
    disk/snapshot.cgi
);

# Every `func=` value sent. Three of them are sent to two CGIs each — `add_lun`,
# `edit_lun` and `remove_lun` mean one thing on the LUN CGI and another on the
# target CGI — which is why the pairs are listed below as well.
my @FUNCS = qw(
    add_init
    add_lun
    add_target
    clone_qsnapshot
    create_snapshot
    del_snapshot
    edit_init
    edit_lun
    edit_target
    extra_get
    get_return
    recover_snapshot
    remove_lun
    remove_target
);

# `func=extra_get` is a family of queries, selected by a switch set to 1.
my @QUERIES = qw(
    Pool_Info
    extra_lun_index
    extra_pool_index
    iSCSI_portal
    lun_info
    snapshot_list
    targetInfo
    targetList
);

# Each write, with the CGI it goes to. 15 of them.
my @WRITES = (
    'disk/iscsi_lun_setting.cgi add_lun',
    'disk/iscsi_lun_setting.cgi edit_lun',
    'disk/iscsi_lun_setting.cgi remove_lun',
    'disk/iscsi_target_setting.cgi add_init',
    'disk/iscsi_target_setting.cgi add_lun',
    'disk/iscsi_target_setting.cgi add_target',
    'disk/iscsi_target_setting.cgi edit_init',
    'disk/iscsi_target_setting.cgi edit_lun',
    'disk/iscsi_target_setting.cgi edit_target',
    'disk/iscsi_target_setting.cgi remove_lun',
    'disk/iscsi_target_setting.cgi remove_target',
    'disk/snapshot.cgi clone_qsnapshot',
    'disk/snapshot.cgi create_snapshot',
    'disk/snapshot.cgi del_snapshot',
    'disk/snapshot.cgi recover_snapshot',
);

# ---------------------------------------------------------------------------
# Read the source, without its comments
# ---------------------------------------------------------------------------
my @files = (glob('lib/PVE/Storage/Custom/QNAP/*.pm'),
             'lib/PVE/Storage/Custom/QNAPSANPlugin.pm', glob('bin/*'));

my %src;
for my $f (@files) {
    open(my $fh, '<', $f) or die "cannot read $f: $!";
    my $text = '';
    while (my $line = <$fh>) {
        # A comment describes a call; only code makes one.
        $line =~ s/(^|\s)#.*$//;
        $text .= $line;
    }
    close($fh);
    $src{$f} = $text;
}
my $all = join("\n", values %src);

ok(scalar(@files) > 5, 'the source was found — run this from the project root');

sub uniq_sorted { my %s = map { $_ => 1 } @_; return [ sort keys %s ] }

# ---------------------------------------------------------------------------
# The three sets
# ---------------------------------------------------------------------------
my $cgis = uniq_sorted($all =~ /'((?:disk\/)?[A-Za-z_]+\.cgi)'/g);
is_deeply($cgis, [ sort @CGIS ], 'the CGI programs called are exactly the listed ones')
    or diag("in the source: @$cgis");

my $funcs = uniq_sorted($all =~ /\bfunc\s*=>\s*'([A-Za-z_]+)'/g);
is_deeply($funcs, [ sort @FUNCS ], 'the func values sent are exactly the listed ones')
    or diag("in the source: @$funcs");

my $queries = uniq_sorted(
    $all =~ /\bfunc\s*=>\s*'extra_get',\s*([A-Za-z_]+)\s*=>\s*1/g);
is_deeply($queries, [ sort @QUERIES ], 'the extra_get queries are exactly the listed ones')
    or diag("in the source: @$queries");

# ---------------------------------------------------------------------------
# The writes, each with its CGI
# ---------------------------------------------------------------------------
#
# A module names its CGIs once, as constants, and each sub talks to ONE of them.
# So a func is paired with the constant its own sub passes to `call`. A sub that
# passed two would be ambiguous, and is reported as such rather than guessed at.
my %const;
for my $text (values %src) {
    while ($text =~ /\b(CGI_[A-Z]+)\s*=>\s*'([^']+)'/g) { $const{$1} = $2 }
}

my %seen_write;
for my $f (sort keys %src) {
    # Split on `sub name {` at the start of a line; the first piece is the
    # file's preamble and makes no calls.
    my @subs = split /^(?=sub\s+\w+\s*\{)/m, $src{$f};
    for my $body (@subs) {
        my @funcs = grep { $_ ne 'extra_get' && $_ ne 'get_return' }
                    $body =~ /\bfunc\s*=>\s*'([A-Za-z_]+)'/g;
        next if !@funcs;

        my %used = map { $_ => 1 } $body =~ /\bcall(?:_ok|_id)?\(\s*(CGI_[A-Z]+)\b/g;
        my @used = sort keys %used;
        my $cgi = @used == 1 ? $const{ $used[0] } : undef;

        my ($name) = $body =~ /^sub\s+(\w+)/;
        $seen_write{ ($cgi // "?? (sub $name in $f)") . " $_" } = 1 for @funcs;
    }
}
is_deeply([ sort keys %seen_write ], [ sort @WRITES ],
   'every call that changes something on the NAS is on the list, with its CGI')
    or diag("in the source:\n  " . join("\n  ", sort keys %seen_write));

# ---------------------------------------------------------------------------
# And the total
# ---------------------------------------------------------------------------
#
# 3 session calls (login, the same CGI asked for the NAS's description, logout),
# 8 queries, get_return, and the 15 writes.
is(3 + scalar(@QUERIES) + 1 + scalar(@WRITES), 27,
   'which is 27 calls in all');

# ---------------------------------------------------------------------------
# QuTS hero h6: the JSON interface
# ---------------------------------------------------------------------------
#
# A SECOND, SEPARATE LIST, added for QuTS hero h6, where the writes above are
# refused and the plugin writes through `/api` instead. Each of these was seen
# to work on h6.0.1 except the last, the Default Policy row, whose result the
# plugin reads back. The same rule applies: a request that is not here does not
# get in by being added here.
#
# Ten requests: the volume list, one volume, creating and deleting a volume;
# creating and deleting a target; attaching, enabling and detaching a LUN; and
# the target's Default Policy row.
my @REST_CALLS = (
    'GET    api/storage/v1/volumes',
    'POST   api/storage/v1/volumes',
    'GET    api/storage/v1/volumes/{}',
    'DELETE api/storage/v1/volumes/{}',
    'POST   api/iscsi/v1/targets',
    'DELETE api/iscsi/v1/targets/{}',
    'POST   api/iscsi/v1/targets/{}/luns/{}',
    'PUT    api/iscsi/v1/targets/{}/luns/{}',
    'DELETE api/iscsi/v1/targets/{}/luns/{}',
    'PUT    api/iscsi/v1/targets/{}/acls/{}',
);

my %rest_const;
for my $text (values %src) {
    while ($text =~ /\b(REST_[A-Z]+)\s*=>\s*'([^']+)'/g) { $rest_const{$1} = $2 }
}
# A path is written as a constant, optionally followed by a string with the
# indexes in it, optionally followed by another constant.
my $path_re = qr/(REST_[A-Z]+)(?:\s*\.\s*"([^"]*)")?/;
my $norm = sub {
    my ($c, $tail, $more) = @_;
    my $p = ($rest_const{$c} // "?$c") . ($tail // '');
    $p =~ s/\$\w+/{}/g;
    $p .= '{}' if $more;
    return $p;
};

my %seen_rest;
for my $f (sort keys %src) {
    my @subs = split /^(?=sub\s+\w+\s*\{)/m, $src{$f};
    for my $body (@subs) {
        # `my $path = REST_X . "..."` then `rest(..., $path, ...)`.
        my %var;
        while ($body =~ /my\s+\$(\w+)\s*=\s*$path_re\s*(\.\s*[A-Z_]+)?\s*;/g) {
            $var{$1} = $norm->($2, $3, $4);
        }
        while ($body =~ /\brest(?:_ok)?\(\s*'(GET|POST|PUT|DELETE)',\s*(?:\$(\w+)|$path_re(\s*\.\s*[A-Z_]+)?)/g) {
            my ($m, $v, $c, $tail, $more) = ($1, $2, $3, $4, $5);
            my $p = defined $v ? ($var{$v} // "?\$$v") : $norm->($c, $tail, $more);
            $seen_rest{ sprintf('%-6s %s', $m, $p) } = 1;
        }
    }
}
is_deeply([ sort keys %seen_rest ], [ sort @REST_CALLS ],
   'h6: the JSON requests sent are exactly the listed ones')
    or diag("in the source:\n  " . join("\n  ", sort keys %seen_rest));
is(scalar(@REST_CALLS), 10, 'which is ten');
unlike($src{'lib/PVE/Storage/Custom/QNAP/API.pm'}, qr/\bsid\b[^\n]*\?[^\n]*sid=|_rest_url\([^)]*sid/,
       'and the session goes in a header, never in a JSON request URL');

# Nothing here may be sent as a GET with a credential in it; `make
# check-secrets` guards that. This only confirms the login is where it should
# be, because it is the one call the lists above cannot express as a func.
like($src{'lib/PVE/Storage/Custom/QNAP/API.pm'},
     qr/_http\('authLogin\.cgi',\s*\{\s*user\s*=>/,
     'the login is sent through the POST-only path');
