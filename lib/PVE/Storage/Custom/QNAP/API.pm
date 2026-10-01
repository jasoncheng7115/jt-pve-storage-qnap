package PVE::Storage::Custom::QNAP::API;

# QTS HTTP transport.
#
# QTS is NOT a REST API and nothing here should be written as though it were.
# It is a set of CGI programs under /cgi-bin, each taking a `func=` parameter
# and a `sid=`, and each answering XML. Four consequences shape this whole file:
#
#   1. **The credential must not travel in a URL.** A URL is what ends up in
#      logs, in every proxy in between, and in any shell history that ever
#      reproduced the call. Everything here is sent as a POST body instead. A
#      GET fallback exists for calls that carry no secret at all, because a
#      firmware that ignores POST would otherwise make the plugin unusable; the
#      login and anything carrying a CHAP secret never take it.
#
#   2. **`<result>` does not mean the same thing twice.** For most calls 0 is
#      success. For `add_target`, `add_lun` and `create_snapshot` a SUCCESS is a
#      non-negative identifier and only a negative value is a failure. So this
#      module never decides success on its own: it returns the number and the
#      caller, which knows which call it made, decides. A generic `result == 0`
#      test would read a newly created LUN's index of 2 as a failure — and read
#      LUN index 0 as a success for every call that returns an index.
#
#   3. **An answer may have more than one root element.** A list element
#      followed by `<result>0</result>` at the same level is not well-formed
#      XML and no parser will accept it; an answer wrapped in `<QDocRoot>` is.
#      Rather than depend on which of the two arrives, the body is wrapped in a
#      synthetic root before it is parsed, so both shapes parse identically.
#
#   4. **A forked operation reports through a channel keyed by CGI NAME.** A
#      clone or a snapshot rollback answers `<fork>1</fork>` and the real result
#      arrives later from `snapshot.cgi?func=get_return&cginame=snapshot.cgi`.
#      The key is the CGI, NOT a job id — so two clones running at once cannot
#      be told apart, and whichever asks first may collect the other's result.
#      This module gives the caller `wait_for_fork`; making sure only one such
#      operation is in flight across the CLUSTER is the plugin's job, and it
#      does it with PVE's own storage lock.

use strict;
use warnings;

use PVE::Storage::Custom::QNAP::Naming;

use MIME::Base64 qw(encode_base64);
use LWP::UserAgent;
use HTTP::Request::Common qw(POST GET);
use XML::LibXML;
use Time::HiRes qw(time);

use constant {
    # Where the credential latch lives. It has to be a FILE: the plugin builds
    # a new API object for every call, so an instance field would die with the
    # object. pvestatd polls every ten seconds, and QTS's Network Access
    # Protection blocks a source address after a handful of failed logins —
    # which would take a node out of the NAS entirely, and look like a dead NAS
    # rather than a bad password.
    LATCH_DIR       => '/run/jt-pve-storage-qnap',

    DEFAULT_PORT    => 443,
    DEFAULT_SCHEME  => 'https',
    DEFAULT_TIMEOUT => 30,
    STATUS_TIMEOUT  => 5,
};

# What a negative `<result>` means, in this plugin's own words. Only the codes a
# storage plugin can actually provoke are listed; anything else is reported by
# number, because inventing a description is worse than admitting the number is
# not one this plugin knows.
our %ERR = (
    0   => 'ok',
    -1  => 'the NAS reported an unspecified error',
    -3  => 'the NAS could not open something it needed',
    -4  => 'the NAS could not read something it needed',
    -5  => 'the NAS could not write something it needed',
    -6  => 'the NAS could not find the object named in the call',
    -9  => 'the answer did not fit the buffer the NAS had for it',
    -10 => 'the NAS ran out of memory',
    -12 => 'the object named in the call is not there',
    -13 => 'the NAS rejected one of the parameters',
    -14 => 'the NAS could not unmount the volume',
    -29 => 'there is no such volume',
    -37 => 'the NAS could not read the volume configuration',
);

sub error_text {
    my ($code) = @_;
    return 'no result' if !defined $code;
    my $t = $ERR{$code};
    return defined $t ? "$code ($t)" : "$code (a code this plugin has no description for)";
}

