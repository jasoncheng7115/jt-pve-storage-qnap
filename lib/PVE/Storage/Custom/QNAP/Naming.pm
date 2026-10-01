package PVE::Storage::Custom::QNAP::Naming;

# Array object names, and the ownership gate.
#
# This module answers one question that matters more than the rest: **may this
# plugin delete this object?** Getting it wrong in the permissive direction
# destroys someone else's data, so the gate takes the storage id and not just
# the shape of a name — a prefix identifies the STORAGE, never the kind of
# object, and every disk on a storage passes a bare prefix test.
#
# WHAT QTS ACCEPTS IN A LUN NAME.
#
# **An underscore is legal**, which is the one character that forced the
# related Synology plugin into a lossy fold of the storage id. Nothing here has
# to be folded away for QTS, and `pve-<storeid>-vm-100-disk-0` reaches the NAS
# unchanged.
#
# Everything beyond that underscore is UNVERIFIED. The rest of the legal set,
# and the maximum length, have not been measured on
# hardware — see docs/TESTING.md, which lists both as open. So this module is
# deliberately strict rather than permissive: it accepts the characters Proxmox
# VE can actually produce, refuses anything else BEFORE it reaches the NAS, and
# names the offending character when it refuses. A refusal here is a message an
# operator can act on; the same name sent to QTS comes back as a bare negative
# `<result>`.
#
# A TARGET NAME IS NOT A LUN NAME, and that is not a style choice. QTS builds a
# target's IQN itself, as
#
#     <targetIQNPrefix> + <targetName> + <targetIQNPostfix>
#
# — something like `iqn.2004-04.com.qnap:<model>:iscsi.` and `.<suffix>`. So a
# target name becomes part of an IQN, whose grammar is much
# narrower than a LUN name's: lower case, digits, `.` and `-`. `target_name`
# folds to exactly that.

use strict;
use warnings;

# Everything here is a plain function, not a method. Calling one as
# `Naming->is_pve_managed_volume($name, $storeid)` shifts the arguments along
# and the gate then answers "not owned" for an object that IS owned — safe, but
# silently wrong, and a listing would simply come back empty with no error to
# explain it.
sub _not_a_method {
    my ($first) = @_;
    return if !defined $first;
    return if $first ne __PACKAGE__;
    die __PACKAGE__ . ": these are functions, not methods. Call"
      . " Naming::name(...) rather than Naming->name(...).\n";
}

use constant {
    # Marks the objects this plugin owns. Not sufficient on its own — see the
    # note above about a prefix identifying only the storage.
    PREFIX => 'pve',

    # QTS publishes no maximum for a LUN name. 64 is chosen to be comfortably
    # under every limit this family has met on any array while still leaving
    # room for the longest name Proxmox VE generates. Listed in docs/TESTING.md
    # as unverified.
    MAX_NAME => 64,

    # The storage id's share of that budget. The longest volume name PVE
    # produces is a state volume, `vm-<vmid>-state-<snapname>`, and a snapshot
    # name is capped at 40 characters by PVE itself — so a fold of 16 plus
    # `pve-` plus a 60-character leaf can exceed MAX_NAME. `lun_name` checks the
    # assembled result rather than trusting this budget, which is why the check
    # is there and not here.
    MAX_STOREID_FOLD => 16,
};

# THE STOREID AS A FILENAME COMPONENT — sanitised AND untainted, in one place.
#
# Three modules build this string: the credential store, the WWID state file and
# the credential latch. All three sanitise the same way and none of them would
# untaint, because `s///` does not untaint — only a capture does. Under
# `pvedaemon`'s `-T` that is the difference between a file being written and:
#
#   Insecure dependency in unlink while running with -T switch
#
# The sanitising was never the weak part: PVE's own storage-id rules are
# stricter than this, and a `../` could not have got through. What is missing is
# that Perl has no way to know that, and telling it requires the match to
# CAPTURE. So the validation and the untainting are the same operation here.
#
# Returns undef when nothing usable is left — the callers all treat that as
# "this storage cannot have a file", which is the safe answer.
sub filename_component {
    _not_a_method($_[0]);
    my ($storeid) = @_;
    return undef if !defined $storeid;

    (my $safe = $storeid) =~ s/[^A-Za-z0-9_.-]/_/g;
    $safe =~ s/\A\.+//;

    # The capture is the untaint. Matching without capturing would leave the
    # value tainted and the whole point of this function unmet.
    return undef if $safe !~ /\A([A-Za-z0-9_.-]+)\z/;
    return $1;
}

