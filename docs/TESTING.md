# What has been verified, and what has not

Read this before you put data on this storage.

**This plugin has not yet worked against a QNAP NAS.** It has been run against
one, on QuTS hero h6.0.1, where it does not work. On the firmware it is written
for, nothing has been exercised yet. Every release in the 0.x series is a
prerelease and this page is the honest account of where that stands. The related projects in this family
(`jt-pve-storage-synology`, `-netapp`, `-purestorage`, `-dellemc`) reached
stability by measuring an array and writing down what it actually did; this one
is at the start of that process.

## What that means concretely

Everything that talks to the NAS (authentication, iSCSI targets and LUNs,
storage pools, and LUN snapshots) is written from the API documentation for QTS
5.1 and from nothing else. No NAS on supported firmware has answered any of it
yet.

Where the behaviour is known, the plugin follows it. Where it is not, the code
is deliberately strict: it refuses rather than assumes, so a wrong guess
surfaces as a message naming the reason instead of as a bare negative
`<result>` from the NAS.

The plugin has been driven through its whole lifecycle against a simulated NAS,
on a simulated QTS and a simulated QuTS hero. That checks the plugin against
this project's own reading of how a NAS answers. It does not check the reading.

The parts ported from the related projects (the multipath handling, the iSCSI
node management, the bounded command runner, the WWID tracking) **have** been
measured, on other storage. What they protect against is the node's and the
kernel's behaviour, which does not change with the storage vendor.

---

## What a real NAS has answered

One run, with version 0.6.0, against a NAS on QuTS hero h6.0.1:

| | Result |
|---|---|
| The login, sent as a POST | Accepted |
| `storage_v2` and `is_zfs` | Both reported as `1` |
| `pve-qnap-api-probe` | Read the portal, the storage pool, the LUNs and the targets |
| Creating the storage's iSCSI target, at `pvesm add` | **Refused by the NAS** |
| Creating a LUN | **Refused by the NAS** |

So QuTS hero h6.0 and later are not supported, and from 0.6.1 the plugin
refuses them when the storage is added. See
[SUPPORTED-QNAP-OS.md](SUPPORTED-QNAP-OS.md).

That run settled none of the items below. No LUN was created, so no device, no
WWID and no vendor string was seen, and the firmware it ran on is not one this
plugin supports.

---

## Open items, in the order they should be settled

### Blocking: a wrong answer here changes the design

1. **Does `LUNNAA` match `/sys/block/<sd>/device/wwid`?**
   The plugin identifies every device by comparing them. `LUNNAA` is 32 hex
   digits and the kernel reports `naa.<digits>`; if the two ever disagree,
   nothing else in this plugin works.
   *How to check:* create one LUN, attach it, compare
   `pve-qnap-api-probe` output against `cat /sys/block/sdX/device/wwid`.

2. **What does a QNAP LUN report as SCSI vendor and product?**
   The multipath drop-in matches vendor `QNAP` and every product. If the vendor
   string differs, the stanza does not apply and the LUN falls back to
   multipath's generic defaults. Those include `no_path_retry queue`, which is
   an unkillable hang when every path is lost.
   *How to check:* `cat /sys/block/sdX/device/vendor`.

3. **Does `edit_lun` grow a LUN that is mapped and in use?**
   `volume_resize` depends on it. `edit_lun` takes `LUNCapacity`; whether the
   LUN must be unmapped first, or whether a running guest is tolerated, is
   unknown.

4. **Does `add_lun` accept a fractional `LUNCapacity`?**
   The plugin rounds every size up to a whole GiB, because a whole number is
   the only form known to work. If decimals work, that rounding could be
   finer. Rounding up is never wrong, only wasteful, so this is an improvement
   rather than a fix.

### Important: these decide whether an operation is safe

5. **Does `recover_snapshot` with `by_lun=1` keep snapshots NEWER than the one
   restored?** `volume_rollback_is_possible` currently allows the rollback. If
   QTS discards newer snapshots, PVE would silently delete snapshots the
   operator can still see, and the refusal the related projects carry has to be
   added here.

6. **Does the LUN's NAA survive a rollback?** The plugin checks and refuses
   loudly if it changes, because the device identity would have moved underneath
   every node. It has never been seen to happen on any array in this family.

7. **Does `authLogin.cgi` accept a POST?** Every call this plugin makes is a
   POST, so that no credential ever travels in a URL. If a session that was
   just issued is still not recognised by another CGI, the plugin takes that as
   a firmware that did not read the POST body and repeats that call as a GET,
   but only for calls that carry no secret. **The login is never sent as a
   GET**, so a firmware that only reads the query string cannot be used at all.
   This is the single most likely reason for a first run to fail. On QuTS hero
   h6.0.1 the login was accepted as a POST. That firmware is not supported, so
   the question is still open for the ones that are.

