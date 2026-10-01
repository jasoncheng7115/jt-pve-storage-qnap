#!/usr/bin/perl
# The XML layer, and the parts of the transport that can be tested without a NAS.
#
# QTS answers XML, and two properties of those answers make a naive parser wrong
# in ways that only show up against real firmware. Both are pinned here.

use strict;
use warnings;
use Test::More tests => 41;

use PVE::Storage::Custom::QNAP::API;
my $A = 'PVE::Storage::Custom::QNAP::API';

sub parse { return { doc => PVE::Storage::Custom::QNAP::API::_parse_xml($_[0]) } }

# ---------------------------------------------------------------------------
# An answer may have MORE THAN ONE ROOT ELEMENT
# ---------------------------------------------------------------------------
#
# A list element followed by `<result>0</result>` at the same level is not
# well-formed XML and no parser will accept it as a document — so the body is
# wrapped before parsing, and both that shape and the `<QDocRoot>` one parse
# identically.
my $two_roots = q{<iSCSIPortal><maxLUNCnt>256</maxLUNCnt></iSCSIPortal><result>0</result>};
my $r = parse($two_roots);
ok($r->{doc}, 'an answer with two root elements still parses');
is($A->can('text') && PVE::Storage::Custom::QNAP::API::text($r, 'result'), '0',
   'and <result> is readable from it');
is(PVE::Storage::Custom::QNAP::API::text($r, 'maxLUNCnt'), '256',
   'as is a field from the other root');

my $qdoc = q{<?xml version="1.0" encoding="UTF-8" ?><QDocRoot version="1.0">}
         . q{<authPassed><![CDATA[1]]></authPassed><authSid><![CDATA[abcd1234]]></authSid>}
         . q{<result>0</result></QDocRoot>};
$r = parse($qdoc);
ok($r->{doc}, 'the QDocRoot shape parses too');
is(PVE::Storage::Custom::QNAP::API::text($r, 'authSid'), 'abcd1234',
   'CDATA is unwrapped — the session id is the one thing that must never'
 . ' arrive with its wrapper still on');
is(PVE::Storage::Custom::QNAP::API::text($r, 'authPassed'), '1',
   'and so is the flag beside it');

is(PVE::Storage::Custom::QNAP::API::_parse_xml('<html><body>404</body></html>')
   ? 'parsed' : 'no', 'parsed', 'an HTML error page parses as XML-ish...');
is(PVE::Storage::Custom::QNAP::API::text(parse('<html><body>404</body></html>'), 'result'),
   undef, '...but has no <result>, which is what the caller actually checks');

is(PVE::Storage::Custom::QNAP::API::_parse_xml(''), undef,
   'an empty body is not an answer');
is(PVE::Storage::Custom::QNAP::API::_parse_xml('{"success":true}'), undef,
   'JSON is not an answer either, so a firmware that spoke it would be named');

# ---------------------------------------------------------------------------
# text() is a FUNCTION
# ---------------------------------------------------------------------------
#
# Called as `$api->text($res, 'result')` the arguments shift by one and it
# returns undef — which every caller reads as "the NAS did not say", so a
# perfectly good answer is discarded silently.
my $api = PVE::Storage::Custom::QNAP::API->new(
    portals => '192.0.2.1', username => 'admin', password => 'x', storeid => 't');
eval { PVE::Storage::Custom::QNAP::API::text($api, 'result') };
like($@, qr/function, not a method/, 'a method call on text() dies loudly');

# ---------------------------------------------------------------------------
# rows(): direct children only
# ---------------------------------------------------------------------------
#
# `lun_info` returns a `<LUNTargetList>` nested INSIDE the LUN's `<row>`. A
# flattening reader would put that sub-list's `targetIndex` in beside the LUN's
# own fields, where it would look like a field of the LUN.
my $lun = q{<LUNInfo><row>
  <LUNIndex>3</LUNIndex>
  <LUNName>some_lun</LUNName>
  <capacity_bytes>1073741824</capacity_bytes>
  <LUNNAA>60123456789abcdef0123456789abcde</LUNNAA>
  <LUNTargetList><row><targetIndex>0</targetIndex><LUNNumber>1</LUNNumber>
  <LUNEnable>1</LUNEnable></row></LUNTargetList>
</row></LUNInfo><result>0</result>};