# The storage id as it appears inside a LUN name.
#
# QTS accepts `_`, so unlike the Synology plugin this fold does NOT have to
# collapse it — which removes that project's worst structural hazard, where
# `syno_1` and `syno-1` became the same prefix and each storage could delete the
# other's disks. Case is still folded, because a NAS that compares names
# case-insensitively would reintroduce exactly that collision, and whether QTS
# does is unmeasured.
sub fold_storeid {
    _not_a_method($_[0]);
    my ($storeid) = @_;
    return '' if !defined $storeid;
    my $s = lc $storeid;
    $s =~ s/[^a-z0-9_-]/-/g;
    $s =~ s/-+/-/g;          # a run of illegal characters is one hyphen
    $s =~ s/\A[-_]+//;
    $s =~ s/[-_]+\z//;
    $s = substr($s, 0, MAX_STOREID_FOLD) if length($s) > MAX_STOREID_FOLD;
    $s =~ s/[-_]+\z//;       # truncation must not leave a trailing separator
    return $s;
}

# Whether two storage ids would produce the same names on one NAS. `on_add_hook`
# uses this to refuse the second one: they are indistinguishable afterwards, and
# each could delete the other's disks.
#
# With `_` surviving the fold this is far less likely than on Synology, but it is
# NOT impossible: the fold lower-cases and truncates at MAX_STOREID_FOLD, so
# `QnapProduction1` and `qnapproduction2` still collide at 16 characters. The
# guard stays.
sub fold_collides_with {
    _not_a_method($_[0]);
    my ($storeid, $other) = @_;
    return 0 if !defined $storeid || !defined $other;
    return 0 if $storeid eq $other;
    return fold_storeid($storeid) eq fold_storeid($other) ? 1 : 0;
}

