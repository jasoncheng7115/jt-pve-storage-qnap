package PVE::Storage::Custom::QNAPSANPlugin;

# Proxmox VE storage plugin for QNAP QTS / QuTS hero over iSCSI.
#
# One VM disk is one thin LUN on the NAS. No LVM layer and no shared LUN carved
# up locally, so the NAS's own snapshots, clones and capacity act on the unit an
# operator thinks about.
#
# Everything array-facing lives in the QNAP::* modules. The decisions there that
# shape THIS file:
#
#   * A device is never identified by its path. The LUN's number within a target
#     is reused, so `.../-lun-2` resolves to a different disk after an ordinary
#     unmap-and-remap. `path()` returns the dm-uuid link and every activation
#     confirms the device against the kernel's WWID, which must equal the
#     `LUNNAA` the NAS reports.
#
#   * **QTS allocates in whole GiB.** `add_lun` takes a whole number and one
#     unit of it is a GiB. PVE allocates in KiB, so every
#     size is rounded UP and `volume_size_info` answers with what the NAS
#     actually has. A volume that reports less than the VM configuration claims
#     is one QEMU refuses to start.
#
#   * **A clone and a rollback FORK on the NAS, and their result is collected
#     through a channel keyed by CGI NAME rather than by job.** Two of them in
#     flight at once cannot be told apart. So only one runs on a NAS at a time,
#     across the whole cluster — see `_fork_claim`, which is not an optimisation
#     and not defensive coding.
#
#   * **A clone exists on QuTS hero only.** There it is instant. On QTS the same
#     call copies the whole disk, and PVE runs a storage-side clone under a lock
#     it aborts after 60 seconds, so this plugin does not offer one on QTS: a
#     template there is cloned by PVE as a full clone.
#
#   * **This plugin does not manage per-initiator access.** It sets CHAP on the
#     target's default policy entry and nothing narrower, so CHAP is the access
#     control it relies on.

use strict;
use warnings;

use PVE::Tools qw(run_command);
use PVE::INotify;
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use PVE::Storage::Custom::QNAP::API;
use PVE::Storage::Custom::QNAP::LUN;
use PVE::Storage::Custom::QNAP::Target;
use PVE::Storage::Custom::QNAP::Naming;
use PVE::Storage::Custom::QNAP::ISCSI;
use PVE::Storage::Custom::QNAP::Multipath;
use PVE::Storage::Custom::QNAP::WwidState;
use PVE::Storage::Custom::QNAP::Health;
use PVE::Storage::Custom::QNAP::Deferred;

use base qw(PVE::Storage::Plugin);

my $NAMING = 'PVE::Storage::Custom::QNAP::Naming';
my $MP     = 'PVE::Storage::Custom::QNAP::Multipath';
my $ISCSI  = 'PVE::Storage::Custom::QNAP::ISCSI';
my $HEALTH = 'PVE::Storage::Custom::QNAP::Health';
my $LUNMOD = 'PVE::Storage::Custom::QNAP::LUN';

# ---------------------------------------------------------------------------
# API version
# ---------------------------------------------------------------------------

# Negotiated, never hardcoded. PVE treats the two directions very differently:
# claiming HIGHER than the node's APIVER makes PVE reject the plugin outright
# and every storage of this type disappears from the node; claiming lower but
# in range only produces a warning on every load of PVE::Storage. PVE 9 raised
# APIVER twice inside its 9.1 point releases, so a fixed number is wrong
# somewhere by construction.
use constant APIVERSION_MIN => 10;
use constant APIVERSION_MAX => 15;   # get_identity. Raise only after implementing the delta.

sub api {
    my $ver = eval { PVE::Storage::APIVER() };
    # perl -c and the unit tests have no PVE::Storage loaded.
    return APIVERSION_MIN if !defined $ver;
    $ver = APIVERSION_MAX if $ver > APIVERSION_MAX;
    $ver = APIVERSION_MIN if $ver < APIVERSION_MIN;
    return $ver;
}

sub type { return 'qnapsan' }

sub plugindata {
    return {
        content => [ { images => 1, rootdir => 1 }, { images => 1 } ],
        format  => [ { raw => 1 }, 'raw' ],

        # WITHOUT THIS THE NAS PASSWORD IS WRITTEN INTO /etc/pve/storage.cfg.
        #
        # That file is `root:www-data 0640`, and — worse — a property PVE does
        # not know is a secret is returned by `GET /storage/<id>` to any user
        # holding Datastore.Audit. A read-only auditor would have been handed an
        # administrator credential for the NAS.
        #
        # `sensitive_properties` falls back to a hardcoded list —
        # `encryption-key keyring master-pubkey password` — when a plugin
        # declares nothing, and none of these names are in it. So omitting this
        # fails silently and in the least safe direction.
        'sensitive-properties' => {
            'qnap-password'             => 1,
            'qnap-chap-password'        => 1,
            'qnap-mutual-chap-password' => 1,
        },
    };
}

# ---------------------------------------------------------------------------
# The credential store
# ---------------------------------------------------------------------------
#
# /etc/pve/priv/storage/<storeid>.qnap, which is where PVE's own CIFS, PBS and
# ESXi plugins keep theirs. Under /etc/pve so it replicates to every node — a
# shared storage is used from all of them — and inside priv, which the cluster
# filesystem serves to root only.

# A variable rather than `use constant`, and deliberately: a constant is folded
# into its call sites at compile time, so a test cannot point the store at a
# temporary directory — and a credential store with no test is not something to
# ship. Nothing in production ever assigns to this.
our $CRED_DIR = '/etc/pve/priv/storage';

my %CRED_KEYS = (
    'password'             => 'qnap-password',
    'chap-password'        => 'qnap-chap-password',
    'mutual-chap-password' => 'qnap-mutual-chap-password',
);

sub _cred_file {
    my ($class, $storeid) = @_;
    # Sanitised and untainted by Naming::filename_component — a storage id
    # carrying `../` must not choose the file, and under pvedaemon's -T an
    # un-untainted one cannot be written to at all.
    my $safe = PVE::Storage::Custom::QNAP::Naming::filename_component($storeid)
        or return undef;
    return "$CRED_DIR/$safe.qnap";
}

sub _read_creds {
    my ($class, $storeid) = @_;
    my $file = $class->_cred_file($storeid) or return {};
    my %c;
    open(my $fh, '<', $file) or return {};
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /\A\s*(?:#|\z)/;
        my ($k, $v) = split(/=/, $line, 2);
        next if !defined $k || !defined $v;
        # Only keys this plugin writes. A stray line is not an instruction.
        next if !exists $CRED_KEYS{$k};
        $c{$k} = $v;
    }
    close($fh);
    return \%c;
}

sub _write_creds {
    my ($class, $storeid, $creds) = @_;
    my $file = $class->_cred_file($storeid)
        or die "storage '$storeid': the storage id cannot be used in a filename\n";

    # Nothing to keep: remove the file rather than leaving an empty one, so
    # "no credential stored" and "an empty credential" are not the same state.
    my %keep = map { $_ => $creds->{$_} }
               grep { defined $creds->{$_} && length $creds->{$_} } keys %$creds;
    if (!%keep) {
        unlink $file;
        return;
    }

    mkdir $CRED_DIR;
    my $body = join('', map { "$_=$keep{$_}\n" } sort keys %keep);
    ## no critic (ValuesAndExpressions::ProhibitLeadingZeros)
    # 0600 is a file mode and octal is the only readable way to write one.
    PVE::Tools::file_set_contents($file, $body, 0600);
    return;
}

sub _delete_creds {
    my ($class, $storeid) = @_;
    my $file = $class->_cred_file($storeid) or return;
    unlink $file;
    return;
}

# The credentials for one storage: the private file first, then the config, so a
# storage written by a version that did not know about the private file keeps
# working. Anything found in the config is reported once, with the command that
# moves it.
sub _creds {
    my ($class, $storeid, $scfg) = @_;
    my $c = $class->_read_creds($storeid);

    my $from_config = 0;
    for my $k (keys %CRED_KEYS) {
        next if defined $c->{$k} && length $c->{$k};
        my $v = $scfg->{ $CRED_KEYS{$k} };
        next if !defined $v || !length $v;
        $c->{$k} = $v;
        $from_config = 1 if $k eq 'password';
    }

    PVE::Storage::Custom::QNAP::Health::warn_once_for($storeid, 'plaintext-cred',
        "storage '$storeid': the NAS credential is still stored in"
      . " /etc/pve/storage.cfg, where it is readable by www-data and returned"
      . " by the API to any user with Datastore.Audit. Run"
      . " `pvesm set $storeid --qnap-password <password>` once to move it into"
      . " /etc/pve/priv, which is root-only.\n") if $from_config;

    return $c;
}

# PVE consults this in parse_config and forces `shared 1`. A LUN on a NAS is
# reachable from every node by construction.
push @PVE::Storage::Plugin::SHARED_STORAGE, 'qnapsan';

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

sub properties {
    return {
        'qnap-portal' => {
            description => "NAS management address. A comma-separated list is"
                         . " tried in order and rotated on failure.",
            type => 'string',
        },
        'qnap-port' => {
            description => "Management port. Defaults to 443, the HTTPS admin"
                         . " port; QTS's HTTP admin port is usually 8080.",
            type => 'integer', minimum => 1, maximum => 65535, default => 443,
        },
        'qnap-scheme' => {
            description => "http or https for the management API. https is the"
                         . " default and the only one that does not put the"
                         . " password on the wire in clear.",
            type => 'string', enum => [ 'https', 'http' ], default => 'https',
        },
        'qnap-username' => {
            description => "NAS account. It must be an administrator: the"
                         . " Storage Manager and iSCSI CGIs are"
                         . " administrator-only. See docs/QNAP-ACCOUNT.md.",
            type => 'string',
        },
        'qnap-password' => {
            description => "Password for the NAS account.",
            type => 'string',
        },
        'qnap-pool' => {
            description => "Storage pool ID that holds the LUNs: the number"
                         . " Storage & Snapshots shows, e.g. 1.",
            type => 'integer', minimum => 1,
        },
        'qnap-protocol' => {
            description => "SAN protocol. Only iSCSI is implemented; the option"
                         . " exists so that adding another one later does not"
                         . " require a new storage type.",
            type => 'string', enum => [ 'iscsi' ], default => 'iscsi',
        },
        'qnap-target-mode' => {
            description => "'shared' puts every LUN of this storage on one"
                         . " target, which is the default. 'per-volume'"
                         . " isolates each disk but consumes one target per"
                         . " disk, and a NAS allows no more targets than LUNs.",
            type => 'string', enum => [ 'shared', 'per-volume' ], default => 'shared',
        },
        'qnap-chap-username' => {
            description => "CHAP username. This plugin does not set up"
                         . " per-initiator access on the target, so CHAP is the"
                         . " access control it relies on: set it unless the"
                         . " NAS is on a storage-only network.",
            type => 'string', optional => 1,
        },
        'qnap-chap-password' => {
            description => "CHAP password.",
            type => 'string', optional => 1,
        },
        'qnap-mutual-chap-username' => {
            description => "Mutual CHAP username. Authenticates the NAS to the"
                         . " node. Requires qnap-chap-username as well.",
            type => 'string', optional => 1,
        },
        'qnap-mutual-chap-password' => {
            description => "Mutual CHAP password.",
            type => 'string', optional => 1,
        },
        'qnap-ssl-verify' => {
            description => "Verify the NAS certificate. Off by default because"
                         . " QTS ships a self-signed one and a default nobody"
                         . " can use protects nobody.",
            type => 'boolean', default => 0,
        },
        'qnap-tls-ca' => {
            description => "CA certificate file, for qnap-ssl-verify.",
            type => 'string', optional => 1,
        },
        'qnap-data-portals' => {
            description => "iSCSI data addresses, comma-separated. Defaults to"
                         . " the management address. Two portals on one subnet"
                         . " need iface binding to be genuinely redundant.",
            type => 'string', optional => 1,
        },
        'qnap-status-timeout' => {
            description => "Timeout in seconds for the health path, which runs"
                         . " every few seconds per node.",
            type => 'integer', minimum => 1, maximum => 60, default => 5,
        },
        'qnap-min-free' => {
            description => "Refuse to allocate when the pool has less than this"
                         . " many GiB free. Thin LUNs can overcommit a pool,"
                         . " and a full pool affects every VM on it.",
            type => 'integer', minimum => 0, default => 10,
        },
        'qnap-no-path-retry' => {
            description => "multipath no_path_retry. A number, never 'queue':"
                         . " queueing turns the loss of every path into a hang"
                         . " nothing can recover from.",
            type => 'integer', minimum => 1, maximum => 200, default => 18,
        },
        'qnap-sector-size' => {
            description => "Logical sector size for new LUNs. QTS offers 512"
                         . " and 4096; 512 is the safe default because some"
                         . " guest operating systems will not boot from 4Kn.",
            type => 'integer', enum => [ 512, 4096 ], default => 512,
        },
        'qnap-thin' => {
            description => "Create thin LUNs. On by default: a thick LUN"
                         . " reserves its whole capacity at creation, which"
                         . " makes over-subscription impossible.",
            type => 'boolean', default => 1,
        },
    };
}