$r = parse($lun);
my $rows = PVE::Storage::Custom::QNAP::API::rows($r, '//LUNInfo/row');
is(scalar @$rows, 1, 'one LUN row');
is($rows->[0]{LUNIndex}, '3', 'a scalar field is read');
is($rows->[0]{capacity_bytes}, '1073741824', 'and so is the capacity');
ok(!exists $rows->[0]{targetIndex},
   "the nested list's targetIndex does NOT appear as a field of the LUN");
ok($rows->[0]{_LUNTargetList}, 'the nested list is kept, under a marked name');

my $sub = PVE::Storage::Custom::QNAP::API::sub_rows(
    $rows->[0]{_LUNTargetList}[0], 'row');
is(scalar @$sub, 1, 'the nested list has one row');
is($sub->[0]{LUNNumber}, '1',
   'and it carries LUNNumber — the number within the target, which is what the'
 . ' by-path device name uses');

# `targetLUNList` is a count followed by BARE `<LUNIndex>` elements with no
# `<row>` around each one, which is a different shape from every other list.
my $tinfo = q{<targetInfo><row><targetIndex>0</targetIndex>
  <targetLUNList><targetLUNListCnt>2</targetLUNListCnt>
  <LUNIndex>0</LUNIndex><LUNIndex>3</LUNIndex></targetLUNList>
</row></targetInfo><result>0</result>};
$r = parse($tinfo);
my ($trow) = @{ PVE::Storage::Custom::QNAP::API::rows($r, '//targetInfo/row') };
my $idx = PVE::Storage::Custom::QNAP::API::sub_texts(
    $trow->{_targetLUNList}[0], 'LUNIndex');
is_deeply($idx, [ '0', '3' ], 'the bare-element list form is read correctly');

# ---------------------------------------------------------------------------
# An IQN that arrives wrapped across a line
# ---------------------------------------------------------------------------
#
# An IQN can arrive on its own line inside the element, so the text content has
# newlines and indentation in the middle of it. An IQN with a space in it
# matches no session and creates no node record.
use PVE::Storage::Custom::QNAP::Target;
is(PVE::Storage::Custom::QNAP::Target::_clean_iqn(
       "\niqn.2004-04.com.qnap:ts-example:iscsi.pve-qnap1-tgt.0a1b2c\n"),
   'iqn.2004-04.com.qnap:ts-example:iscsi.pve-qnap1-tgt.0a1b2c',
   'a wrapped IQN is put back together');
is(PVE::Storage::Custom::QNAP::Target::_clean_iqn('   '), undef,
   'and an empty one is undef rather than a string of spaces');

# ---------------------------------------------------------------------------
# Passwords
# ---------------------------------------------------------------------------
#
# Base64 of the UTF-8 bytes: `secret` becomes `c2VjcmV0`.
is(PVE::Storage::Custom::QNAP::API::_encode_password('secret'), 'c2VjcmV0',
   'a password is sent as Base64');
# No newlines. encode_base64 wraps at 76 characters by default, and a wrapped
# credential is one the NAS will not recognise while looking perfectly correct.
unlike(PVE::Storage::Custom::QNAP::API::_encode_password('x' x 200), qr/\n/,
   'a long password is encoded without a line break');

# ---------------------------------------------------------------------------
# A logout that actually asks to log out
# ---------------------------------------------------------------------------
#
# The session id AND an explicit `logout=1`. Both go, because a logout the NAS
# answers and does not act on leaks a session per call — the related Dell plugin
# sent one of those for five releases and its array answered every one happily.
#
# This pins what is SENT. Whether QTS then drops the session can only be
# measured on a NAS, and docs/TESTING.md lists it.
my $out = PVE::Storage::Custom::QNAP::API::_logout_form('abcd1234');
is($out->{sid}, 'abcd1234', 'a logout names the session it is ending');
is($out->{logout}, 1, 'and carries logout=1, not the sid alone');

# ---------------------------------------------------------------------------
# A forked result is asked for by the CGI's NAME, not by its path
# ---------------------------------------------------------------------------
#
# Requests go to `disk/snapshot.cgi`; `get_return` takes the CGI's name. Sending
# the path as the name is a clone or a rollback whose result is never collected.
is(PVE::Storage::Custom::QNAP::API::cgi_name('disk/snapshot.cgi'), 'snapshot.cgi',
   'the path a request goes to becomes the name get_return is keyed by');