8. **Concurrency.** `get_return` is keyed by CGI name rather than by job, so a
   clone and a rollback in flight at once cannot be told apart. The plugin
   serialises both with PVE's cluster storage lock. Worth confirming that
   nothing else on the NAS (a scheduled snapshot job, the web interface) shares
   that channel. What `get_return` wants as `cginame` is unmeasured too:
   the plugin sends `snapshot.cgi`, and if QTS wants something else, a clone or
   a rollback never collects its result.

9. **Session lifetime.** How long a `sid` lasts is unknown. The plugin
   re-logs-in once when a call reports `authPassed 0`.

10. **QTS's Network Access Protection.** The credential latch exists because a
    ten-second poll with a wrong password would lock a node out of the NAS. The
    threshold and the block duration are per-NAS settings; the latch means the
    plugin makes exactly one failed attempt regardless.

11. **Does a logout actually end the session?** The plugin logs in for each
    operation and logs out when it is done, and every node polls every ten
    seconds. The logout carries the `sid` and an explicit `logout=1`. If QTS
    answers the logout and keeps the session anyway, that is six leaked
    sessions a minute per node.
    *How to check:* leave the storage configured for ten minutes and count the
    sessions the NAS itself lists for the plugin's account. The answer has to
    come from the NAS, not from the logout's own reply.

12. **How many LUNs one target will carry, and whether LUNs and targets share
    one ceiling.** With `qnap-target-mode=shared`, the default, every disk on
    the storage is mapped to one target, so that target's ceiling is the
    storage's. The NAS reports a ceiling for LUNs and one for targets, and none
    for LUNs per target. The related Synology plugin measured 200 on one target
    without objection, which says nothing about QTS. If QTS stops lower,
    `qnap-target-mode=per-volume` is the way out, and it trades this ceiling for
    the target one. QNAP's user guides also give 255 for LUNs and targets
    **combined**, while the plugin checks the two separately. See
    [LIMITS.md](LIMITS.md). *How to check:* map LUNs to one target until the NAS
    refuses, and note the count and what it answered.

### Worth knowing

13. **What characters QTS accepts in a LUN name, and the maximum length.** The
    plugin sends letters, digits, `-`, `.` and `_`, capped at 64 characters,
    and refuses anything else before it reaches the NAS. `_` is known to be
    legal; the rest is a conservative guess.

14. **What characters QTS accepts in a snapshot name.** Same treatment.

15. **Is `create_time` in a snapshot listing an epoch?** The plugin reports a
    timestamp only when the value is plausible as one and reports none
    otherwise. Nothing in Proxmox VE 9 reads it.

16. **Whether `bTargetClusterEnable` can be read back.** `targetInfo` does
    not return it, so the plugin writes it at target creation and again on every
    `pvesm set`, and never on the activation path. If a second node cannot log
    in to a target, run `pvesm set <storeid>` to re-apply it.

---

## The first run, in order

Do this on a NAS with nothing on it, or on a pool you are willing to lose.

```
# 1. Read-only. Creates nothing.
pve-qnap-api-probe --host <nas> --user admin --insecure --node

# 2. Add the storage. Every precondition is checked here.
pvesm add qnapsan qnap1 \
    --qnap-portal <nas> --qnap-username admin --qnap-password <pw> \
    --qnap-pool 1 --qnap-ssl-verify 0 \
    --qnap-chap-username pve --qnap-chap-password <secret> \
    --content images

# 3. One disk.
pvesm alloc qnap1 9999 '' 1G
pvesm list qnap1

# 4. Attach it and confirm the identity (item 1 above).
qm create 9999 --scsi0 qnap1:vm-9999-disk-0 --scsihw virtio-scsi-single
qm start 9999
multipath -ll
cat /sys/block/sdX/device/vendor   # item 2

# 5. Snapshot, roll back, and check the data really moved.
qm snapshot 9999 s1
qm stop 9999
qm rollback 9999 s1

# 6. Resize (item 3).
qm resize 9999 scsi0 +1G

# 7. Template and linked clone.
qm template 9999
qm clone 9999 9998

# 8. Clean up, and check the NAS is back to where it started.
qm destroy 9998; qm destroy 9999
pvesm status
```

If step 2 fails with a login error and the probe in step 1 succeeded, item 7 is
the first thing to suspect.

---

## Reporting

Please include the output of `pve-qnap-api-probe --node`, the model, the
firmware version, and whether it is QTS or QuTS hero. The plugin's messages are
written to be quotable. If one of them was not enough to act on, that is itself
a defect worth reporting.