sub options {
    return {
        'qnap-portal'   => { fixed => 1 },
        'qnap-username' => { fixed => 1 },
        # OPTIONAL, and that is not a relaxation.
        #
        # `extract_sensitive_params` removes every sensitive property from the
        # parameters BEFORE `check_config` validates them (API2/Storage/Config.pm
        # does them in that order). So by the time PVE checks whether a required
        # option is present, this one is already gone — and `pvesm add` fails
        # with "missing value for required option 'qnap-password'" for a password
        # that WAS supplied on the command line. PVE's own CIFS plugin declares
        # its password optional for exactly this reason.
        #
        # PVE cannot validate what it never sees, so on_add_hook does it: it
        # refuses a missing password itself, naming the option.
        'qnap-password' => { optional => 1 },
        'qnap-pool'     => { fixed => 1 },
        'qnap-port'     => { optional => 1 },
        'qnap-scheme'   => { optional => 1 },
        'qnap-protocol' => { optional => 1 },
        'qnap-target-mode'   => { optional => 1 },
        'qnap-chap-username' => { optional => 1 },
        'qnap-chap-password' => { optional => 1 },
        'qnap-mutual-chap-username' => { optional => 1 },
        'qnap-mutual-chap-password' => { optional => 1 },
        'qnap-ssl-verify'    => { optional => 1 },
        'qnap-tls-ca'        => { optional => 1 },
        'qnap-data-portals'  => { optional => 1 },
        'qnap-status-timeout' => { optional => 1 },
        'qnap-min-free'      => { optional => 1 },
        'qnap-no-path-retry' => { optional => 1 },
        'qnap-sector-size'   => { optional => 1 },
        'qnap-thin'          => { optional => 1 },
        nodes    => { optional => 1 },
        shared   => { optional => 1 },
        disable  => { optional => 1 },
        content  => { optional => 1 },
        format   => { optional => 1 },
        bwlimit  => { optional => 1 },
    };
}

# ---------------------------------------------------------------------------
# Clients
# ---------------------------------------------------------------------------