is(PVE::Storage::Custom::QNAP::API::cgi_name('snapshot.cgi'), 'snapshot.cgi',
   'and a bare name is left alone');
is(PVE::Storage::Custom::QNAP::API::cgi_name(undef), undef, 'undef stays undef');

# ---------------------------------------------------------------------------
# A GET is sent for ONE reason, and a healthy NAS never gives it
# ---------------------------------------------------------------------------
#
# The fallback exists for a firmware whose CGIs do not read a POST body. It
# used to fire on any answer without a `<result>` — and the NAS's own
# description, and a forked operation still running, are two healthy answers
# with none. So an ordinary NAS was sent a GET, sid in the URL, on each of
# those. The only trigger now is a session that was issued a moment ago and is
# still not recognised.
{
    my (@sent, @answers);
    no warnings 'redefine';
    local *PVE::Storage::Custom::QNAP::API::login  = sub { $_[0]{sid} = 'fresh'; 1 };
    local *PVE::Storage::Custom::QNAP::API::logout = sub { $_[0]{sid} = undef; return };
    local *PVE::Storage::Custom::QNAP::API::_do_call = sub {
        my ($self, $cgi, $params, $method) = @_;
        push @sent, ($method // 'POST');
        return shift @answers;
    };
    my @warned;
    local $SIG{__WARN__} = sub { push @warned, $_[0] };
    my $c = PVE::Storage::Custom::QNAP::API->new(
        portals => '192.0.2.1', username => 'pve', password => 'x', storeid => 'getrule');

    my $described  = sub { parse('<authPassed>1</authPassed><model><modelName>X</modelName></model>') };
    my $processing = sub { parse('<authPassed>1</authPassed><processing>1</processing>') };
    my $refused    = sub { parse('<authPassed>0</authPassed>') };
    my $done       = sub { parse('<authPassed>1</authPassed><result>0</result>') };

    @sent = (); @answers = ($described->());
    $c->call('authLogin.cgi');
    is_deeply(\@sent, [ 'POST' ], "the NAS's description has no <result>, and no GET follows it");

    @sent = (); @answers = ($processing->());
    $c->call('disk/snapshot.cgi', func => 'get_return', cginame => 'snapshot.cgi');
    is_deeply(\@sent, [ 'POST' ], 'nor does one follow a forked operation that is still running');

    @sent = (); @answers = ($refused->(), $done->());
    my $r = $c->call('disk/x.cgi', func => 'f');
    is_deeply(\@sent, [ 'POST', 'POST' ], 'an expired session is a new login and the same POST again');
    is($r->{result}, '0', 'and its answer is the one returned');

    @sent = (); @answers = ($refused->(), $refused->(), $done->());
    $r = $c->call('disk/x.cgi', func => 'f');
    is_deeply(\@sent, [ 'POST', 'POST', 'GET' ],
       'a fresh session that is STILL not recognised is the body not being read: only then a GET');
    is($r->{result}, '0', 'whose answer is used');
    is(scalar(grep { /did not read the POST/ } @warned), 1, 'and it is said out loud');

    @sent = (); @answers = ($refused->(), $refused->(), $done->());
    $c->call('disk/x.cgi', func => 'f', CHAPPasswd => 'secret', _secret => 1);
    is_deeply(\@sent, [ 'POST', 'POST' ], 'but NEVER for a call that carries a secret');
}

# ---------------------------------------------------------------------------
# Error text
# ---------------------------------------------------------------------------
like(PVE::Storage::Custom::QNAP::API::error_text(-13), qr/rejected one of the parameters/,
   'a code this plugin knows is described');
like(PVE::Storage::Custom::QNAP::API::error_text(-9999), qr/no description/,
   'one it does not know says so rather than inventing a description');
is(PVE::Storage::Custom::QNAP::API::error_text(undef), 'no result',
   'and a missing result is distinguishable from any code');

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------
eval { PVE::Storage::Custom::QNAP::API->new(portals => '', storeid => 't') };
like($@, qr/no management address/, 'a storage with no address is refused');
is($api->scheme, 'https',
   'https is the default, because http puts the password on the wire in clear');