sub prefix_for {
    _not_a_method($_[0]);
    my ($storeid) = @_;
    my $fold = fold_storeid($storeid);
    die "storage id '" . ($storeid // '') . "' contains no character that can"
      . " appear in a QNAP LUN name\n" if !length $fold;
    return PREFIX . '-' . $fold;
}

# EVERY VOLUME NAME PROXMOX VE CONSTRUCTS, read out of PVE rather than guessed.
# A pattern ending in `\w*` covers neither a hyphen nor three whole forms, and
# the cost is visible: a snapshot named `open-ap` taken with RAM is refused with
# "is not a Proxmox VE disk name", because PVE asks for `vm-146-state-open-ap`
# and `\w` does not match `-`. A pve-configid is `[a-z][a-z0-9_-]+`, so both `_`
# and `-` are ordinary in a snapshot name.
#
#   (vm|base)-<vmid>-disk-<n>        an ordinary disk, and a template's
#   vm-<vmid>-cloudinit              the cloud-init drive
#   vm-<vmid>-state-<snapname>       a snapshot taken WITH RAM
#   vm-<vmid>-efi-enroll             enrolling secure-boot keys
#   vm-<vmid>-fleece-<n>             backup fleecing
#   vm-<vmid>-tpmstate<n>            the TPM's state
#
# Anchored with \z and not $, because `$` also matches before a trailing newline
# and "vm-100-disk-0\n" would then resolve to the same object.
my $PVE_DISK = qr{
    \A
    (?:   (?: vm | base ) - \d+ - disk - \d+
        | vm - \d+ - cloudinit
        | vm - \d+ - state - [A-Za-z][A-Za-z0-9_-]*
        | vm - \d+ - efi-enroll
        | vm - \d+ - fleece - \d+
        | vm - \d+ - tpmstate \d+
    )
    \z
}x;

sub is_pve_disk_name {
    _not_a_method($_[0]);
    my ($name) = @_;
    return 0 if !defined $name;
    return $name =~ $PVE_DISK ? 1 : 0;
}

# PVE hands a linked clone's volname as `base-100-disk-0/vm-101-disk-0`. The
# LEAF is the object on the array; the part before the slash is its parent, and
# it is not part of this object's name.
sub leaf_of {
    _not_a_method($_[0]);
    my ($volname) = @_;
    return undef if !defined $volname;
    my @parts = split m{/}, $volname;
    return $parts[-1];
}

# THE ONE RULE THIS FILE EXISTS TO KEEP: nothing with a character QTS might
# refuse may leave for the array.
#
# The set is what Proxmox VE produces and no more. It is deliberately narrower than
# whatever QTS really allows: being refused here costs an error message, being
# refused by the NAS costs a negative `<result>` with no explanation at all, and
# on some arrays in this family a refused create makes the object anyway.
my $QTS_LUN_OK = qr/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;

sub assert_qts_legal {
    _not_a_method($_[0]);
    my ($name) = @_;

    if (defined $name && length $name && length($name) > MAX_NAME) {
        die "storage: the LUN name '$name' is " . length($name)
          . " characters, longer than the " . MAX_NAME . " this plugin will"
          . " send. Use a shorter storage id.\n";
    }
    return $name if defined $name && $name =~ $QTS_LUN_OK;

    my $shown = defined $name ? $name : '(undef)';
    my ($bad) = defined $name ? ($name =~ /([^A-Za-z0-9._-])/) : ();
    die "storage: the LUN name '$shown' cannot be sent to QTS"
      . (defined $bad ? ": it contains '$bad'"
       : !defined $name || !length $name ? ": it is empty"
       : ": it does not start with a letter or digit")
      . ". This plugin sends letters, digits, '-', '.' and '_' only.\n";
}

sub lun_name {
    _not_a_method($_[0]);
    my ($storeid, $volname) = @_;
    my $leaf = leaf_of($volname);
    die "cannot build a LUN name from an empty volume name\n"
        if !defined $leaf || !length $leaf;
    die "'$leaf' is not a Proxmox VE disk name\n" if !is_pve_disk_name($leaf);
    return assert_qts_legal(prefix_for($storeid) . '-' . $leaf);
}

# THE OWNERSHIP GATE.
#
# Takes the storage id, not merely a name that looks like some PVE plugin's.
# Both halves are required: the prefix says which storage, and the remainder
# must be a PVE disk name — otherwise every object on the NAS whose name starts
# with the prefix would qualify, including ones this plugin did not create.
sub is_pve_managed_volume {
    _not_a_method($_[0]);
    my ($name, $storeid) = @_;
    return 0 if !defined $name || !defined $storeid;

    my $prefix = eval { prefix_for($storeid) };
    return 0 if !defined $prefix;

    return 0 if index($name, "$prefix-") != 0;

    my $leaf = substr($name, length($prefix) + 1);
    return is_pve_disk_name($leaf) ? 1 : 0;
}

# The reverse: what PVE calls the object whose LUN has this name. Returns undef
# for anything this storage does not own, so a listing can filter with it.
sub volname_from_lun_name {
    _not_a_method($_[0]);
    my ($name, $storeid) = @_;
    return undef if !is_pve_managed_volume($name, $storeid);
    my $prefix = prefix_for($storeid);
    return substr($name, length($prefix) + 1);
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

# A target name that QTS can turn into a legal IQN. See the note at the top:
# the NAS concatenates its own prefix and postfix around this, so the grammar
# here is an IQN's and not a LUN name's.
#
# The IQN itself is never built here and never compared against. It is read back
# from the NAS, because the prefix embeds the NAS's model and hostname AS THEY
# WERE when the target was created — a renamed NAS carries targets with two
# different prefixes, and a plugin that derived the IQN from the current one
# would fail to recognise its own targets.
sub target_name {
    _not_a_method($_[0]);
    my ($storeid, $leaf) = @_;

    my $n = PREFIX . '-' . fold_storeid($storeid) . '-tgt';
    if (defined $leaf && length $leaf) {
        $n .= '-' . lc $leaf;
    }
    $n =~ s/[^a-z0-9.-]/-/g;
    $n =~ s/-+/-/g;
    $n =~ s/\A-+//;
    $n =~ s/-+\z//;
    die "storage id '" . ($storeid // '') . "' produces no usable iSCSI target"
      . " name\n" if !length $n;
    return $n;
}

sub target_prefix_for {
    _not_a_method($_[0]);
    my ($storeid) = @_;
    return PREFIX . '-' . fold_storeid($storeid) . '-tgt';
}

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

# A QTS LUN SNAPSHOT CARRIES NO `taken_by`, AND THAT CHANGES THE OWNERSHIP RULE.
#
# The related Synology plugin can tell its own snapshots from the operator's
# because DSM records who took each one. The QTS snapshot list — Storage Manager
# returns `snapshot_id`, `snapshot_name`,
# `create_time`, `status` and progress fields, and **nothing that identifies the
# creator**. A description can be set afterwards, but the listing does not return
# it either.
#
# So ownership has to live in the NAME, and it is the only thing standing between
# `qm destroy` and an operator's own scheduled snapshot of the same LUN. Every
# snapshot this plugin takes is named `pve-<snapname>`; nothing without that
# prefix is ever listed to PVE, rolled back to, or deleted.
use constant SNAP_PREFIX => PREFIX . '-';

sub snapshot_name {
    _not_a_method($_[0]);
    my ($snapname) = @_;
    die "a snapshot needs a name\n" if !defined $snapname || !length $snapname;

    # PVE's own limit, respected rather than the array's being approached: a
    # pve-configid is at most 40 characters.
    die "snapshot name '$snapname' is longer than 40 characters\n"
        if length($snapname) > 40;

    # A configid is `[a-z][a-z0-9_-]+`, so this can only fail if PVE's rules
    # change. It fails here rather than at the NAS if it ever does.
    die "snapshot name '$snapname' contains a character this plugin will not"
      . " send to QTS. Proxmox VE snapshot names are letters, digits, '-' and"
      . " '_'.\n" if $snapname !~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;

    return SNAP_PREFIX . $snapname;
}

# The reverse. undef for a snapshot this plugin did not take — which is how the
# operator's own snapshots stay invisible to PVE and therefore undeletable by it.
sub snapname_from_snapshot_name {
    _not_a_method($_[0]);
    my ($name) = @_;
    return undef if !defined $name;
    my $p = SNAP_PREFIX;
    return undef if index($name, $p) != 0;
    # A temporary snapshot is this plugin's own scaffolding — `clone_image`
    # leaves one behind to hold an instant clone up. It must not be reported to
    # PVE as a snapshot of the disk: it would appear in the GUI as something the
    # operator could roll back to, and deleting it would break the clone that
    # depends on it.
    return undef if is_temp_snapshot_name($name);
    my $snap = substr($name, length $p);
    return length($snap) ? $snap : undef;
}

# Temporary objects this plugin creates and must be able to remove unattended.
#
# `clone_image` needs one: QTS has no LUN-to-LUN clone at all — Storage Manager
# `clone_qsnapshot` is the only clone there is, and it clones a
# SNAPSHOT. So cloning a live disk means taking a snapshot first, and that
# snapshot has to be named so that it is unmistakably ours AND unmistakably not
# a PVE snapshot an operator would expect to see in the GUI.
sub temp_snapshot_name {
    _not_a_method($_[0]);
    my ($purpose, $token) = @_;
    $purpose //= 'tmp';
    $purpose =~ s/[^a-z0-9]//g;
    $token   //= '';
    $token   =~ s/[^A-Za-z0-9]//g;
    return SNAP_PREFIX . 'tmp-' . $purpose . ($token ? "-$token" : '');
}

sub is_temp_snapshot_name {
    _not_a_method($_[0]);
    my ($name) = @_;
    return 0 if !defined $name;
    return index($name, SNAP_PREFIX . 'tmp-') == 0 ? 1 : 0;
}

1;