sub _api {
    my ($class, $storeid, $scfg, %opt) = @_;
    # The credentials never come from $scfg directly any more: they live in
    # /etc/pve/priv, and $scfg is only the fallback for a storage written by a
    # version that did not know that. A hook that has just been handed a new
    # password passes it in as `creds`, because it is not on disk yet.
    my $c = $opt{creds} // $class->_creds($storeid, $scfg);

    my $scheme = $scfg->{'qnap-scheme'} // 'https';
    PVE::Storage::Custom::QNAP::Health::warn_once_for($storeid, 'plaintext-http',
        "storage '$storeid': qnap-scheme is http, so the NAS password and any"
      . " CHAP secret travel over the network in clear on every call. Use"
      . " https unless the management network is genuinely private.\n")
        if $scheme eq 'http';

    return PVE::Storage::Custom::QNAP::API->new(
        portals    => $scfg->{'qnap-portal'},
        port       => $scfg->{'qnap-port'},
        scheme     => $scheme,
        username   => $scfg->{'qnap-username'},
        password   => $c->{password},
        ssl_verify => $scfg->{'qnap-ssl-verify'},
        tls_ca     => $scfg->{'qnap-tls-ca'},
        storeid    => $storeid,
        # The health path gets the short timeout: the next poll is the retry,
        # and PVE runs status() for every storage in sequence.
        status     => $opt{status},
        timeout    => $opt{status} ? ($scfg->{'qnap-status-timeout'} // 5) : undef,
    );
}

sub _lun { return PVE::Storage::Custom::QNAP::LUN->new($_[1]) }
sub _tgt { return PVE::Storage::Custom::QNAP::Target->new($_[1]) }
sub _state { return PVE::Storage::Custom::QNAP::WwidState->new($_[1]) }

sub _pool { return $_[1]->{'qnap-pool'} }

sub _data_portals {
    my ($class, $scfg) = @_;
    my $p = $scfg->{'qnap-data-portals'} // $scfg->{'qnap-portal'};
    return [ grep { length } split /\s*,\s*/, ($p // '') ];
}

# One target for the whole storage in `shared` mode.
#
# Looked up by NAME, never by an IQN derived from anything local: QTS builds the
# IQN from a prefix that embeds the NAS's model and hostname AS THEY WERE when
# the target was created, so a renamed NAS carries targets with two different
# prefixes and a plugin that derived the IQN would not recognise its own.
sub _target_name {
    my ($class, $storeid, $scfg, $volname) = @_;
    return PVE::Storage::Custom::QNAP::Naming::target_name($storeid)
        if ($scfg->{'qnap-target-mode'} // 'shared') eq 'shared';
    my $leaf = PVE::Storage::Custom::QNAP::Naming::leaf_of($volname);
    return PVE::Storage::Custom::QNAP::Naming::target_name($storeid, $leaf);
}

# The CHAP settings, with the secrets from the credential store.
#
# They must NOT be read from $scfg: the passwords are sensitive properties, so
# PVE strips them from the configuration and `$scfg->{'qnap-chap-password'}` is
# undef on any storage added by a version that declares them. Both CHAP call
# sites read from here, because a `// ''` fallback at either of them would write
# an EMPTY secret — authentication that appears configured and protects nothing.
sub _chap {
    my ($class, $storeid, $scfg, $creds) = @_;
    $creds //= $class->_creds($storeid, $scfg);
    return (
        chap_user            => $scfg->{'qnap-chap-username'},
        chap_password        => $creds->{'chap-password'},
        mutual_chap_user     => $scfg->{'qnap-mutual-chap-username'},
        mutual_chap_password => $creds->{'mutual-chap-password'},
    );
}

# `$creds` is for the one caller that holds secrets which are not on disk yet.
#
# on_add_hook writes the credential store LAST, after every check that could
# refuse the storage — so while it is creating the target, the CHAP secret the
# operator just typed exists only in the hook's arguments. Reading the store
# here found nothing, and the "username with no secret" guard then refused
# every `pvesm add` that set CHAP: the configuration this plugin recommends.
# Found by driving the hook against a fake NAS; no unit test reached it.
sub _ensure_target {
    my ($class, $api, $storeid, $scfg, $volname, $creds) = @_;
    my $tgt = $class->_tgt($api);
    return $tgt->ensure(
        name => $class->_target_name($storeid, $scfg, $volname),
        $class->_chap($storeid, $scfg, $creds),
    );
}

# ONE FORKED OPERATION AT A TIME, CLUSTER-WIDE.
#
# `clone_qsnapshot` and `recover_snapshot` both answer `<fork>1</fork>` and
# leave their real result to be collected from
# `snapshot.cgi?func=get_return&cginame=snapshot.cgi`. **That channel is keyed
# by the CGI's name, not by a job id.** Two started at the same moment from two
# nodes are indistinguishable, and whichever asks first may collect the other's
# answer, so one of them would report someone else's success or someone else's
# failure.
#
# So only one is ever in flight, and the only scope that covers is the cluster.
#
# IT USED TO BE THE CLUSTER STORAGE LOCK, HELD FOR THE WHOLE OPERATION, AND
# THAT WAS WRONG. Proxmox VE aborts whatever runs under a cfs lock after 60
# seconds (`cfs_lock` in PVE::Cluster arms an alarm), and a rollback on QTS
# takes as long as writing the disk back. The rollback was therefore cut off at
# one minute with the NAS still overwriting the LUN, the guest left locked, and
# nothing to say the disk was half restored.
#
# What is held now is a CLAIM: a small file in /etc/pve/priv, which every node
# sees. The storage lock is taken only for the moment it takes to look for a
# claim and write one, and the operation itself runs with no time limit but its
# own. The claim is removed when the operation returns, whatever it returns.
#
# A claim nobody removed (the task was killed, the node went down) stands for
# FORK_CLAIM_MAX_AGE and is then ignored. Until then it REFUSES, because the
# NAS may well still be working: a claim that cannot be vouched for is not read
# as "free". The message names the file, for the operator who knows better.
#
# `clone_image` does not write a claim. PVE's `vdisk_clone` holds the storage
# lock around the whole of it, a clone exists only on QuTS hero where it is
# instant, and taking a cfs storage lock twice in one process deadlocks. It
# READS the claim, so a clone does not start while a rollback is running, and a
# rollback cannot write its claim while a clone holds the lock.
our $FORK_DIR = '/etc/pve/priv/storage';

# The longest a rollback is waited for, plus slack for clocks that disagree.
use constant FORK_CLAIM_MAX_AGE => 1800 + 300;

sub _fork_file {
    my ($class, $storeid) = @_;
    (my $safe = $storeid) =~ s/[^A-Za-z0-9_.-]/_/g;
    return "$FORK_DIR/$safe.qnap-busy";
}

# The claim in force, as a hash with a `text` describing it, or undef when
# there is none. A claim that cannot be read IS one: see above.
sub _fork_busy {
    my ($class, $storeid) = @_;

    my $file = $class->_fork_file($storeid);
    return undef if !-e $file;

    my $raw = eval { PVE::Tools::file_get_contents($file) };
    my %c = map { /\A(\w+)=(.*)\z/ ? ($1 => $2) : () } split /\n/, ($raw // '');

    return { text => "a claim that cannot be read ($file)", file => $file }
        if !defined $c{time} || $c{time} !~ /\A\d+\z/;

    my $age = time - $c{time};
    if ($age > FORK_CLAIM_MAX_AGE) {
        warn "storage '$storeid': ignoring a claim left by node "
           . ($c{node} // '?') . " " . int($age / 60) . " minutes ago ("
           . ($c{what} // '?') . "). Whatever made it did not finish"
           . " cleanly.\n";
        return undef;
    }

    return {
        %c,
        file => $file,
        text => ($c{what} // 'an operation') . ", started on node "
              . ($c{node} // '?') . " at " . scalar(localtime($c{time})),
    };
}

sub _fork_claim {
    my ($class, $storeid, $scfg, $what) = @_;

    return $class->cluster_lock_storage($storeid, $scfg->{shared}, undef, sub {
        my $busy = $class->_fork_busy($storeid);
        die "storage '$storeid': $what cannot start, because this plugin runs"
          . " one rollback or clone on a NAS at a time and another is still"
          . " running: $busy->{text}. Wait for it to finish. If that task was"
          . " killed and the NAS is idle, remove $busy->{file}.\n" if $busy;

        mkdir $FORK_DIR;
        my $body = "node=" . PVE::INotify::nodename() . "\npid=$$\ntime=" . time
                 . "\nwhat=$what\n";
        ## no critic (ValuesAndExpressions::ProhibitLeadingZeros)
        # A file mode, as in `_write_creds`.
        PVE::Tools::file_set_contents($class->_fork_file($storeid), $body, 0600);
        return 1;
    });
}

# Only the claim this process wrote. One left by somebody else is theirs.
sub _fork_release {
    my ($class, $storeid) = @_;

    my $file = $class->_fork_file($storeid);
    my $raw = eval { PVE::Tools::file_get_contents($file) } // '';
    my $mine = "node=" . PVE::INotify::nodename() . "\npid=$$\n";
    unlink $file if index($raw, $mine) == 0;
    return;
}

# ---------------------------------------------------------------------------
# What kind of NAS is behind a storage
# ---------------------------------------------------------------------------

# QuTS hero or QTS, as 1 / 0 / undef. `volume_has_feature` needs it and is
# handed no session, so the answer is kept per node and refreshed once a day.
#
# THREE-VALUED, and undef is not "QTS" and not "QuTS hero": it means the NAS
# could not be asked and nothing is on file. The one caller treats that as "do
# not offer it", which is the answer that cannot start something the NAS will
# then be unable to finish.
our $STATE_DIR = '/var/lib/jt-pve-storage-qnap';
use constant NAS_KIND_TTL => 86400;

sub _kind_file {
    my ($class, $storeid) = @_;
    (my $safe = $storeid) =~ s/[^A-Za-z0-9_.-]/_/g;
    return "$STATE_DIR/$safe.nas";
}

# Called wherever a session already exists, so the file is usually fresh and
# `_nas_is_zfs` usually asks nobody.
sub _remember_nas_kind {
    my ($class, $storeid, $api) = @_;

    my $info = eval { $api->sysinfo } // {};
    # A NAS that did not describe itself has told us nothing. Writing "QTS" for
    # it would turn a failed request into a decision.
    return undef if !defined $info->{storage_v2};

    my $kind = $api->is_zfs ? 'zfs' : 'lvm';
    eval {
        mkdir $STATE_DIR;
        PVE::Tools::file_set_contents($class->_kind_file($storeid), "$kind\n");
    };
    return $kind;
}

sub _nas_is_zfs {
    my ($class, $storeid, $scfg) = @_;

    my $file = $class->_kind_file($storeid);
    my $read = sub {
        my $raw = eval { PVE::Tools::file_get_contents($file) } // '';
        return $raw =~ /\A(zfs|lvm)\s*\z/ ? $1 : undef;
    };

    my $kind;
    my @st = stat($file);
    $kind = $read->() if @st && time - $st[9] < NAS_KIND_TTL;

    if (!defined $kind) {
        # The short timeout: this is asked from a feature check, which the web
        # interface makes while somebody is waiting on a dialog.
        $kind = eval {
            my $api = $class->_api($storeid, $scfg, status => 1);
            my $k = $class->_remember_nas_kind($storeid, $api);
            eval { $api->logout };
            $k;
        };
        # Could not ask. What was true yesterday is better than nothing: a NAS
        # does not change its operating system without being reinstalled.
        $kind //= $read->();
    }

    return undef if !defined $kind;
    return $kind eq 'zfs' ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------

# The only place a constraint on the DATA can be enforced rather than discovered
# later. Everything refused here would otherwise surface at the first
# allocation, or at the first snapshot, or never.
sub on_add_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;

    # The credentials arrive HERE, not in $scfg: PVE strips every property named
    # in `sensitive-properties` out of the config before writing it.
    my %creds = (
        'password'             => $sensitive{'qnap-password'},
        'chap-password'        => $sensitive{'qnap-chap-password'},
        'mutual-chap-password' => $sensitive{'qnap-mutual-chap-password'},
    );
    die "storage '$storeid': qnap-password is required\n"
        if !defined $creds{password} || !length $creds{password};

    $class->_assert_chap_pairs($storeid, $scfg, \%creds);

    # A storage id that folds onto another one's prefix is indistinguishable
    # from it on the NAS: each would list the other's disks and the ownership
    # gate would pass for both. It cannot be fixed in a name, so it is refused
    # at the moment the data is created.
    my $cfg = eval { PVE::Storage::config() };
    if ($cfg && ref $cfg->{ids} eq 'HASH') {
        for my $other (sort keys %{ $cfg->{ids} }) {
            next if $other eq $storeid;
            my $o = $cfg->{ids}{$other};
            next if ($o->{type} // '') ne 'qnapsan';
            next if !PVE::Storage::Custom::QNAP::Naming::fold_collides_with($storeid, $other);
            # Only a collision on the SAME NAS actually collides.
            next if ($o->{'qnap-portal'} // '') ne ($scfg->{'qnap-portal'} // '');
            die "storage '$storeid' cannot be added: its name folds to the same"
              . " LUN prefix as the existing storage '$other' on the same NAS."
              . " Each would list and could delete the other's disks. Choose a"
              . " name that differs in its first "
              . PVE::Storage::Custom::QNAP::Naming::MAX_STOREID_FOLD
              . " characters by more than case.\n";
        }
    }

    my $api = $class->_api($storeid, $scfg, creds => \%creds);
    PVE::Storage::Custom::QNAP::Health::assert_usable($api,
        pool_id => $class->_pool($scfg));
    $class->_remember_nas_kind($storeid, $api);

    # Create the storage's target now rather than at the first allocation, so
    # that a NAS which refuses it — the target ceiling, a name QTS will not take
    # — says so while the operator is still adding the storage.
    my $t = $class->_ensure_target($api, $storeid, $scfg, undef, \%creds);
    print "storage '$storeid': using iSCSI target '$t->{name}' ($t->{iqn}).\n";

    warn "storage '$storeid': no CHAP is configured. This plugin does not set"
       . " up per-initiator access on the target, so CHAP is what restricts who"
       . " can attach these disks through $t->{iqn}. Set qnap-chap-username and"
       . " qnap-chap-password unless this NAS is on a storage-only network.\n"
        if !defined $scfg->{'qnap-chap-username'}
        || !length $scfg->{'qnap-chap-username'};

    # Best effort, and it says nothing when it could not ask: "could not list"
    # must not become "somebody else's disks are there".
    my $luns = eval { $class->_lun($api)->list };
    my $msg  = $class->_existing_volumes_warning($storeid, $luns);
    warn $msg if defined $msg;

    $api->logout;

    # LAST. Every check that can refuse has passed, so nothing is written for a
    # storage that is not going to exist — the same ordering rule the
    # activate_storage path follows.
    $class->_write_creds($storeid, \%creds);
    return;
}

# IS SOMETHING ELSE ALREADY USING THIS STORAGE'S NAMES ON THE NAS?
#
# The fold check in on_add_hook refuses two storages in ONE cluster that would
# share a LUN prefix. It reads the local storage.cfg, so it cannot see a second
# Proxmox VE cluster attached to the same NAS — and two clusters that both call
# their storage `qnap1` share every LUN name. Each lists the other's disks, the
# ownership gate passes for both, and `qm destroy` on one can delete from the
# other. The related Dell plugin was asked about exactly this by an operator
# running it.
#
# So the NAS is asked, at the one moment the storage id is still free to change.
#
# A WARNING, never a refusal. Re-adding a storage that already has disks is
# entirely legitimate — after a reinstall, or after `pvesm remove` — and nothing
# here can tell that from a collision. Only the operator can, so the message
# spells out both readings.
#
# Returns the message, or undef when there is nothing to say. A listing that
# is not one (the caller could not ask) is undef too.
sub _existing_volumes_warning {
    my ($class, $storeid, $luns) = @_;
    return undef if ref $luns ne 'ARRAY';

    my @names = sort grep {
        PVE::Storage::Custom::QNAP::Naming::is_pve_managed_volume($_, $storeid)
    } map { $_->{LUNName} // '' } @$luns;
    return undef if !@names;

    my $prefix = PVE::Storage::Custom::QNAP::Naming::prefix_for($storeid);
    my $shown = join(', ', @names[0 .. ($#names > 4 ? 4 : $#names)]);
    $shown .= ', and ' . (scalar(@names) - 5) . ' more' if @names > 5;

    return "storage '$storeid': the NAS already has " . scalar(@names)
      . " LUN(s) under this storage's prefix '$prefix-': $shown\n"
      . "  If this storage was added here before, those are its own disks and"
      . " this is expected.\n"
      . "  If they belong to a DIFFERENT Proxmox VE cluster using the same"
      . " storage id, the two clusters now share one set of LUN names on this"
      . " NAS: each will list the other's disks, and deleting a disk from one"
      . " can delete it from the other. Remove this storage and add it under"
      . " an id the other cluster does not use.\n";
}

# The target belongs to the STORAGE, not to any one disk, so it is removed when
# the storage is — not by free_image, which would tear it out from under every
# other disk on the same storage.
sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    # The credential outlives the storage unless something removes it, and a
    # stored NAS password belonging to a storage that no longer exists is the
    # worst of both: nothing uses it and nobody is looking after it. So it goes
    # whatever happens below — including when the NAS cannot be reached, which
    # is the path an early return would leave it on.
    my $cleanup = PVE::Storage::Custom::QNAP::Deferred->new(sub {
        $class->_delete_creds($storeid);
        PVE::Storage::Custom::QNAP::API::clear_credential_latch(undef, $storeid);
        unlink $class->_kind_file($storeid);
        unlink $class->_fork_file($storeid);
    });

    my $api = eval { $class->_api($storeid, $scfg) } or return;
    my $tgt = $class->_tgt($api);
    my $prefix = eval {
        PVE::Storage::Custom::QNAP::Naming::target_prefix_for($storeid) };
    return if !defined $prefix;

    my $targets = eval { $tgt->list } // [];
    for my $t (@$targets) {
        my $name = $t->{name} // '';
        # Only this storage's own targets.
        next if index($name, $prefix) != 0;

        my $info = eval { $tgt->info($t->{index}) };
        # A target with LUNs still on it is not ours to remove, whatever its
        # name suggests — and the LUNs would be left mapped to nothing.
        if ($info && @{ $info->{lun_indexes} // [] }) {
            warn "storage '$storeid': leaving target '$name' in place: it"
               . " still has " . scalar(@{ $info->{lun_indexes} })
               . " LUN(s) mapped to it.\n";
            next;
        }

        # THIS NODE's session first. Removing the target on the NAS while a node
        # is still logged in leaves that node with a session and a node record
        # pointing at something that no longer exists. Other nodes are NOT
        # cleaned up here and nothing in PVE cleans them up either — see
        # deactivate_storage's comment. `pve-qnap-reap` is the path for them.
        $class->_detach_target($storeid, $scfg, $t->{iqn});

        eval { $tgt->delete($t->{index}) };
        warn "storage '$storeid': could not remove target '$name': $@" if $@;
    }
    eval { $api->logout };
    return;
}

# PVE calls _full when the plugin's api() is 13 or higher, and it hands over the
# LIVE config hash — the one that is written immediately afterwards. That is
# what makes the migration possible: a plaintext password left in storage.cfg by
# an earlier version can be moved into /etc/pve/priv and deleted from the config
# by any `pvesm set` on the storage.
sub on_update_hook_full {
    my ($class, $storeid, $scfg, $opts, $delete, $sensitive) = @_;
    $sensitive //= {};

    my $creds = $class->_update_creds($storeid, $scfg, $sensitive, $delete);

    # Strip anything an older version left in the config. $scfg is written by
    # the caller after this returns, so deleting here is what actually removes
    # it.
    delete $scfg->{$_} for values %CRED_KEYS;

    # THE EFFECTIVE CONFIGURATION, which is not $scfg.
    #
    # PVE applies $delete AFTER this hook returns — its own comment says so, so
    # that the hook sees the unmodified current configuration. $scfg therefore
    # still holds a property the operator is removing, while `_update_creds` has
    # already honoured the deletion. Validating against $scfg makes
    # `pvesm set --delete qnap-chap-username,qnap-chap-password` refuse itself:
    # the username still looks present and its secret has already gone.
    #
    # The order is: start from the current config, apply the deletions, then
    # overlay the new values — the same result PVE will write.
    my %effective = %$scfg;
    delete $effective{$_} for @{ $delete // [] };
    %effective = (%effective, %{ $opts // {} });

    $class->_revalidate($storeid, \%effective, $creds);
    return;
}

# The pre-13 form, kept because api() is negotiated and a node can be older.
sub on_update_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;
    my $creds = $class->_update_creds($storeid, $scfg, \%sensitive, undef);
    $class->_revalidate($storeid, $scfg, $creds);
    return;
}

# Merge what was just supplied over what is already stored, so an update that
# does not resend the password keeps it.
sub _update_creds {
    my ($class, $storeid, $scfg, $sensitive, $delete) = @_;

    my $creds = $class->_creds($storeid, $scfg);

    while (my ($key, $prop) = each %CRED_KEYS) {
        next if !exists $sensitive->{$prop};
        my $v = $sensitive->{$prop};
        # PVE puts an explicitly deleted property in here as undef.
        if (!defined $v || !length $v) { delete $creds->{$key} }
        else { $creds->{$key} = $v }
    }
    for my $prop (@{ $delete // [] }) {
        my ($key) = grep { $CRED_KEYS{$_} eq $prop } keys %CRED_KEYS;
        delete $creds->{$key} if defined $key;
    }

    return $creds;
}

# A CHAP username with no secret is a configuration that cannot work, so it is
# refused before anything is written rather than warned about afterwards. A
# refusal must precede every state change — the same rule the activate_storage
# path follows.
sub _assert_chap_pairs {
    my ($class, $storeid, $scfg, $creds) = @_;

    my $user = $scfg->{'qnap-chap-username'};
    if (defined $user && length $user) {
        my $secret = $creds->{'chap-password'};
        die "storage '$storeid': qnap-chap-username is set to '$user' but no"
          . " CHAP secret is stored. Set both together:\n"
          . "    pvesm set $storeid --qnap-chap-username $user --qnap-chap-password <secret>\n"
          . " or remove the username with --delete qnap-chap-username. A target"
          . " with an empty secret accepts anyone while reporting that CHAP is"
          . " on.\n" if !defined $secret || !length $secret;
    }

    my $muser = $scfg->{'qnap-mutual-chap-username'};
    if (defined $muser && length $muser) {
        die "storage '$storeid': qnap-mutual-chap-username is set but no mutual"
          . " CHAP secret is stored.\n"
            if !defined $creds->{'mutual-chap-password'}
            || !length $creds->{'mutual-chap-password'};
        die "storage '$storeid': mutual CHAP authenticates the NAS to the node"
          . " and only works alongside one-way CHAP. Set qnap-chap-username and"
          . " qnap-chap-password as well.\n"
            if !defined $user || !length $user;
    }
    return;
}

sub _revalidate {
    my ($class, $storeid, $scfg, $creds) = @_;

    $class->_assert_chap_pairs($storeid, $scfg, $creds);

    my $api = $class->_api($storeid, $scfg, creds => $creds);
    PVE::Storage::Custom::QNAP::Health::assert_usable($api,
        pool_id => $class->_pool($scfg), quiet => 1);
    $class->_remember_nas_kind($storeid, $api);

    # Push everything this plugin owns but cannot read back, on EVERY target
    # this storage owns.
    #
    # Two things make this necessary rather than tidy. The CHAP secret is one:
    # the NAS never returns a password, so `reconcile_chap` on the hot path can
    # only compare whether CHAP is on and under which name — a CHANGED secret is
    # invisible there, and this is the one moment it is known. `bTargetClusterEnable`
    # is the other: `targetInfo` does not report it at all, so there is
    # nothing anywhere to compare against, and if it is ever wrong this is the
    # only place that can put it right.
    #
    # EVERY target, not just the shared one. In `per-volume` mode there is a
    # target per disk, and a version of this that only looked at the shared name
    # would leave them all on the old secret without saying so.
    {
        my $prefix = eval {
            PVE::Storage::Custom::QNAP::Naming::target_prefix_for($storeid) };
        my $tgt = $class->_tgt($api);
        my $targets = defined $prefix ? eval { $tgt->list } : undef;
        my $n = 0;
        my %chap = $class->_chap($storeid, $scfg, $creds);

        for my $t (@{ $targets // [] }) {
            my $name = $t->{name} // '';
            next if index($name, $prefix) != 0;
            eval { $tgt->push_settings($t, %chap); $n++ };
            warn "storage '$storeid': could not re-apply settings to target"
               . " '$name': $@" if $@;
        }
        # Both directions are reported. Turning access control OFF especially:
        # the operator asked for it, but "it happened on the NAS too" is the
        # part they cannot see from the configuration.
        if ($n) {
            print defined $scfg->{'qnap-chap-username'}
                ? "storage '$storeid': target settings and CHAP re-applied to"
                . " $n target(s).\n"
                : "storage '$storeid': CHAP REMOVED from $n target(s) on the"
                . " NAS.\n";
        }
    }

    $api->logout;

    # After the checks, as in on_add_hook.
    $class->_write_creds($storeid, $creds);

    # A configuration change is the operator having had a chance to fix things,
    # so the credential latch and the once-only warnings both reset.
    PVE::Storage::Custom::QNAP::API::clear_credential_latch($storeid);
    PVE::Storage::Custom::QNAP::Health::clear_warnings($storeid);
    return;
}

# ---------------------------------------------------------------------------
# Names and paths
# ---------------------------------------------------------------------------

# Element 1 is the LEAF, so a linked clone reports vm-101-disk-0 and not
# base-100-disk-0/vm-101-disk-0. That is what RBDPlugin does, and
# PVE::Storage::storage_migrate builds the target volume name out of this
# element when a disk moves to a storage of another type.
sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m{^((base-(\d+)-\S+)/)?((base)?(vm)?-(\d+)-\S+)$}) {
        my ($basename, $basevmid, $leaf, $isbase, $vmid) = ($2, $3, $4, $5, $7);
        return ('images', $leaf, $vmid, $basename, $basevmid,
                $isbase ? 1 : 0, 'raw');
    }

    die "unable to parse QNAP volume name '$volname'\n";
}

# $scfg->{storage} is always undef — PVE's storage config hash does not carry
# the storage id — so this cannot be implemented, and every base method that
# would reach it is overridden. Dying with an actionable message beats returning
# a path that is silently wrong.
sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;
    die "a QNAP LUN has no filesystem path. This is a bug in the caller: use"
      . " path() with the storage id.\n";
}

# The dm-uuid link, NOT /dev/mapper/<wwid>.
#
# On a node with `user_friendly_names yes` multipath names the map mpathX and
# /dev/mapper/<wwid> does not exist at all. The dm-uuid link is always present,
# whatever naming policy the node's administrator chose.
sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    die "a QNAP LUN cannot be addressed at a snapshot: roll back to it, or"
      . " clone it into a new disk.\n" if defined $snapname;

    # $vmid, not the leaf name: the second element is the OWNER.
    my ($vtype, $leaf, $vmid) = $class->parse_volname($volname);
    my $api  = $class->_api($storeid, $scfg);
    my $lun  = $class->_lun($api);
    my $name = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $volname);

    my $obj = $lun->get($name)
        or die "storage '$storeid': there is no LUN named '$name' on the NAS\n";
    $api->logout;

    my $wwid = PVE::Storage::Custom::QNAP::LUN::wwid_of($obj)
        or die "storage '$storeid': the NAS reports no LUNNAA for '$name', so"
             . " its device cannot be identified on this node\n";
    my $path = PVE::Storage::Custom::QNAP::Multipath::dm_uuid_path($wwid)
        or die "storage '$storeid': could not derive a device path for '$name'\n";

    # ($path, $vmid, $vtype) — what RBDPlugin and ZFSPoolPlugin return, and what
    # PVE actually consumes. `qm destroy` calls path() in list context and
    # compares the second element against the VM id NUMERICALLY:
    #
    #     return if !$path || !$owner || ($owner != $vmid);
    #
    # Returning the leaf name there makes that comparison "vm-9999-disk-0" !=
    # 9999, so PVE returns early and never calls vdisk_free — every `qm destroy`
    # silently LEAKS its LUN, with nothing but a numeric warning to show for it.
    return wantarray ? ($path, $vmid, $vtype) : $path;
}

# The base implementation runs `qemu-img info` on filesystem_path, which cannot
# exist here — so without this override `qm create` with an EXISTING volume dies
# before it starts, and the message points at filesystem_path rather than at the
# real cause.
#
# Answered from the NAS, which is the authority on a LUN's size — and here that
# matters more than usual: QTS rounds every LUN up to a whole GiB, so what PVE
# asked for and what exists are routinely different numbers.
sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $volname);
    my $obj = eval { $lun->get($name) };
    my $err = $@;
    eval { $api->logout };

    die "storage '$storeid': could not read the size of '$name': $err" if $err;
    die "storage '$storeid': there is no LUN named '$name' on the NAS\n" if !$obj;
    die "storage '$storeid': the NAS reports no capacity for '$name'\n"
        if !defined $obj->{size};

    # ($size, $format, $used, $parent, $ctime). `used` is the NAS's own
    # allocated figure, which it reports as a formatted string ("0 Byte"); it is
    # only displayed, so it is passed through rather than parsed into a number
    # this plugin would have to guess the unit of.
    return wantarray ? ($obj->{size}, 'raw', undef, undef, undef) : $obj->{size};
}

# LVM and RBD override these; the base answers () unless $scfg->{path} is set,
# which silently refuses every disk move to another storage type, `pvesm
# export`/`import` and remote migration before any plugin code runs.
sub volume_export_formats { return ('raw+size') }
sub volume_import_formats { return ('raw+size') }

# The base implementation is gated on `$scfg->{path}`, which a block storage
# never sets — so it would refuse every export while `volume_export_formats`
# above promises `raw+size`. That mismatch breaks a disk move to another storage
# type with a message about a format rather than about a path.
sub volume_export {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot,
        $base_snapshot, $with_snapshots) = @_;

    die "storage '$storeid': only raw+size can be exported (asked for"
      . " '$format')\n" if $format ne 'raw+size';
    die "storage '$storeid': a QNAP LUN cannot be exported together with its"
      . " snapshots\n" if $with_snapshots;
    die "storage '$storeid': exporting from a snapshot is not supported: roll"
      . " back to it, or clone it into a disk of its own first\n"
        if defined $snapshot || defined $base_snapshot;

    my $path = $class->path($scfg, $volname, $storeid);
    my $size = $class->volume_size_info($scfg, $storeid, $volname);

    PVE::Storage::Plugin::write_common_header($fh, $size);
    run_command([ 'dd', "if=$path", 'bs=4k', 'status=none' ],
        output => '>&' . fileno($fh));
    return;
}

sub volume_import {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot,
        $base_snapshot, $with_snapshots, $allow_rename) = @_;

    die "storage '$storeid': only raw+size can be imported (offered"
      . " '$format')\n" if $format ne 'raw+size';
    die "storage '$storeid': a QNAP LUN cannot be imported together with its"
      . " snapshots\n" if $with_snapshots;

    my ($vtype, $leaf, $vmid) = $class->parse_volname($volname);
    my $size = PVE::Storage::Plugin::read_common_header($fh);

    # The disk has to exist before anything can be written into it, and it is
    # created at the size the stream declares — rounded UP, never down: a volume
    # smaller than the source gets filled and then fails. QTS rounds up again to
    # a whole GiB, which can only make it larger.
    my $name = $class->alloc_image($storeid, $scfg, $vmid, 'raw', $leaf,
        int(($size + 1023) / 1024));

    my $ok = eval {
        $class->activate_volume($storeid, $scfg, $name);
        my $path = $class->path($scfg, $name, $storeid);
        run_command([ 'dd', "of=$path", 'bs=4k', 'conv=fsync', 'status=none' ],
            input => '<&' . fileno($fh));
        1;
    };
    if (!$ok) {
        my $err = $@;
        # Cleanup on failure: a half-written disk PVE does not know about is
        # worse than a failed import.
        eval { $class->free_image($storeid, $scfg, $name, 0) };
        die "storage '$storeid': import of '$name' failed and it was removed"
          . " again: $err";
    }

    return "$storeid:$name";
}

# Refused rather than left to a base implementation that would reach for a
# filesystem path. This plugin has no call that renames a snapshot, and
# pretending otherwise would lose the mapping between what PVE lists and what
# the NAS holds.
sub rename_snapshot {
    my ($class, $scfg, $storeid, $volname, $source_snap, $target_snap) = @_;
    die "storage '$storeid': a QNAP LUN snapshot cannot be renamed.\n";
}

# Neither is meaningful for a block storage, and both would otherwise reach for
# `$scfg->{path}` and produce an error about a directory.
sub get_subdir {
    my ($class, $scfg, $vtype) = @_;
    die "a QNAP LUN storage has no directories, so '$vtype' has no path.\n";
}

sub prune_backups {
    my ($class, $scfg, $storeid, $keep, $vmid, $type, $dryrun, $logfunc) = @_;
    die "storage '$storeid': this storage holds disks, not backups.\n";
}

# PVE::LXC::Config freezes a container's mountpoints only when this is true, and
# a container's root is mounted on this host while the NAS snapshots it.
sub volume_snapshot_needs_fsfreeze { return 1 }

sub get_identity {
    my ($class, $scfg, $storeid) = @_;
    my $api = $class->_api($storeid, $scfg, status => 1);
    my $id = eval { PVE::Storage::Custom::QNAP::Health::nas_identity($api) };
    eval { $api->logout };
    # Pinned to something intrinsic to the NAS rather than to an address,
    # because an address can be re-pointed at a different NAS.
    my $pool = $class->_pool($scfg) // '';
    return defined $id ? "qnapsan:$id:$pool"
                       : "qnapsan:" . ($scfg->{'qnap-portal'} // '') . ":$pool";
}

# ---------------------------------------------------------------------------
# Storage-level operations
# ---------------------------------------------------------------------------

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    my $api = $class->_api($storeid, $scfg, status => 1);
    my @r = PVE::Storage::Custom::QNAP::Health::status(
        $api, $class->_lun($api), pool_id => $class->_pool($scfg));
    eval { $api->logout };
    return @r;
}

# Runs every few seconds per node per storage, sequentially with every other
# storage. It must be cheap and idempotent on the no-change path, and — the rule
# that cost a related project an incident — **nothing may change node state
# before every check that could refuse the storage has passed.**
sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    die "storage '$storeid': open-iscsi is not usable on this node (iscsiadm"
      . " did not answer)\n"
        if !PVE::Storage::Custom::QNAP::ISCSI::is_available();

    # Only now may the node be touched. The drop-in is written before anything
    # is mapped, because without it a QNAP LUN falls back to multipath's generic
    # defaults — and those include no_path_retry "queue".
    my $changed = PVE::Storage::Custom::QNAP::Multipath::write_conf(
        no_path_retry => $scfg->{'qnap-no-path-retry'});
    # The one permitted node-wide reconfigure, and only when the file changed:
    # multipathd has no per-file reload. Never on a timer.
    PVE::Storage::Custom::QNAP::Multipath::reload_config() if $changed;

    return 1;
}

# ---------------------------------------------------------------------------
# Reaping orphaned devices
# ---------------------------------------------------------------------------

# A map this node holds for a LUN the NAS no longer has.
#
# PVE calls `deactivate_volume` on the source node only when it copied a LOCAL
# volume — `QemuMigrate`'s single `deactivate_volumes` call is inside
# `sync_offline_local_volumes` — so for a SHARED storage the source node is
# never told. A VM live-migrated A -> B -> C and destroyed on C leaves A and B
# each holding a multipath map and a tracking entry for a LUN that has ceased to
# exist. One per LUN, per node that ever saw it.
#
# It is not corruption: the LUN number within a target is reused, so a stale
# device path can point at a different LUN, and the kernel-WWID check is what
# stops that. It is a leak, and a dead map is something an operator will
# eventually trip over.
#
# THE SAFETY CONTRACT, and none of it is optional:
#
#   * `$live` must be a COMPLETE listing. A partial one would name every live
#     volume an orphan, and this list feeds a flush. `LUN::list` dies rather
#     than returning an empty list when it could not ask, and the read below is
#     NOT wrapped in an eval that could swallow that into an empty set.
#   * `is_device_in_use` must answer a definite **0**. undef means "could not
#     tell", and a safety check that cannot answer must not answer "safe".
#   * One map at a time, named. Never a node-wide flush.
sub reap_orphans {
    my ($class, $storeid, $scfg, %opt) = @_;
    my $dry = $opt{dry_run} ? 1 : 0;
    my @report;

    my $state = $class->_state($storeid);
    my $tracked = $state->tracked;
    return [] if !%$tracked;

    # The complete live set, or nothing at all. A failure here must not become
    # an empty listing, because an empty listing makes everything an orphan.
    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $luns = $lun->list;
    die "storage '$storeid': could not read the LUN list; not reaping"
      . " anything\n" if ref $luns ne 'ARRAY';

    # The listing carries no NAA, so the live set has to be built from each
    # LUN's own info. Only this storage's own LUNs are looked up: a WWID this
    # node tracks can only belong to one of them, and asking about every LUN on
    # the NAS would be a round trip per LUN for information that cannot change
    # the answer.
    my %live;
    for my $l (@$luns) {
        next if !PVE::Storage::Custom::QNAP::Naming::is_pve_managed_volume(
            $l->{LUNName} // '', $storeid);
        my $info = $lun->get_by_index($l->{LUNIndex}) or next;
        my $w = PVE::Storage::Custom::QNAP::LUN::wwid_of($info);
        $live{ lc $w } = 1 if defined $w;
    }
    eval { $api->logout };

    # STALE TRACKING, which is the crash case and not an orphan.
    #
    # A node that is hard-reset never runs `deactivate_volume`, so its tracking
    # file keeps an entry for a LUN that is no longer attached — while the LUN
    # itself still exists on the NAS, so `orphans` correctly does not report it.
    #
    # It is not dangerous — every consumer re-checks for a device before acting —
    # but it is a record that says this node holds something it does not, and
    # `deactivate_storage` reads a non-empty tracking file as "still in use".
    #
    # Only a confirmed 1 from `map_is_gone` counts: it is three-valued, and
    # undef means the stat never came back.
    my $orphaned = { map { $_ => 1 } @{ $state->orphans(\%live) } };
    for my $wwid (sort keys %$tracked) {
        next if $orphaned->{$wwid};
        my $gone = PVE::Storage::Custom::QNAP::Multipath::map_is_gone($wwid);
        next if !defined $gone || !$gone;

        push @report, { wwid => $wwid, volname => $state->volname_for($wwid) // '?',
                        action => $dry ? 'would untrack' : 'untracked',
                        reason => 'the LUN still exists but nothing is attached here'
                                . ': a tracking entry left by a crash' };
        $state->untrack($wwid) if !$dry;
    }

    for my $wwid (@{ $state->orphans(\%live) }) {
        my $volname = $state->volname_for($wwid) // '?';
        my $path = PVE::Storage::Custom::QNAP::Multipath::device_path_for_wwid($wwid);

        if (!defined $path) {
            # No device left; only the bookkeeping is stale.
            push @report, { wwid => $wwid, volname => $volname,
                            action => $dry ? 'would untrack' : 'untracked',
                            reason => 'no device on this node' };
            $state->untrack($wwid) if !$dry;
            next;
        }

        my $in_use = PVE::Storage::Custom::QNAP::Multipath::is_device_in_use($path);
        if (!defined $in_use) {
            push @report, { wwid => $wwid, volname => $volname, action => 'skipped',
                            reason => "could not determine whether $path is in use"
                                    . ": refusing rather than guessing" };
            next;
        }
        if ($in_use) {
            push @report, { wwid => $wwid, volname => $volname, action => 'skipped',
                            reason => "$path is IN USE on this node even though the"
                                    . " LUN is gone from the NAS" };
            next;
        }

        if ($dry) {
            push @report, { wwid => $wwid, volname => $volname,
                            action => 'would flush', reason => "$path" };
            next;
        }

        $class->_detach_local($storeid, $scfg, $wwid);
        my $gone = PVE::Storage::Custom::QNAP::Multipath::map_is_gone($wwid);
        push @report, { wwid => $wwid, volname => $volname,
                        action => (defined $gone && $gone) ? 'flushed' : 'flush incomplete',
                        reason => "$path" };
    }

    return \@report;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $state = eval { $class->_state($storeid) } or return 1;

    # NOTHING IN PROXMOX VE CALLS THIS FUNCTION.
    #
    # Verified across the whole /usr/share/perl5/PVE tree on PVE 9 in the
    # related projects: only the dispatcher in Storage.pm and the per-plugin
    # implementations exist, and neither pvestatd nor the API invokes it.
    #
    # It is kept, implemented and safe, because it is reachable manually and a
    # future PVE release may start calling it. But it is NOT the cleanup path:
    # `pve-qnap-reap` is, and the documentation says so.
    #
    # Reap first regardless. A node that migrated a VM away keeps a map for a
    # LUN that may since have been deleted, and the tracking check below would
    # read that as "something is still attached" and never log out — one stale
    # entry would pin a session open for good.
    my $reaped = eval { $class->reap_orphans($storeid, $scfg) };
    warn "storage '$storeid': could not reap orphaned devices: $@" if $@;
    for my $r (@{ $reaped // [] }) {
        print "storage '$storeid': $r->{action} orphan $r->{volname}"
            . " ($r->{wwid}): $r->{reason}\n";
    }

    my $tracked = eval { $state->tracked } // {};
    # Something is still legitimately attached here; leaving is not this call's
    # business.
    return 1 if %$tracked;

    my $prefix = eval {
        PVE::Storage::Custom::QNAP::Naming::target_prefix_for($storeid) };
    return 1 if !defined $prefix;

    # Match on the name this plugin gives its own targets, which QTS embeds in
    # the IQN. A session to anything else on the same NAS is not ours to end.
    for my $s (@{ PVE::Storage::Custom::QNAP::ISCSI::sessions() }) {
        next if index($s->{iqn}, $prefix) < 0;
        $class->_detach_target($storeid, $scfg, $s->{iqn});
    }
    return 1;
}

# Log out of one target on this node and forget its node record. One target at a
# time: `--logoutall` would drop every other storage's sessions.
sub _detach_target {
    my ($class, $storeid, $scfg, $iqn) = @_;
    return if !defined $iqn;

    for my $portal (@{ $class->_data_portals($scfg) }) {
        next if !PVE::Storage::Custom::QNAP::ISCSI::has_session($iqn, $portal);
        eval { PVE::Storage::Custom::QNAP::ISCSI::logout($iqn, $portal) };
        warn "storage '$storeid': could not log out of $iqn at $portal: $@" if $@;
    }
    # The record goes too, so nothing on this node points at a target that may
    # no longer exist.
    for my $portal (@{ $class->_data_portals($scfg) }) {
        eval { PVE::Storage::Custom::QNAP::ISCSI::node_delete($iqn, $portal) };
    }
    return;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $luns = $lun->list;

    my $res = $class->_images_from_luns($storeid, $lun, $luns, $vmid, $vollist);
    eval { $api->logout };
    return $res;
}

# The LUN listing turned into PVE's image records.
#
# `extra_lun_index` carries NO capacity — that is only in `lun_info`, which is
# a call per LUN. So a size is fetched only for the LUNs that survive the
# ownership filter and the vmid/vollist filters, which bounds the cost to the
# disks PVE is actually asking about rather than to every LUN on the NAS.
sub _images_from_luns {
    my ($class, $storeid, $lun, $luns, $vmid, $vollist) = @_;

    my $res = [];
    for my $l (@$luns) {
        # Ownership, decided locally on the name and WITH the storage id. A
        # prefix identifies the storage, never the kind of object.
        my $volname = PVE::Storage::Custom::QNAP::Naming::volname_from_lun_name(
            $l->{LUNName} // '', $storeid) or next;

        my (undef, undef, $owner) = eval { $class->parse_volname($volname) };
        next if !defined $owner;

        # `!$vollist &&` matters, and it is the base class's own condition.
        # When the caller named exact volids it knows what it asked for, so the
        # vmid is not also applied — otherwise a volid on the list whose owner
        # differs would be silently absent from the answer.
        next if !$vollist && defined $vmid && $owner ne $vmid;

        my $volid = "$storeid:$volname";
        if ($vollist) {
            next if !grep { $_ eq $volid } @$vollist;
        }

        # One call per surviving LUN. A size that could not be read is reported
        # as undef rather than as 0: PVE displays it, and a disk shown as empty
        # is a disk somebody will try to delete.
        my $info = eval { $lun->get_by_index($l->{LUNIndex}) };

        push @$res, {
            volid  => $volid,
            format => 'raw',
            size   => ($info ? $info->{size} : undef),
            used   => undef,
            vmid   => $owner,
            ctime  => undef,
        };
    }
    return $res;
}

# The trailing $luns is this plugin's addition and the reason for it is cost.
#
# `list_images` opens its own session. Called from inside `alloc_image` — which
# already has one — that would be a second login and a second logout, all inside
# PVE's cluster_lock_storage, which is cluster-wide and serialises every
# allocation on the storage.
#
# NAMES ONLY. `find_free_diskname` needs the set of names in use and nothing
# else, so this deliberately does NOT go through `_images_from_luns`, which
# fetches a size per LUN. Using that here would make choosing a disk name cost a
# round trip per existing disk, inside the cluster lock.
sub find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix, $luns) = @_;

    my @names;
    if (defined $luns) {
        for my $l (@$luns) {
            my $v = PVE::Storage::Custom::QNAP::Naming::volname_from_lun_name(
                $l->{LUNName} // '', $storeid);
            push @names, $v if defined $v;
        }
    } else {
        my $imgs = $class->list_images($storeid, $scfg, undef, undef, {});
        @names = map { (split m{:}, $_->{volid}, 2)[1] } @$imgs;
    }

    return PVE::Storage::Plugin::get_next_vm_diskname(
        \@names, $storeid, $vmid, $fmt, $scfg, $add_fmt_suffix);
}

# ---------------------------------------------------------------------------
# Volume lifecycle
# ---------------------------------------------------------------------------

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "storage '$storeid': only raw disks are supported (asked for '$fmt')\n"
        if defined $fmt && $fmt ne 'raw';

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);

    # `pvesm alloc` passes an EMPTY STRING when no name is given, not undef, so
    # `//=` never fires and the LUN name would come out as just the prefix.
    $name = undef if defined $name && !length $name;

    # ONE listing for the whole allocation. It is used for the free-name search,
    # for the ceiling check, and for the duplicate-name check inside
    # `LUN::create`. Fetching it three times would be three round trips inside
    # PVE's cluster lock, which serialises every allocation on the storage.
    my $all = $lun->list;

    $name //= $class->find_free_diskname($storeid, $scfg, $vmid, $fmt, 0, $all);

    # Thin LUNs can overcommit the pool, and PVE has no way to express
    # over-subscription — so a full pool, which takes every VM on it with it,
    # has to be prevented here.
    my $min_free = ($scfg->{'qnap-min-free'} // 10) * 1024 ** 3;
    if ($min_free > 0) {
        # (total, AVAILABLE, used, active) — PVE's order, not the intuitive one.
        my (undef, $avail, undef, $active) =
            PVE::Storage::Custom::QNAP::Health::status($api, undef,
                pool_id => $class->_pool($scfg));
        die "storage '$storeid': the NAS is not answering; not allocating\n"
            if !$active;
        die "storage '$storeid': storage pool " . ($class->_pool($scfg) // '?')
          . " has only " . sprintf('%.1f', $avail / 1024 ** 3) . " GiB free and"
          . " qnap-min-free is " . ($scfg->{'qnap-min-free'} // 10) . " GiB. A"
          . " thin LUN can overcommit the pool, and a full pool affects every"
          . " VM on it.\n" if $avail < $min_free;
    }

    my $lunname = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $name);

    my $obj = $lun->create(
        known_lun_count => scalar @$all,
        listing     => $all,
        name        => $lunname,
        size        => $size * 1024,          # PVE passes KiB
        pool_id     => $class->_pool($scfg),
        sector_size => $scfg->{'qnap-sector-size'},
        thin        => (defined $scfg->{'qnap-thin'} ? $scfg->{'qnap-thin'} : 1),
    );

    # Map it while we still hold the handle. Cleanup on failure unmaps before it
    # deletes: a LUN deleted while still mapped leaves every node it was mapped
    # to with a device that answers nothing.
    my $ok = eval {
        my $t = $class->_ensure_target($api, $storeid, $scfg, $name);
        $lun->map_to_target($obj->{index}, $t->{index});
        $lun->set_enabled_on_target($obj->{index}, $t->{index}, 1);
        1;
    };
    if (!$ok) {
        my $err = $@;
        eval {
            my $t = $class->_tgt($api)->find_by_name(
                $class->_target_name($storeid, $scfg, $name));
            $lun->unmap_from_target($obj->{index}, $t->{index}) if $t;
        };
        eval { $lun->delete($obj->{index}) };
        eval { $api->logout };
        die "storage '$storeid': created LUN '$lunname' but could not map it,"
          . " so it was removed again: $err";
    }

    $lun->warn_if_near_lun_limit(count => scalar(@$all) + 1);
    eval { $api->logout };
    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $volname);

    # The ownership gate, with the storeid. Never delete anything that is not
    # provably this storage's.
    die "storage '$storeid': refusing to delete '$name', which this storage"
      . " does not own\n"
        if !PVE::Storage::Custom::QNAP::Naming::is_pve_managed_volume($name, $storeid);

    my $obj = $lun->get($name);
    if (!defined $obj) {
        # ABSENT, established by a listing that succeeded. `LUN::list` dies
        # rather than returning an empty list when it could not ask, which is
        # the distinction that matters: returning success here makes PVE drop
        # the disk from the VM configuration, and if the NAS were merely
        # unreachable the LUN would stay on it with nothing pointing at it.
        eval { $api->logout };
        return undef;
    }

    my $index = $obj->{index};
    my $wwid  = PVE::Storage::Custom::QNAP::LUN::wwid_of($obj);

    # A destructive path must not proceed on "could not tell". is_device_in_use
    # answers 1 / 0 / undef, and undef means something inside it could not
    # establish an answer — most importantly `fuser`, which is the only check
    # that sees a running QEMU holding the device open with no mount and no
    # holder.
    $class->_assert_not_in_use($storeid, $wwid, 'delete');

    # The slave list is captured BEFORE anything is torn down: once the map is
    # flushed there is nothing left to ask which sd devices belonged to it.
    my $slaves = PVE::Storage::Custom::QNAP::Multipath::slaves_of_map($wwid);

    # Local device first, while the mapping still exists to find it by.
    $class->_detach_local($storeid, $scfg, $wwid);

    # Then unmap everywhere it is mapped. The LUN's own info says where that is,
    # so this cannot miss a target belonging to another storage mode or left
    # over from one.
    for my $t (@{ $obj->{targets} // [] }) {
        eval { $lun->unmap_from_target($index, $t->{target_index}) };
        warn "storage '$storeid': could not unmap '$name' from target"
           . " $t->{target_index}: $@" if $@;
    }

    # This plugin's own snapshots, before the LUN.
    #
    # QTS will not delete a LUN that still has snapshots, and — on QuTS hero —
    # will not delete a snapshot that an instant clone is still hanging off. An
    # operator who cannot delete a template needs to hear about that.
    #
    # AS A POSSIBILITY, after the NAS's own answer, and never as a finding.
    # Nothing here has established WHY the snapshot could not be removed, and
    # the related Dell plugin told operators that clones existed for every
    # refused delete — including ones refused for something else entirely — so
    # they went looking for clones that were not there.
    for my $s (@{ $lun->snapshot_list($index, all => 1) }) {
        next if !defined $s->{snapname}
             && !PVE::Storage::Custom::QNAP::Naming::is_temp_snapshot_name($s->{name});
        eval { $lun->snapshot_delete($s->{id}) };
        if ($@) {
            my $err = $@;
            $err =~ s/\s+\z//;
            eval { $api->logout };
            die "storage '$storeid': cannot delete '$name' because its snapshot"
              . " '$s->{name}' could not be removed. The NAS said: $err\n"
              . "  One possible cause on QuTS hero is a linked clone: the clone"
              . " shares the snapshot's blocks, so the snapshot cannot go while"
              . " the clone exists. If this disk is a template or was cloned"
              . " from, check for clones first. The disk is still on the NAS,"
              . " unmapped; using it again maps it back.\n";
        }
    }

    $lun->delete($index);

    # Now the residual paths. Deleting the LUN on the NAS does not make its
    # device disappear here — the iSCSI session is still up, so each sd node
    # survives as a DEAD device and multipathd re-adds a map for it. Without
    # this a stale map is left behind for a LUN that no longer exists.
    PVE::Storage::Custom::QNAP::ISCSI::remove_sd_device($_) for @$slaves;

    # And flush again, because the map may have been recreated between the first
    # flush and the delete.
    $class->_detach_local($storeid, $scfg, $wwid);

    # Only once the LUN is verifiably gone.
    $class->_state($storeid)->untrack($wwid) if defined $wwid;

    eval { $api->logout };
    return undef;
}

# ---------------------------------------------------------------------------
# Attaching
# ---------------------------------------------------------------------------

# How long to keep asking the session for a device before giving up, and how
# long to wait between asks. The total is what an operator waits when something
# is genuinely wrong; the interval is what decides whether a session that
# bounced mid-operation is picked up at all.
use constant {
    DISCOVERY_TIMEOUT         => 45,
    DISCOVERY_RESCAN_INTERVAL => 5,
};

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache, $hints) = @_;

    # A SNAPNAME IS A SUCCESSFUL NO-OP, not a refusal.
    #
    # PVE's `clone_vm` activates the source volumes with the snapname before it
    # clones them (`activate_volumes($storecfg, $vollist, $snapname)` in
    # API2/Qemu.pm), for a linked clone as much as a full one. So refusing here
    # would refuse the whole operation, with a message telling the operator to
    # clone it — while they were cloning it.
    #
    # There is nothing to activate: a QNAP LUN has no device at a snapshot, and
    # the clone is entirely array-side. `path()` still refuses a snapname, and
    # must: a caller that genuinely needs a device at a snapshot has to fail
    # loudly rather than be handed the device for the current state.
    return 1 if defined $snapname;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $volname);

    my $obj = $lun->get($name)
        or die "storage '$storeid': there is no LUN named '$name' on the NAS\n";
    my $index = $obj->{index};
    my $wwid = PVE::Storage::Custom::QNAP::LUN::wwid_of($obj)
        or die "storage '$storeid': the NAS reports no LUNNAA for '$name', so"
             . " its device cannot be identified on this node\n";

    my $t = $class->_ensure_target($api, $storeid, $scfg, $volname);

    if (!PVE::Storage::Custom::QNAP::LUN::is_mapped_to($obj, $t->{index})) {
        $lun->map_to_target($index, $t->{index});
        $obj = $lun->get_by_index($index)
            or die "storage '$storeid': '$name' disappeared while being"
                 . " mapped\n";
    }
    # A LUN can be mapped and DISABLED on its target, which presents no device
    # at all. Enabling it is idempotent.
    $lun->set_enabled_on_target($index, $t->{index}, 1)
        if ($obj->{enabled} // '1') ne '1';

    # The number within THIS target, which is what the by-path name carries —
    # not `LUNIndex`, which is the NAS-wide identifier.
    my $number = PVE::Storage::Custom::QNAP::LUN::lun_number_on_target(
        $obj, $t->{index});
    die "storage '$storeid': the NAS does not report a LUN number for '$name'"
      . " on target '$t->{name}', so there is nowhere to look for its device\n"
        if !defined $number;

    my $size = $obj->{size};
    eval { $api->logout };

    my $found;
    for my $portal (@{ $class->_data_portals($scfg) }) {
        my $had_session = PVE::Storage::Custom::QNAP::ISCSI::has_session(
            $t->{iqn}, $portal);

        PVE::Storage::Custom::QNAP::ISCSI::login($t->{iqn}, $portal,
            $class->_chap($storeid, $scfg));

        # A login discovers the LUNs mapped at that moment. This LUN was mapped
        # afterwards if the session already existed — which is every allocation
        # after the first — so the session has to be rescanned or no device ever
        # appears. One session, never `-m session --rescan`, which would rescan
        # every other vendor's storage on this node too.
        #
        # RESCANNED REPEATEDLY, not once, because the session can be bouncing
        # underneath us: a NAS asks initiators to log out while it restores a
        # snapshot, and a single rescan issued in the middle of that achieves
        # nothing while the polling that follows can never succeed, because
        # nothing asked again.
        my $cand = PVE::Storage::Custom::QNAP::ISCSI::by_path_for(
            $portal, $t->{iqn}, $number);

        my $dev;
        my $warned_slow = 0;
        my $deadline = time + DISCOVERY_TIMEOUT;
        while (1) {
            PVE::Storage::Custom::QNAP::ISCSI::rescan_session(
                $t->{iqn}, $portal) if $had_session;
            $dev = PVE::Storage::Custom::QNAP::ISCSI::wait_for_by_path(
                $cand, timeout => DISCOVERY_RESCAN_INTERVAL);
            last if defined $dev;
            last if time >= $deadline;

            if (!$warned_slow) {
                $warned_slow = 1;
                warn "storage '$storeid': the device for '$name' has not"
                   . " appeared yet; still rescanning the session. A NAS asks"
                   . " initiators to log out while it restores a snapshot, so"
                   . " this is expected right after a rollback.\n";
            }
        }
        next if !defined $dev;

        # THE CHECK. The LUN number within a target is reused, so the path that
        # led here proves nothing: a stale device for a detached disk would sit
        # at the same path. Only the kernel's own identification decides, and
        # "could not tell" is not "yes".
        my $is = PVE::Storage::Custom::QNAP::Multipath::device_is_lun($dev, $wwid);
        if (!defined $is) {
            warn "storage '$storeid': could not read the WWID of $dev, so it"
               . " cannot be confirmed as '$name'; ignoring it\n";
            next;
        }
        if (!$is) {
            warn "storage '$storeid': $dev is NOT '$name': QTS reuses a LUN's"
               . " number within a target and this is a stale device."
               . " Ignoring it.\n";
            next;
        }

        # The map has to be made to exist, not hoped for. Under multipath's
        # default `find_multipaths strict` NO device gets a map until its WWID
        # is in /etc/multipath/wwids, and under `yes` a single-path device gets
        # none either — and the path this plugin returns would point at nothing.
        # A QNAP with one data address is the common case, not the exception.
        #
        # ensure_map does nothing once the map exists, which is every portal
        # after the first. The claim below is what offers THIS portal's path to
        # it, so it is not a repeat of what ensure_map already did.
        my $mapped = PVE::Storage::Custom::QNAP::Multipath::ensure_map($wwid, $dev);
        PVE::Storage::Custom::QNAP::Multipath::claim_path($dev);

        # THE KERNEL AND MULTIPATHD CAN DISAGREE ABOUT WHAT THIS DEVICE IS.
        #
        # After a LUN is deleted its number within the target is reused, and the
        # node reuses the sd node with it: the kernel re-reads the VPD on rescan
        # and updates /sys/block/<sd>/device/wwid to the NEW LUN — which is why
        # we got this far, since device_is_lun reads sysfs and confirmed it —
        # while multipathd never re-reads the path and goes on holding a map for
        # the LUN that is gone.
        #
        # Measured in the related project: dropping the path, flushing the
        # corpse map by name and re-adding the path all leave the corpse in
        # place. The only remedy that worked is to make the KERNEL rediscover
        # the device, which is what this does.
        #
        # Safe because both of these hold, and neither is incidental:
        #   1. $dev came from by_path_for(portal, OUR target iqn, number), so it
        #      is on this plugin's own target by construction.
        #   2. It has already been confirmed as OUR LUN by the kernel's own
        #      WWID. We are removing our own device in order to get it back.
        #
        # Once. If rediscovery does not produce the map, the cause is not this,
        # and retrying would be a loop that hides whatever it really is.
        if (!$mapped) {
            warn "storage '$storeid': multipath built no map for '$name'"
               . " although the kernel confirms the device. Asking the kernel"
               . " to rediscover it.\n";

            PVE::Storage::Custom::QNAP::ISCSI::remove_sd_device($dev);
            PVE::Storage::Custom::QNAP::ISCSI::rescan_session($t->{iqn}, $portal);

            my $again = PVE::Storage::Custom::QNAP::ISCSI::wait_for_by_path(
                $cand, timeout => DISCOVERY_TIMEOUT);
            # Re-confirmed, not assumed: rediscovery is exactly the moment the
            # reused number could hand us a different LUN.
            my $ok = defined $again
                ? PVE::Storage::Custom::QNAP::Multipath::device_is_lun($again, $wwid)
                : undef;
            if (defined $ok && $ok) {
                $dev = $again;
                PVE::Storage::Custom::QNAP::Multipath::ensure_map($wwid, $dev);
                PVE::Storage::Custom::QNAP::Multipath::claim_path($dev);
            }
        }

        $found = $dev;
    }

    die "storage '$storeid': no device for '$name' appeared on this node after"
      . " logging in to $t->{iqn}\n" if !defined $found;

    $class->_state($storeid)->track($wwid, $volname);

    # The map is what path() hands out, so its absence is a failure and not a
    # detail — a VM would be started against a path that is not there.
    die "storage '$storeid': the device for '$name' is present but multipath"
      . " built no map for it. Check `find_multipaths` in /etc/multipath.conf"
      . " on this node, and that /etc/multipath/wwids contains $wwid.\n"
        if !PVE::Storage::Custom::QNAP::Multipath::ensure_map($wwid, $found,
               timeout => 20);

    # A RESIZE ONLY EVER REACHED ONE NODE, and a guest can be started on any of
    # them. `volume_resize` runs where the guest is; every other node's map goes
    # on presenting the old size until something refreshes it, and a live
    # migration onto such a node would hand the guest a device SMALLER than its
    # own configuration says. So reconcile here, where the LUN's size is already
    # in hand and costs no extra call to the NAS.
    #
    # A warning, not a refusal: an activation that fails stops a VM from
    # starting, and a short device is a correctness problem rather than a
    # data-loss one. The no-change path reads two sysfs files and does nothing.
    if (defined $size) {
        my $mapname = PVE::Storage::Custom::QNAP::Multipath::map_name_for_wwid($wwid);
        my $have = PVE::Storage::Custom::QNAP::Multipath::map_size_bytes($wwid);
        if (defined $mapname && defined $have && $have < $size) {
            my $slaves = PVE::Storage::Custom::QNAP::Multipath::slaves_of_map($wwid);
            PVE::Storage::Custom::QNAP::ISCSI::rescan_device($_) for @$slaves;
            $class->_grow_node_device($storeid, $wwid, $mapname, $size, $slaves);
        }
    }

    return 1;
}

# Does NOT unmap on the NAS. Other nodes of the cluster share the target, and a
# migration deactivates on the source while the destination is using it.
sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    return 1 if defined $snapname;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $volname);
    my $obj = eval { $lun->get($name) };
    eval { $api->logout };
    return 1 if !$obj;

    my $wwid = PVE::Storage::Custom::QNAP::LUN::wwid_of($obj);
    $class->_detach_local($storeid, $scfg, $wwid);
    return 1;
}

# Refuse a destructive operation unless the device is provably unused.
sub _assert_not_in_use {
    my ($class, $storeid, $wwid, $what) = @_;
    return if !defined $wwid;

    my $path = PVE::Storage::Custom::QNAP::Multipath::device_path_for_wwid($wwid);
    # No device on this node means nothing here is using it.
    return if !defined $path;

    my $in_use = PVE::Storage::Custom::QNAP::Multipath::is_device_in_use($path);

    die "storage '$storeid': refusing to $what this disk: could not establish"
      . " whether anything on this node is using $path. That is not the same as"
      . " 'nothing is', and this operation destroys data. Check with"
      . " 'fuser -vm $path' and try again.\n" if !defined $in_use;

    die "storage '$storeid': refusing to $what this disk: $path is IN USE on"
      . " this node. Stop whatever is using it first ('fuser -vm $path' will"
      . " say what).\n" if $in_use;

    return;
}

# Remove the local device for one WWID. One named map, never a node-wide flush.
sub _detach_local {
    my ($class, $storeid, $scfg, $wwid) = @_;
    return if !defined $wwid;

    my $map = PVE::Storage::Custom::QNAP::Multipath::map_name_for_wwid($wwid);
    if (defined $map) {
        # Captured BEFORE the flush: once the map is gone there is nothing left
        # to ask which sd devices belonged to it.
        my $slaves = PVE::Storage::Custom::QNAP::Multipath::slaves_of_map($wwid);

        PVE::Storage::Custom::QNAP::Multipath::flush_map($map, wwid => $wwid);

        # IF THE MAP SURVIVED, its paths are holding it, and that is not
        # hypothetical: it is what a node sees when the LUN was deleted from
        # ANOTHER node. The iSCSI session here is still up, so each sd node
        # survives as a dead device and multipathd rebuilds a map over it.
        #
        # Only on the failure path, deliberately: removing the sd devices on an
        # ordinary VM stop would force a rediscovery that is not needed.
        # `map_is_gone` is THREE-VALUED — 1 / 0 / undef — and undef means the
        # stat never came back, which must not be read as "still there" and
        # acted on.
        my $gone = PVE::Storage::Custom::QNAP::Multipath::map_is_gone($wwid);
        if (defined $gone && !$gone) {
            PVE::Storage::Custom::QNAP::ISCSI::remove_sd_device($_) for @$slaves;
            PVE::Storage::Custom::QNAP::Multipath::flush_map($map, wwid => $wwid);
        }
    }

    # Untracked only when the device is verifiably gone.
    my $gone = PVE::Storage::Custom::QNAP::Multipath::map_is_gone($wwid);
    $class->_state($storeid)->untrack($wwid) if defined $gone && $gone;
    return;
}

# ---------------------------------------------------------------------------
# Resize, snapshots, clones
# ---------------------------------------------------------------------------

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running, $snapname) = @_;

    die "storage '$storeid': a snapshot cannot be resized\n" if defined $snapname;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $volname);
    my $obj = $lun->get($name)
        or die "storage '$storeid': there is no LUN named '$name'\n";

    my $new = $lun->resize($obj, $size);
    eval { $api->logout };

    # QTS ROUNDS UP TO A WHOLE GiB, so what the guest gets is usually MORE than
    # what was asked for. That is reported rather than hidden: PVE writes the
    # size this returns into the VM configuration, and a configuration that
    # disagrees with the device is the thing this plugin works hardest to avoid.
    my $got = $new->{size};
    warn "storage '$storeid': QTS allocates in whole GiB, so '$name' is now"
       . " $got bytes rather than the $size requested.\n"
        if defined $got && defined $size && $got != $size;

    # Then refresh what this node already has. A per-device rescan and a map
    # resize — never a host scan, which discovers new devices rather than
    # refreshing existing ones.
    my $wwid = PVE::Storage::Custom::QNAP::LUN::wwid_of($new);
    my $map = defined $wwid
        ? PVE::Storage::Custom::QNAP::Multipath::map_name_for_wwid($wwid) : undef;
    if (defined $map) {
        # The SLAVES carry the new size up to the map. Rescanning the map itself
        # does nothing — /sys/block/dm-N has no device/rescan — and that is
        # exactly the mistake that makes a resize succeed on the NAS while the
        # node goes on reporting the old size.
        my $slaves = PVE::Storage::Custom::QNAP::Multipath::slaves_of_map($wwid);
        PVE::Storage::Custom::QNAP::ISCSI::rescan_device($_) for @$slaves;
        $class->_grow_node_device($storeid, $wwid, $map, $got, $slaves, fatal => 1);
    }

    return $got;
}

# A RESIZE THAT REACHED THE ARRAY AND NOT THE NODE MUST SAY SO.
#
# PVE's very next step after `volume_resize` is `block_resize`, issued with no
# tolerance at all for a device that has not caught up. When the map is still
# short, QEMU answers "Cannot grow device files" — an unexplained failure of a
# plugin that had, on the array, done exactly what was asked. Worse, PVE writes
# the VM configuration only after `block_resize` succeeds, so the NAS is left at
# the new size while the configuration still claims the old one.
sub _grow_node_device {
    my ($class, $storeid, $wwid, $map, $want, $slaves, %opt) = @_;
    return 1 if !defined $want || !$want;

    my $r = PVE::Storage::Custom::QNAP::Multipath::grow_map(
        $wwid, $map, $want, $slaves);
    return 1 if $r->{ok};

    my $have = defined $r->{size} ? "$r->{size} bytes"
                                  : 'a size that could not be read';
    my $why =
        $r->{cmd_error}   ? "multipathd could not be run on this node:"
                            . " $r->{cmd_error}"
      : $r->{paths_ready} ? "The paths carry the new size but the map did not"
                            . " follow."
      :                     "This node's paths to the LUN are still reporting"
                            . " the old size.";
    my $msg = "storage '$storeid': the LUN is $want bytes on the NAS, but this"
      . " node's multipath map '$map' is presenting $have after "
      . PVE::Storage::Custom::QNAP::Multipath::RESIZE_SETTLE_TIMEOUT
      . "s. $why The guest has NOT been given the new space. Nothing is damaged"
      . " and the NAS is correct: refresh the node with 'multipathd resize map"
      . " $map' and run the resize again to the same size.\n";

    die $msg if $opt{fatal};
    warn $msg;
    return 0;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $volname);
    my $obj = $lun->get($name) or die "storage '$storeid': no LUN '$name'\n";

    # Flush BEFORE the snapshot, or it records what reached the NAS rather than
    # what the guest believes it wrote.
    #
    # A warning, not a refusal: the snapshot is still a valid crash-consistent
    # one without it, only staler than intended, and refusing to take a snapshot
    # is worse than taking a slightly older one.
    my $wwid = PVE::Storage::Custom::QNAP::LUN::wwid_of($obj);
    my $flushed = defined $wwid
        ? PVE::Storage::Custom::QNAP::Multipath::flush_device_cache($wwid)
        : undef;
    warn "storage '$storeid': could not flush this node's cache for the device"
       . " before snapshotting '$snap'. The snapshot is still crash-consistent,"
       . " but it may not contain the guest's most recent writes. Check that"
       . " blockdev is installed and runnable on this node.\n"
        if defined $flushed && !$flushed;

    $lun->snapshot_create(
        lun_index   => $obj->{index},
        name        => PVE::Storage::Custom::QNAP::Naming::snapshot_name($snap),
        description => "$snap (Proxmox VE $storeid)",
    );
    eval { $api->logout };
    return 1;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;
    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $volname);
    my $obj = $lun->get($name);
    if (!$obj) { eval { $api->logout }; return 1 }

    # THE OWNERSHIP GATE, explicitly, on the LUN as well as the snapshot.
    #
    # The snapshot list below already refuses a snapshot this plugin did not
    # take, and a snapshot this plugin took implies a LUN this plugin owns — but
    # that is two hops of reasoning guarding a destructive operation. A prefix
    # identifies the STORAGE, never the kind of object, so the object gets its
    # own check.
    die "storage '$storeid': refusing to delete a snapshot of '$name', which"
      . " this storage does not own\n"
        if !PVE::Storage::Custom::QNAP::Naming::is_pve_managed_volume($name, $storeid);

    # Only this plugin's own snapshots are visible here, so an operator's
    # scheduled snapshot cannot be deleted by a VM operation.
    my ($found) = grep { ($_->{snapname} // '') eq $snap }
                       @{ $lun->snapshot_list($obj->{index}) };
    if (!$found) { eval { $api->logout }; return 1 }

    eval { $lun->snapshot_delete($found->{id}) };
    if (my $err = $@) {
        $err =~ s/\s+\z//;
        # On QuTS hero a disk cloned FROM this snapshot shares its blocks, and
        # the NAS will not remove a snapshot something still hangs off. Offered
        # as a possibility after the NAS's own answer, never as a finding.
        my $hint = eval { $api->is_zfs }
            ? "\n  One possible cause on QuTS hero is a disk that was cloned from"
            . " this snapshot: it shares the snapshot's blocks, so the snapshot"
            . " cannot go while that disk exists."
            : '';
        eval { $api->logout };
        die "$err$hint\n";
    }
    eval { $api->logout };
    return 1;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    # A CLAIM, not the cluster lock: see `_fork_claim`. Nothing in PVE holds a
    # storage lock around a rollback, so this is what stands between two of
    # them and each other's answers, and it must not put a time limit on work
    # the NAS needs as long as it needs.
    $class->_fork_claim($storeid, $scfg, "rolling '$volname' back to '$snap'");

    my $ok = eval { $class->_do_rollback($storeid, $scfg, $volname, $snap) };
    my $err = $@;

    # Released, with one exception: the NAS was waited for as long as this
    # plugin waits and has still not answered. It is then STILL WORKING, so the
    # claim stays and runs out on its own. Releasing it would let the next
    # rollback start on top of this one.
    $class->_fork_release($storeid)
        if !$err || $err !~ /has NOT failed/;

    die $err if $err;
    return $ok;
}

sub _do_rollback {
    my ($class, $storeid, $scfg, $volname, $snap) = @_;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $volname);
    my $obj = $lun->get($name) or die "storage '$storeid': no LUN '$name'\n";

    die "storage '$storeid': refusing to roll back '$name', which this storage"
      . " does not own\n"
        if !PVE::Storage::Custom::QNAP::Naming::is_pve_managed_volume($name, $storeid);

    my ($found) = grep { ($_->{snapname} // '') eq $snap }
                       @{ $lun->snapshot_list($obj->{index}) };
    die "storage '$storeid': '$name' has no snapshot named '$snap' taken by"
      . " this plugin\n" if !$found;

    my $wwid = PVE::Storage::Custom::QNAP::LUN::wwid_of($obj);

    # A rollback OVERWRITES the disk, so it is as destructive as a delete and
    # takes the same guard. PVE stops a rollback on a running VM at a higher
    # level, but a plugin that relied on that would be trusting a caller it does
    # not control.
    $class->_assert_not_in_use($storeid, $wwid, 'roll back');

    # FLUSH BEFORE. Dirty pages written back after the NAS has restored the
    # snapshot would land pre-rollback content on top of it, and the result
    # looks like a rollback that half worked.
    #
    # `defined` FIRST. undef means there is no device on this node — which is
    # what a stopped VM leaves behind, and PVE requires a stop before a disk
    # rollback. No device, no dirty pages, nothing to refuse over.
    my $flushed = defined $wwid
        ? PVE::Storage::Custom::QNAP::Multipath::flush_device_cache($wwid)
        : undef;
    die "storage '$storeid': refusing to roll back: this node has the device"
      . " for this disk but its host cache could not be flushed, so dirty pages"
      . " could be written back on top of the restored snapshot. Check that"
      . " blockdev is installed and runnable on this node.\n"
        if defined $flushed && !$flushed;

    # LUN::snapshot_rollback verifies afterwards that the NAA did not change —
    # if it ever does, the device identity moved underneath every node.
    $lun->snapshot_rollback(lun_index => $obj->{index}, snapshot_id => $found->{id});

    # INVALIDATE AFTER. Reading the device straight after a successful rollback
    # returns the OLD bytes until the cache is dropped, so without this a guest
    # goes on seeing pre-rollback data from cache.
    #
    # A warning and not a die: the rollback HAS happened on the NAS by now, so
    # refusing would report a failure for work that is done. But it must be said
    # out loud, because the symptom is a disk that looks as though it was never
    # rolled back at all.
    my $dropped = defined $wwid
        ? PVE::Storage::Custom::QNAP::Multipath::invalidate_device_cache($wwid)
        : undef;
    warn "storage '$storeid': the rollback succeeded on the NAS, but this"
       . " node's cache for the device could not be invalidated. Reads may"
       . " return pre-rollback data until the guest is started fresh.\n"
        if defined $dropped && !$dropped;

    eval { $api->logout };
    return 1;
}

# What `recover_snapshot` does to snapshots NEWER than the one being restored is
# something this project has not measured on
# hardware. So PVE is left to its own default, which is to allow the rollback
# and keep its own record — the same position the related Synology plugin holds
# after measuring that newer snapshots survive there.
#
# If a measurement ever shows that QTS discards them, this is where the refusal
# goes: PVE would otherwise delete snapshots the operator can still see, without
# saying so. It is listed as open in docs/TESTING.md.
sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap, $blockers) = @_;
    return 1;
}

# Answered from the NAS. The base implementation runs `qemu-img info` on
# filesystem_path, which does not exist here.
sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;
    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $name = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $volname);
    my $obj = eval { $lun->get($name) };
    my $info = {};
    if ($obj) {
        for my $s (@{ $lun->snapshot_list($obj->{index}) }) {
            next if !defined $s->{snapname};
            $info->{ $s->{snapname} } = {
                id => $s->{id},
                timestamp => _plausible_epoch($s->{create_time}),
            };
        }
    }
    eval { $api->logout };
    return $info;
}

# A timestamp PVE could act on, or none at all.
#
# Whether QTS's `create_time` is an epoch is unknown: this project has not
# measured what it actually is. Reporting a wrong one is worse than reporting
# nothing: a snapshot dated 1970 or the year 58000 sorts to an end of the list
# and looks like a real answer. Nothing in Proxmox VE 9 reads this value —
# Replication and QemuServer use the snapshot NAMES — so a missing one breaks
# nothing today. It is guarded anyway, because "nothing reads it yet" is not a
# property of the data.
sub _plausible_epoch {
    my ($v) = @_;
    return undef if !defined $v || $v !~ /\A[0-9]+\z/;

    # 2001-09-09 .. 2065-01-24. Wide enough that a clock set badly still passes,
    # narrow enough that a millisecond value cannot.
    return $v + 0 if $v >= 1_000_000_000 && $v <= 3_000_000_000;

    # Milliseconds, which is the one wrong unit an API of this shape produces.
    my $s = int($v / 1000);
    return $s if $s >= 1_000_000_000 && $s <= 3_000_000_000;

    return undef;
}

# THERE IS NO LUN-TO-LUN CLONE. `clone_qsnapshot` clones a SNAPSHOT, and it is
# the only clone there is — so every path through here goes via one.
#
# QuTS HERO ONLY. There the call without a destination pool is an INSTANT
# clone: the new LUN shares the snapshot's blocks instead of copying them, which
# is what makes a Proxmox VE linked clone actually cheap. The snapshot then
# backs the clone and must not be removed, which is why `create_base` leaves one
# behind and why `free_image` explains itself when it cannot delete one.
#
# NOT wrapped in `_fork_claim`: PVE's own `vdisk_clone` already holds the
# storage lock around this call, and taking a cfs storage lock twice in one
# process deadlocks. It reads the claim instead.
sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    my (undef, undef, undef, undef, undef, $src_is_base) =
        $class->parse_volname($volname);

    my $api = $class->_api($storeid, $scfg);
    $class->_remember_nas_kind($storeid, $api);

    # QuTS HERO ONLY. `volume_has_feature` does not offer a clone on QTS, so
    # PVE does not get here on one. This is for a caller that did not ask, and
    # for a kind on file that has gone stale.
    if (!$api->is_zfs) {
        eval { $api->logout };
        die "storage '$storeid': this NAS runs QTS, and this plugin does not"
          . " make linked clones or clones from a snapshot on QTS: a clone"
          . " there takes longer than Proxmox VE allows a storage operation to"
          . " run. Make a full clone instead (qm clone <vmid> <newid> --full"
          . " 1). QuTS hero h5.x has instant clones.\n";
    }

    # Not while a rollback is running: see `_fork_claim`.
    if (my $busy = $class->_fork_busy($storeid)) {
        eval { $api->logout };
        die "storage '$storeid': a clone cannot start, because this plugin runs"
          . " one rollback or clone on a NAS at a time and another is still"
          . " running: $busy->{text}. Wait for it to finish. If that task was"
          . " killed and the NAS is idle, remove $busy->{file}.\n";
    }

    my $lun = $class->_lun($api);
    my $src = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $volname);
    my $obj = $lun->get($src) or die "storage '$storeid': no LUN '$src'\n";

    my $target = $class->find_free_diskname($storeid, $scfg, $vmid, 'raw');
    my $dst = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $target);

    my $snapshot_id;

    if (defined $snap) {
        my ($found) = grep { ($_->{snapname} // '') eq $snap }
                           @{ $lun->snapshot_list($obj->{index}) };
        die "storage '$storeid': '$src' has no snapshot '$snap'\n" if !$found;
        $snapshot_id = $found->{id};

    } elsif ($src_is_base) {
        # A TEMPLATE. Its snapshot is permanent and shared: every linked clone
        # of the template hangs off the same one, `create_base` made it, and
        # nothing removes it while the template exists.
        my $all = $lun->snapshot_list($obj->{index}, all => 1);
        my ($base) = grep {
            PVE::Storage::Custom::QNAP::Naming::is_temp_snapshot_name($_->{name})
        } @$all;

        if ($base) {
            $snapshot_id = $base->{id};
        } else {
            # A template made by an older version, or one whose snapshot was
            # removed by hand. Make it now rather than refusing: the template is
            # perfectly usable and this is the only thing missing.
            my $tmp = PVE::Storage::Custom::QNAP::Naming::temp_snapshot_name(
                'base', $obj->{index});
            $snapshot_id = $lun->snapshot_create(
                lun_index   => $obj->{index},
                name        => $tmp,
                description => "Proxmox VE $storeid template base");
        }

    } else {
        # AN ORDINARY DISK, so the snapshot is scaffolding and MUST be fresh.
        #
        # Reusing one left over from a previous clone is the bug this branch
        # exists to avoid: on QuTS hero an instant clone keeps its snapshot as
        # its backing store, so the snapshot from clone #1 survives — and a
        # second clone that adopted it would silently be a copy of the disk AS
        # IT WAS at the first clone, not as it is now. The operator would get a
        # VM built from stale data with nothing anywhere reporting a problem.
        #
        # The name therefore carries the destination, which is unique on this
        # storage by construction, rather than being looked up by shape.
        my $tmp = PVE::Storage::Custom::QNAP::Naming::temp_snapshot_name(
            'clone', $target);
        # A leftover under the same name — a previous clone to this name that
        # failed partway — is removed rather than adopted, for the same reason.
        my ($stale) = grep { ($_->{name} // '') eq $tmp }
                           @{ $lun->snapshot_list($obj->{index}, all => 1) };
        eval { $lun->snapshot_delete($stale->{id}) } if $stale;

        $snapshot_id = $lun->snapshot_create(
            lun_index   => $obj->{index},
            name        => $tmp,
            description => "Proxmox VE $storeid clone source");
        # Kept. An instant clone has this snapshot as its backing store and
        # would lose it with it, and `free_image` on the source explains itself
        # if it then cannot delete it.
    }

    # Map the clone onto this storage's target as it is created: the alternative
    # is a window in which the LUN exists and no node can reach it.
    my $t = $class->_ensure_target($api, $storeid, $scfg, $target);

    my $new = eval {
        $lun->clone_from_snapshot(
            snapshot_id  => $snapshot_id,
            name         => $dst,
            pool_id      => $class->_pool($scfg),
            instant      => 1,
            target_index => $t->{index},
        );
    };
    my $err = $@;

    if (!$new) {
        eval { $api->logout };
        die $err;
    }

    # `clone_qsnapshot` takes a `targetIndex`, but whether the LUN is then
    # ENABLED on that target is unmeasured — and a mapped-but-disabled LUN
    # presents no device at all.
    eval { $lun->set_enabled_on_target($new->{index}, $t->{index}, 1) };

    eval { $api->logout };

    my ($base) = $volname =~ m{^(base-\d+-\S+)};
    return $base ? "$base/$target" : $target;
}

# A template.
#
# Two things happen, and the second is what makes a linked clone possible at
# all: the LUN is renamed so PVE can tell a base from a disk, and a permanent
# snapshot is taken for every future clone to hang off. Without the snapshot
# there is nothing for `clone_qsnapshot` to clone — QTS has no LUN-to-LUN clone.
#
# The snapshot is given a temp-shaped name deliberately, so that it does NOT
# appear in the GUI as a snapshot an operator could roll back to or delete. It
# is scaffolding, not a restore point.
sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my ($vtype, $leaf, $vmid, $basename, $basevmid, $isBase) =
        $class->parse_volname($volname);
    die "storage '$storeid': '$volname' is already a template\n" if $isBase;

    my $newname = $leaf;
    $newname =~ s/^vm-/base-/;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);
    my $old = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $leaf);
    my $new = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $newname);

    my $obj = $lun->get($old) or die "storage '$storeid': no LUN '$old'\n";
    die "storage '$storeid': a LUN named '$new' already exists\n"
        if $lun->get($new);

    my $renamed = $lun->rename($obj, $new);

    # QTS: a template there is cloned by PVE itself, a full clone that reads the
    # disk, so there is nothing for a base snapshot to do except occupy one of
    # the NAS's snapshot slots.
    $class->_remember_nas_kind($storeid, $api);
    if (!$api->is_zfs) {
        eval { $api->logout };
        return $newname;
    }

    my $tmp = PVE::Storage::Custom::QNAP::Naming::temp_snapshot_name(
        'base', $renamed->{index});
    my $have = $lun->snapshot_list($renamed->{index}, all => 1);
    if (!grep { ($_->{name} // '') eq $tmp } @$have) {
        eval {
            $lun->snapshot_create(
                lun_index   => $renamed->{index},
                name        => $tmp,
                description => "Proxmox VE $storeid template base");
        };
        if ($@) {
            my $err = $@;
            eval { $api->logout };
            die "storage '$storeid': '$newname' was renamed but the base"
              . " snapshot every linked clone hangs off could not be taken."
              . " Linked clones of this template will not work until it"
              . " exists.\n$err";
        }
    }

    eval { $api->logout };
    return $newname;
}

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;

    my $api = $class->_api($storeid, $scfg);
    my $lun = $class->_lun($api);

    my (undef, $leaf) = $class->parse_volname($source_volname);
    $target_volname //= $class->find_free_diskname($storeid, $scfg, $target_vmid, 'raw');

    my $old = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $leaf);
    my $new = PVE::Storage::Custom::QNAP::Naming::lun_name($storeid, $target_volname);

    my $obj = $lun->get($old) or die "storage '$storeid': no LUN '$old'\n";
    die "storage '$storeid': a LUN named '$new' already exists\n"
        if $lun->get($new);

    $lun->rename($obj, $new);
    eval { $api->logout };
    return "$storeid:$target_volname";
}