sub new {
    my ($class, %opt) = @_;

    my $portals = $opt{portals};
    $portals = [ split(/\s*,\s*/, $portals // '') ] if !ref $portals;
    @$portals = grep { defined && length } @$portals;
    die "no management address given\n" if !@$portals;

    my $self = bless {
        portals   => $portals,
        # Which portal to try first. Rotated by a failure, and deliberately
        # sticky: the next request should start where the last one succeeded.
        portal_ix => 0,
        scheme    => ($opt{scheme} // DEFAULT_SCHEME),
        port      => $opt{port} // DEFAULT_PORT,
        username  => $opt{username},
        password  => $opt{password},
        ssl_verify => $opt{ssl_verify} ? 1 : 0,
        tls_ca    => $opt{tls_ca},
        # The health path uses a short timeout and a single attempt: the next
        # poll is the retry, and a storage that hangs must not hold up
        # `pvesm status` for every other storage on the node.
        status    => $opt{status} ? 1 : 0,
        timeout   => $opt{timeout} // ($opt{status} ? STATUS_TIMEOUT : DEFAULT_TIMEOUT),
        storeid   => $opt{storeid} // '<unnamed>',

        sid       => undef,
        sysinfo   => undef,
        portal_info => undef,
        credential_refused => undef,
        # The pid that built this object. DESTROY below must not act on a
        # forked child's copy.
        owner_pid => $$,
    }, $class;

    return $self;
}

sub storeid { return $_[0]->{storeid} }
sub scheme  { return $_[0]->{scheme} }

# ---------------------------------------------------------------------------
# The credential latch, which must outlive one process
# ---------------------------------------------------------------------------
#
# Under /run rather than /var/lib deliberately: a reboot is a legitimate reason
# to try again, and an operator who has fixed the account should not have to
# know about a file. A configuration change clears it explicitly.

sub _latch_file {
    my ($self) = @_;
    my $safe = PVE::Storage::Custom::QNAP::Naming::filename_component(
        $self->{storeid}) or return undef;
    return LATCH_DIR . "/$safe.credential-refused";
}

sub _read_latch {
    my ($self) = @_;
    my $f = $self->_latch_file or return undef;
    open(my $fh, '<', $f) or return undef;
    my $why = <$fh> // '';
    close($fh);
    chomp $why;
    return length($why) ? $why : 'a previous credential failure';
}

sub _write_latch {
    my ($self, $why) = @_;
    my $f = $self->_latch_file or return;
    mkdir LATCH_DIR, 0700 if !-d LATCH_DIR;
    if (open(my $fh, '>', $f)) {
        print $fh "$why\n";
        close($fh);
    }
    return;
}

# Called when the configuration changes: the operator has had a chance to fix it.
sub clear_credential_latch {
    my ($class_or_self, $storeid) = @_;
    $storeid = $class_or_self->{storeid} if ref $class_or_self;
    return if !defined $storeid;
    my $safe = PVE::Storage::Custom::QNAP::Naming::filename_component($storeid)
        or return;
    unlink LATCH_DIR . "/$safe.credential-refused";
    return;
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

sub _ua {
    my ($self) = @_;
    return $self->{ua} if $self->{ua};

    my %ssl;
    if ($self->{ssl_verify}) {
        $ssl{ssl_opts} = { verify_hostname => 1, SSL_verify_mode => 1 };
        $ssl{ssl_opts}{SSL_ca_file} = $self->{tls_ca} if $self->{tls_ca};
    } else {
        # QTS ships a self-signed certificate. A default of "verify" would mean
        # almost no fresh NAS could be added at all, and a default nobody can
        # use protects nobody. qnap-ssl-verify turns it on.
        $ssl{ssl_opts} = { verify_hostname => 0, SSL_verify_mode => 0 };
    }

    my $ua = LWP::UserAgent->new(
        timeout => $self->{timeout},
        agent   => 'jt-pve-storage-qnap',
        %ssl,
    );
    # A redirect to a login page is an answer, not a place to resend a
    # credential: every request here carries one.
    $ua->max_redirect(0);

    $self->{ua} = $ua;
    return $ua;
}

sub _portal { return $_[0]->{portals}[ $_[0]->{portal_ix} ] }

sub _rotate_portal {
    my ($self) = @_;
    return 0 if @{ $self->{portals} } < 2;
    $self->{portal_ix} = ($self->{portal_ix} + 1) % scalar @{ $self->{portals} };
    # A session belongs to the address that issued it.
    $self->{sid} = undef;
    return 1;
}

sub _url {
    my ($self, $cgi) = @_;
    my $portal = $self->_portal;

    # A portal may carry its own port. Splitting on the LAST colon leaves IPv6
    # literals in brackets alone.
    my ($host, $port) = ($portal, $self->{port});
    if ($portal =~ /\A(.+):(\d+)\z/ && $1 !~ /:\z/) {
        ($host, $port) = ($1, $2);
    }

    $cgi =~ s{\A/+}{};
    return $self->{scheme} . "://$host:$port/cgi-bin/$cgi";
}

# ONE HTTP ROUND TRIP.
#
# The URL is built HERE and not by the caller: a URL built before a login that
# rotates portals goes on travelling to the address that was just found dead.
#
# `method` defaults to POST. See note 1 at the top of this file: a credential in
# a URL ends up in logs.
sub _http {
    my ($self, $cgi, $form, %opt) = @_;

    my $url = $self->_url($cgi);
    my $req = ($opt{method} // 'POST') eq 'GET'
        ? GET($url . '?' . _query_string($form))
        : POST($url, [ %$form ]);

    my $res = eval { $self->_ua->request($req) };
    if (!$res) {
        my $err = $@ || 'request failed';
        chomp $err;
        return { transport => $err };
    }

    if (!$res->is_success) {
        return { transport => $res->status_line, http => $res->code };
    }

    my $body = $res->decoded_content(charset => 'none');
    return { transport => 'the NAS returned an empty body', http => $res->code }
        if !defined $body || !length $body;

    my $doc = _parse_xml($body);
    if (!$doc) {
        my $snip = $body;
        $snip =~ s/\s+/ /g;
        $snip = length($snip) > 160 ? substr($snip, 0, 160) . '...' : $snip;
        # Quote the first bytes: on a first run the difference between an HTML
        # error page, a login form and a firmware that answered JSON is the
        # whole diagnosis.
        return { transport => "the answer is not XML: $snip", http => $res->code };
    }

    return { http => $res->code, doc => $doc, body => $body };
}

sub _query_string {
    my ($form) = @_;
    my @p;
    for my $k (sort keys %$form) {
        my $v = $form->{$k};
        next if !defined $v;
        push @p, _uri_escape($k) . '=' . _uri_escape($v);
    }
    return join('&', @p);
}

sub _uri_escape {
    my ($s) = @_;
    $s = '' if !defined $s;
    $s =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord($1))/ge;
    return $s;
}

# ---------------------------------------------------------------------------
# XML
# ---------------------------------------------------------------------------

# Note 3 at the top of this file: an answer may have several root elements, and
# may or may not carry an XML declaration. Both shapes are made into one by
# stripping any declaration and wrapping what is left.
#
# `recover` is on because a NAS is not a validating producer and a single stray
# byte in a field this plugin never reads must not lose the whole answer. The
# caller still gets undef when nothing parsed at all, which is the case that
# means "this was not XML".
sub _parse_xml {
    my ($body) = @_;
    return undef if !defined $body;

    $body =~ s/\A\s*<\?xml.*?\?>\s*//s;
    # A stray NUL or control byte makes libxml refuse the document outright.
    $body =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g;

    my $parser = XML::LibXML->new(
        recover    => 2,
        no_network => 1,
        expand_entities => 0,
        load_ext_dtd    => 0,
    );

    my $doc = eval {
        local $SIG{__WARN__} = sub { };
        $parser->parse_string("<jtroot>$body</jtroot>");
    };
    return undef if !$doc;
    # A document that recovered into nothing is not an answer.
    return undef if !$doc->documentElement;

    # AT LEAST ONE ELEMENT, not merely "some content". The synthetic wrapper
    # means ANY body parses — a JSON object, a plain-text error, a stack trace
    # all come back as a `<jtroot>` with one text child and no elements. Reading
    # that as a successful parse hands the caller a document it will then find
    # no `<result>` in, and the diagnosis becomes "the NAS answered without a
    # result" for a firmware that did not answer XML at all.
    for my $child ($doc->documentElement->childNodes) {
        return $doc if $child->nodeType == XML::LibXML::XML_ELEMENT_NODE();
    }
    return undef;
}

# The text of the first element with this name, anywhere in the answer.
#
# A FUNCTION, not a method, and the guard below is why that has to be said out
# loud. Called as `$api->text($res, 'result')` the arguments shift by one, `$res`
# becomes the API object, `ref $res ne 'HASH'` is true, and it returns undef —
# which every caller reads as "the NAS did not say", so a perfectly good answer
# is discarded silently. The same shape has bitten Naming and Multipath in the
# related projects. Here it fails loudly instead.
sub text {
    my ($res, $name) = @_;
    die __PACKAGE__ . "::text is a function, not a method. Call"
      . " API::text(\$res, 'name').\n"
        if ref $res eq __PACKAGE__;
    return undef if ref $res ne 'HASH' || !$res->{doc};

    my ($node) = $res->{doc}->findnodes("//$name");
    return undef if !$node;
    my $t = $node->textContent;
    return undef if !defined $t;
    $t =~ s/\A\s+//; $t =~ s/\s+\z//;
    return $t;
}

# Every element with this name, as a list of trimmed strings.
sub text_all {
    my ($res, $name) = @_;
    return [] if ref $res ne 'HASH' || !$res->{doc};
    my @out;
    for my $node ($res->{doc}->findnodes("//$name")) {
        my $t = $node->textContent // '';
        $t =~ s/\A\s+//; $t =~ s/\s+\z//;
        push @out, $t;
    }
    return \@out;
}

# Rows: each node matching $xpath becomes a hash of its direct child elements.
#
# Only DIRECT children, deliberately. A `<row>` that contains a nested list —
# `lun_info`'s `LUNTargetList` inside a LUN row — would otherwise flatten
# the nested values in beside the row's own fields, and a `targetIndex` from a
# sub-list would look like a field of the LUN.
sub rows {
    my ($res, $xpath) = @_;
    return [] if ref $res ne 'HASH' || !$res->{doc};

    my @out;
    for my $node ($res->{doc}->findnodes($xpath)) {
        push @out, _element_hash($node);
    }
    return \@out;
}

sub _element_hash {
    my ($node) = @_;
    my %h;
    for my $child ($node->childNodes) {
        next if $child->nodeType != XML::LibXML::XML_ELEMENT_NODE();
        my $name = $child->nodeName;
        # A child that itself has element children is a nested structure, not a
        # value. It is kept as a node so a caller that wants it can ask, and
        # left out of the scalar fields so it cannot be mistaken for one.
        my $has_elements = 0;
        for my $g ($child->childNodes) {
            next if $g->nodeType != XML::LibXML::XML_ELEMENT_NODE();
            $has_elements = 1;
            last;
        }
        if ($has_elements) {
            push @{ $h{"_$name"} }, $child;
            next;
        }
        my $t = $child->textContent // '';
        $t =~ s/\A\s+//; $t =~ s/\s+\z//;
        $h{$name} = $t;
    }
    return \%h;
}

# The text of every direct child of $node named $child_name.
#
# For the lists QTS returns as repeated scalar elements rather than as rows —
# `targetLUNList` is a `targetLUNListCnt` followed by bare `<LUNIndex>` elements,
# with no `<row>` around each one.
sub sub_texts {
    my ($node, $child_name) = @_;
    return [] if !$node;
    my @out;
    for my $n ($node->childNodes) {
        next if $n->nodeType != XML::LibXML::XML_ELEMENT_NODE();
        next if defined $child_name && $n->nodeName ne $child_name;
        my $t = $n->textContent // '';
        $t =~ s/\A\s+//; $t =~ s/\s+\z//;
        push @out, $t if length $t;
    }
    return \@out;
}

# The direct children of a node, as rows. For the nested lists kept by
# _element_hash under a leading underscore.
sub sub_rows {
    my ($node, $child_name) = @_;
    return [] if !$node;
    my @out;
    for my $n ($node->childNodes) {
        next if $n->nodeType != XML::LibXML::XML_ELEMENT_NODE();
        next if defined $child_name && $n->nodeName ne $child_name;
        push @out, _element_hash($n);
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------

# QTS's password encoding: Base64 of the password's UTF-8 bytes.
#
# No newlines: encode_base64's default wraps at 76 characters, and a wrapped
# credential is one the NAS will not recognise while looking perfectly correct
# in a debugger.
sub _encode_password {
    my ($pw) = @_;
    return '' if !defined $pw;
    return encode_base64($pw, '');
}

sub login {
    my ($self) = @_;
    return 1 if defined $self->{sid};

    # Read from disk, not from this object: the object is new on every call.
    $self->{credential_refused} //= $self->_read_latch;

    if (my $why = $self->{credential_refused}) {
        # Latched. Retrying on a ten-second poll is what trips QTS's Network
        # Access Protection and locks this node out of the NAS.
        die "storage '$self->{storeid}': not retrying after $why."
          . " Fix the credentials in the storage configuration; this plugin"
          . " will not attempt another login until it changes, because QTS"
          . " blocks a source address after a few failed logins.\n";
    }

    die "storage '$self->{storeid}': no user name is configured\n"
        if !defined $self->{username} || !length $self->{username};
    die "storage '$self->{storeid}': no password is stored\n"
        if !defined $self->{password} || !length $self->{password};

    my $attempts = scalar @{ $self->{portals} };
    my $last;

    for my $try (1 .. $attempts) {
        # POST, never GET. See note 1 at the top of this file.
        my $r = $self->_http('authLogin.cgi', {
            user => $self->{username},
            pwd  => _encode_password($self->{password}),
        });

        if ($r->{transport}) {
            $last = $r->{transport};
            last if !$self->_rotate_portal;
            next;
        }

        my $passed = text($r, 'authPassed');
        my $sid    = text($r, 'authSid');

        if (defined $passed && $passed eq '1' && defined $sid && length $sid) {
            $self->{sid} = $sid;
            return 1;
        }

        # QTS answers a refused login with authPassed 0 — the same answer for a
        # wrong password, a disabled account and an account without the
        # privilege. There is no code to tell them apart, so the message says
        # what is knowable and no more.
        my $ev = text($r, 'errorValue');
        my $why = 'the NAS did not accept the account'
                . (defined $ev ? " (errorValue $ev)" : '');

        # NEVER rotate and never retry on a refused credential: the next portal
        # is usually the same NAS, and each attempt counts towards a block.
        $self->{credential_refused} = $why;
        $self->_write_latch($why);
        die "storage '$self->{storeid}': QTS refused the login: $why."
          . " Check qnap-username and qnap-password, and that the account is"
          . " an administrator: the Storage Manager and iSCSI CGIs are"
          . " administrator-only.\n";
    }

    die "storage '$self->{storeid}': could not reach any of"
      . " (" . join(', ', @{ $self->{portals} }) . "): "
      . ($last // 'no answer') . "\n";
}

# What a logout sends. Its own function so a test can read it without a NAS.
#
# BOTH parameters: the session being ended, and an explicit `logout=1`. Which of
# the two a firmware goes by is unmeasured, so neither is left out. A logout that
# the NAS answers and does not act on is not a hypothetical: the related Dell
# plugin sent one for five releases, its array answered every one of them
# happily, and the sessions piled up to the array's ceiling. This plugin logs in
# once per call and pvestatd calls every ten seconds from every node, so here
# that would be six leaked sessions a minute per node.
#
# Whether QTS really drops the session is listed as open in docs/TESTING.md;
# it is settled by counting sessions ON THE NAS, not by this call's answer.
sub _logout_form {
    my ($sid) = @_;
    return { logout => 1, sid => $sid };
}

sub logout {
    my ($self) = @_;
    return if !defined $self->{sid};
    local $@;
    eval { $self->_http('authLogout.cgi', _logout_form($self->{sid})) };
    $self->{sid} = undef;
    return;
}

# Log out when the object goes away, however it goes away.
#
# Many of this plugin's methods build an API object and have a `die` between the
# construction and the `logout` — a rollback that refuses, a resize the NAS
# rejects, a `path()` on a volume that is gone. Every one of those would leak a
# QTS session. Perl unwinds through DESTROY on the die path, so the object
# cleans up after itself rather than relying on twenty call sites to remember.
#
# Four things this must get right, all of them load-bearing:
#
#   1. **`$@` must survive.** Not on the die path — Perl 5.14 and later save and
#      restore `$@` around destructors called while a `die` propagates. It is
#      ORDINARY SCOPE EXIT that is exposed: this plugin is full of
#      `eval { ... }; if ($@) { ... }`, and an object released between the two
#      would replace the caller's error with whatever the logout did.
#   2. **Not during global destruction.** At interpreter shutdown the HTTP
#      client and its dependencies may already be gone.
#   3. **Not in a forked child.** PVE forks workers. A child inheriting this
#      object and logging out on exit would invalidate the PARENT's session,
#      which would look exactly like the NAS dropping sessions at random.
#   4. **Never die.** A die in DESTROY becomes a warning at best, and during
#      unwinding it can replace the real error.
sub DESTROY {
    my ($self) = @_;

    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
    return if !defined $self->{sid};
    return if ($self->{owner_pid} // 0) != $$;

    local $@;
    eval { $self->logout };
    return;
}

# ---------------------------------------------------------------------------
# Calls
# ---------------------------------------------------------------------------

# One call to one CGI.
#
# Returns a hash: `doc` and `result` on an answer, `transport` when the NAS was
# not reached or did not answer XML. **Nothing here decides success** — see note
# 2 at the top of this file. `result` is returned verbatim, including undef for
# a call whose answer carries no `<result>` at all.
#
# `_secret => 1` marks a call whose parameters include a credential. Such a call
# is POST-only: it must never fall back to a GET that would write the secret
# into the NAS's log.
sub call {
    my ($self, $cgi, %params) = @_;

    my $secret = delete $params{_secret} ? 1 : 0;
    my $method = delete $params{_method};

    $self->login;

    my $r = $self->_do_call($cgi, \%params, $method);

    # A session that has gone is the ordinary path, not an exception: QTS
    # expires one, and a storage nobody has touched for a while meets that on
    # the very next poll. `authPassed` 0 on a call that carried a sid is how it
    # says so.
    my $still_refused = 0;
    if (_says_not_logged_in($r)) {
        # Logged out rather than merely forgotten: if the session was in fact
        # alive and it was this CGI that could not see it, dropping the sid
        # here would leave it behind on the NAS.
        $self->logout;
        $self->login;
        $r = $self->_do_call($cgi, \%params, $method);
        # A sid issued a moment ago and STILL not recognised is not an expired
        # session. It is what a CGI that never read the POST body looks like:
        # the sid was in that body.
        $still_refused = _says_not_logged_in($r);
    }

    # THE GET FALLBACK, and the only thing that triggers it.
    #
    # It exists for a firmware whose CGIs ignore a POST body. It used to fire
    # on any answer without a `<result>` — and two perfectly healthy answers
    # have none: the NAS's own description, and a forked operation that is still
    # running. So an ordinary NAS was sent a GET, with the sid in its URL, on
    # every one of those calls, while this file promised it never happens.
    # Driving the plugin against a fake NAS that counts its GETs showed it.
    #
    # Now it takes the one symptom that actually means "the body was not read",
    # and it is never taken for a call that carries a secret.
    if ($still_refused && !$secret && ($method // 'POST') ne 'GET') {
        my $g = $self->_do_call($cgi, \%params, 'GET');
        if (!$g->{transport} && !_says_not_logged_in($g)) {
            _warn_once("$self->{storeid}:getfallback",
                "storage '$self->{storeid}': this NAS did not read the POST sent"
              . " to $cgi but did answer a GET. Falling back to GET for calls"
              . " that carry no credential. Calls that DO carry one are never"
              . " sent this way, so CHAP cannot be configured on this"
              . " firmware.\n");
            $r = $g;
        }
    }

    $r->{result} = text($r, 'result');
    $r->{cgi}    = $cgi;
    return $r;
}

# `authPassed` 0 on an answer that arrived: the NAS does not consider this
# request logged in.
sub _says_not_logged_in {
    my ($r) = @_;
    return 0 if ref $r ne 'HASH' || $r->{transport};
    my $passed = text($r, 'authPassed');
    return (defined $passed && $passed eq '0') ? 1 : 0;
}

sub _do_call {
    my ($self, $cgi, $params, $method) = @_;
    my %form = %$params;
    $form{sid} = $self->{sid} if defined $self->{sid};
    return $self->_http($cgi, \%form, method => $method);
}

my %warned;
sub _warn_once {
    my ($key, $msg) = @_;
    return if $warned{$key};
    $warned{$key} = 1;
    warn $msg;
    return;
}

sub clear_warnings {
    my ($storeid) = @_;
    delete $warned{$_} for grep { /\A\Q$storeid\E:/ } keys %warned;
    return;
}

# The form most callers want when 0 is the only success: succeed, or die with
# something an operator can act on.
#
# `_what` names the operation. Without it the message is a CGI and a func, which
# tells an operator nothing about what they were doing.
sub call_ok {
    my ($self, $cgi, %params) = @_;
    my $what = delete $params{_what} // $cgi;

    my $r = $self->call($cgi, %params);
    die "storage '$self->{storeid}': $what failed: $r->{transport}\n"
        if $r->{transport};

    my $result = $r->{result};
    die "storage '$self->{storeid}': $what: the NAS answered without a"
      . " <result>, so whether it happened is unknown. Check the NAS before"
      . " retrying.\n" if !defined $result;

    die "storage '$self->{storeid}': $what failed: " . error_text($result) . "\n"
        if $result !~ /\A-?\d+\z/ || $result != 0;

    return $r;
}

# The form for a call whose success is a non-negative IDENTIFIER: `add_target`,
# `add_lun`, `create_snapshot`. Returns the number.
sub call_id {
    my ($self, $cgi, %params) = @_;
    my $what = delete $params{_what} // $cgi;

    my $r = $self->call($cgi, %params);
    die "storage '$self->{storeid}': $what failed: $r->{transport}\n"
        if $r->{transport};

    my $result = $r->{result};
    die "storage '$self->{storeid}': $what: the NAS answered without a"
      . " <result>, so whether it happened is unknown. Check the NAS before"
      . " retrying.\n" if !defined $result || $result !~ /\A-?\d+\z/;

    die "storage '$self->{storeid}': $what failed: " . error_text($result) . "\n"
        if $result < 0;

    return $result + 0;
}

# ---------------------------------------------------------------------------
# Forked operations
# ---------------------------------------------------------------------------

# The CGI's NAME — `snapshot.cgi` — which is what `get_return` is keyed by.
#
# Callers hold the path they send requests to, `disk/snapshot.cgi`, and for as
# long as that went out as `cginame` unchanged the code disagreed with its own
# description of the call at the top of this file. Which spelling QTS wants is
# unmeasured; the name is what the parameter is called after, and a wrong one
# here is a clone or a rollback whose result is never collected.
sub cgi_name {
    my ($cgi) = @_;
    return undef if !defined $cgi;
    my ($name) = $cgi =~ m{([^/]+)\z};
    return $name;
}

# See note 4 at the top of this file. `get_return` is keyed by CGI NAME, so this
# can only be correct while one forked operation per CGI is in flight — the
# plugin holds PVE's cluster-wide storage lock around every caller for exactly
# that reason.
#
# Returns the final `<result>`, or dies. A timeout is NOT reported as a failure:
# the NAS is still working, and a caller that retried would start a second
# clone.
sub wait_for_fork {
    my ($self, $cgi, %opt) = @_;
    my $limit = $opt{timeout} // 1800;
    my $what  = $opt{what} // 'the operation';
    my $name  = cgi_name($cgi);

    my $t0 = time;
    my $last;
    while (time - $t0 < $limit) {
        select(undef, undef, undef, 1);

        my $r = $self->call('disk/snapshot.cgi',
            func => 'get_return', cginame => $name);

        # A transport failure mid-wait is not an answer about the operation.
        # Keep waiting: the NAS being briefly unreachable while it clones is
        # ordinary, and concluding failure here would invite a retry that
        # duplicates the work.
        if ($r->{transport}) { $last = $r->{transport}; next }

        my $processing = text($r, 'processing');
        next if defined $processing && $processing eq '1';

        my $result = text($r, 'result');
        next if !defined $result;
        return $result + 0;
    }

    die "storage '$self->{storeid}': $what has been running on the NAS for"
      . " ${limit}s and has not reported a result"
      . (defined $last ? " (last transport error: $last)" : '')
      . ". It has NOT failed: check Storage & Snapshots on the NAS before"
      . " retrying, because retrying may duplicate it.\n";
}

# ---------------------------------------------------------------------------
# What this NAS is, and what it can hold
# ---------------------------------------------------------------------------

# `authLogin.cgi` with a sid and no other parameter answers with the NAS's own
# description: model, firmware, and — this is the part nothing else provides —
# `storage_v2` and `is_zfs`, which are how QTS and QuTS hero are told apart.
# How the three are told apart:
#
#   <storage_v2> absent or 0            legacy Storage Manager
#   <storage_v2>1</storage_v2>, is_zfs 0  Storage Manager V2 on LVM  (QTS)
#   <storage_v2>1</storage_v2>, is_zfs 1  ZFS                        (QuTS hero)
#
# Cached for the life of the object: it is a property of the firmware, and the
# health path must not fetch it every ten seconds.
sub sysinfo {
    my ($self) = @_;
    return $self->{sysinfo} if $self->{sysinfo};

    my $r = $self->call('authLogin.cgi');
    return {} if $r->{transport} || !$r->{doc};

    my %i = (
        model      => text($r, 'displayModelName') // text($r, 'modelName'),
        platform   => text($r, 'platform'),
        hostname   => text($r, 'hostname'),
        firmware   => text($r, 'version'),
        build      => text($r, 'build'),
        storage_v2 => text($r, 'storage_v2'),
        is_zfs     => text($r, 'is_zfs'),
    );

    $self->{sysinfo} = \%i;
    return $self->{sysinfo};
}

# QuTS hero, which matters for more than a label: the instant clone of Storage
# clone exists only there, and it is the difference between a linked clone that
# is instant and one that copies the whole disk.
sub is_zfs {
    my ($self) = @_;
    my $i = $self->sysinfo;
    return (($i->{is_zfs} // '') eq '1') ? 1 : 0;
}

# Storage Manager V2. The legacy CGI surface is a different set of calls
# entirely, and this plugin implements V2 only — so this is a refusal, not a
# branch.
sub is_storage_v2 {
    my ($self) = @_;
    my $i = $self->sysinfo;
    return (($i->{storage_v2} // '') eq '1') ? 1 : 0;
}

# The iSCSI portal's own description, which carries THIS NAS's ceilings.
#
# `maxLUNCnt` and `maxTargetCnt` are read rather than assumed: they vary by
# model, and the LUN ceiling is the real limit of a storage where one VM disk is
# one LUN — a NAS with 40 TB free and every LUN slot taken is full, and
# `pvesm status` has no way to say so.
sub portal_info {
    my ($self) = @_;
    return $self->{portal_info} if $self->{portal_info};

    my $r = $self->call('disk/iscsi_portal_setting.cgi',
        func => 'extra_get', iSCSI_portal => 1);
    return {} if $r->{transport};

    my %p = (
        max_luns        => _int(text($r, 'maxLUNCnt')),
        max_targets     => _int(text($r, 'maxTargetCnt')),
        max_lun_size_tb => _int(text($r, 'maxISCSILunSize')),
        service_enabled => text($r, 'bServiceEnable'),
        service_port    => _int(text($r, 'servicePort')),
        iqn_prefix      => text($r, 'targetIQNPrefix'),
        iqn_postfix     => text($r, 'targetIQNPostfix'),
    );

    $self->{portal_info} = \%p;
    return $self->{portal_info};
}

# undef for a ceiling the NAS did not report — and undef must NOT be read as
# "no limit": it means "this NAS did not say", so a caller can only stop
# guarding, never conclude there is room.
sub limits {
    my ($self) = @_;
    my $p = $self->portal_info;
    return {
        luns    => $p->{max_luns},
        targets => $p->{max_targets},
    };
}

sub _int {
    my ($v) = @_;
    return undef if !defined $v || $v !~ /\A\d+\z/;
    return $v + 0;
}

1;