# Nothing here decides base vs current by looking at the volname STRING:
# `base-100-disk-0/vm-101-disk-0` starts with `base-` and is a linked clone, and
# reading it that way answers "no" to snapshot and rename for every linked clone
# on the storage.
sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) = @_;

    my (undef, undef, undef, $basename, undef, $isBase) =
        eval { $class->parse_volname($volname) };
    return 0 if $@;

    my $features = {
        snapshot   => { current => 1, snap => 1 },

        # `clone` from a snapshot and from a template both go through
        # `clone_qsnapshot`. `current` is claimed too, and it costs a snapshot,
        # which `clone_image` takes itself.
        #
        # QuTS HERO ONLY, decided below. On QTS that call copies the whole
        # disk, PVE runs it under a lock it aborts after 60 seconds, and the
        # NAS would carry on copying into a disk no guest owns.
        clone      => { base => 1, current => 1, snap => 1 },
        template   => { current => 1 },

        # NO `snap` HERE, and that is a correction rather than an omission.
        #
        # `copy` means PVE reads the source data ITSELF — `qm clone --full
        # --snapshot <name>` asks for exactly this — and a yes sends it to
        # `qemu-img convert` on `path($scfg, $volname, $storeid, $snapname)`.
        # That call DIES: a QNAP LUN has no device at a snapshot, so there is
        # nothing to read from until the snapshot is cloned or rolled back.
        #
        # Declaring it would make PVE start an operation and fail partway, with
        # a message about addressing rather than about the operation. Saying no
        # makes it refuse up front with "Full clone feature is not supported for
        # a snapshot of ...", which an operator can act on — and the action is a
        # linked clone, which this storage does support.
        copy       => { base => 1, current => 1 },
        sparseinit => { base => 1, current => 1 },
        rename     => { current => 1 },
    };

    my $key = defined $snapname ? 'snap' : ($isBase ? 'base' : 'current');
    return undef if !$features->{$feature}->{$key};

    # Offered only where it is known to be QuTS hero. Not known is not offered.
    return undef if $feature eq 'clone' && !$class->_nas_is_zfs($storeid, $scfg);

    return 1;
}

1;
