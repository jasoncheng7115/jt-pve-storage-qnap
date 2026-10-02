# Which QNAP operating systems this plugin supports

Short version: **QTS 5.1 and QuTS hero h5.1 are what it is written against.**
Anything older than QTS 4.5.1 is refused when the storage is added, not
discovered later. **QuTS hero h6.0 and later are not supported yet**, and are
refused the same way.

This page is deliberately specific about the difference between *supported*,
*expected to work* and *not supported*, because two of those are promises and
one is not.

---

## 1. The hard requirement: Storage Manager V2

QNAP has two generations of Storage Manager and they are **different sets of CGI
calls**, not two versions of one API. This plugin implements V2 only.

The firmware says which it has. `authLogin.cgi` returns:

| `<storage_v2>` | `<is_zfs>` | What it is | This plugin |
|---|---|---|---|
| absent, or `0` | any | Legacy Storage Manager | **Refused** |
| `1` | `0` | Storage Manager V2 on LVM (QTS) | Supported |
| `1` | `1` | ZFS (QuTS hero) | Supported on h5.x, and gets instant clones. **Refused** on h6.0 and later |

`pvesm add` calls this before it writes anything, so a firmware that is too old
fails immediately with a message naming its version, rather than producing a
storage that adds cleanly and then lists nothing.

QuTS hero h6.0 and later report Storage Manager V2 as well, and this plugin
still does not work on them. That one is decided from the firmware version, and
is refused at the same moment. See section 3.

To check before you install anything:

```
pve-qnap-api-probe --host <nas> --user admin --insecure
```

---

## 2. The matrix

| Operating system | Version | Status | Notes |
|---|---|---|---|
| **QTS** | **5.1.x** | **Supported** | The firmware generation this plugin is written for |
| QTS | 5.2.x | Expected to work | Same API family; not verified. Report what you find. |
| QTS | 4.5.1 to 5.0.x | Expected to work | The first release with `storage_v2`. Not verified. |
| QTS | 4.5.0 and older | **Not supported** | Legacy Storage Manager. Refused at `pvesm add`. |
| **QuTS hero** | **h5.1.x** | **Supported** | ZFS. Instant clones, so a Proxmox VE linked clone is instant |
| QuTS hero | h5.2.x | Expected to work | Not verified |
| QuTS hero | h4.5.x to h5.0.x | Expected to work | Not verified |
| QuTS hero | h6.0 and later | **Not supported yet** | Measured on h6.0.1. Refused at `pvesm add`. See section 3 |
| QuTScloud | any | **Not supported** | A cloud image with no local storage pools of this shape |
| QNE Network OS | any | **Not supported** | A different product; it has no Storage Manager |
| QTS on a TR-series expansion unit | any | n/a | An expansion unit is not a NAS |

"Expected to work" means nothing in what this plugin uses is known to differ.
It does not mean anyone has run it. Treat it as you would any untested
combination.

---

## 3. QuTS hero h6.0 and later: not supported yet

This is the one entry in the matrix that was measured rather than read. The
plugin was run against a NAS on QuTS hero h6.0.1:

| | Result on h6.0.1 |
|---|---|
| Logging in, and reading the model, the firmware and the two discriminators | Works |
| `pve-qnap-api-probe`: the portal, the storage pool, the LUNs, the targets | Works |
| Creating the storage's iSCSI target | **Refused by the NAS** |
| Creating a LUN | **Refused by the NAS** |

So a storage on h6 could be described and could hold nothing. From 0.6.1 the
plugin refuses QuTS hero h6.0 and later when the storage is added, before it
sends anything the NAS would refuse, and the message names the firmware.

**Do not upgrade a NAS that already holds this plugin's disks to QuTS hero
h6.** After such an upgrade the storage still reports its capacity and still
lists its disks, and no disk can be created or deleted. The plugin's refusals
name the firmware when that happens. Whether guests that are already running
keep their disks across the upgrade has not been measured.

---

## 4. QTS or QuTS hero? Linked clones exist on QuTS hero only

Both are supported. The difference is one operation, and it is a big one.

Every clone this plugin makes is made on the NAS, from a snapshot. On **QuTS
hero** that is an *instant* clone that shares the snapshot's blocks, so a linked
clone is immediate and takes no extra space. On **QTS** a clone copies the whole
disk, and Proxmox VE aborts a storage-side clone that runs longer than 60
seconds. So on QTS the plugin does not offer one: Proxmox VE refuses a linked
clone, or a clone from a snapshot, before it starts.

| | QTS (LVM) | QuTS hero (ZFS) |
|---|---|---|
| Snapshot | yes | yes |
| Rollback | yes. Takes as long as the NAS needs to write the disk back | yes |
| Linked clone, clone from a snapshot | **not offered** | instant |
| Template | yes, cloned with a full clone | yes |
| Full clone | copied by Proxmox VE | copied by Proxmox VE |
| Template deployment at scale | slow | fast |

If you are choosing hardware for a Proxmox VE cluster and expect to deploy from
templates, this is the deciding factor.

**On QTS, clone a template with a full clone**: `qm clone <vmid> <newid>
--full 1`, or *Mode: Full Clone* in the web interface. Proxmox VE copies the
data itself and is under no such limit.

The plugin runs one rollback or clone on a NAS at a time. A second one started
meanwhile, from any node, is refused with a message that says what is running,
on which node and since when.

One consequence to know about on QuTS hero: an instant clone keeps the snapshot
it was made from as its backing store. The plugin therefore leaves a snapshot on
a template, and deleting a template while linked clones still exist fails with
a message that quotes what the NAS answered.

---

## 5. Model requirements, which are not the same as firmware

A model can run a supported firmware and still not do what is needed.

* **iSCSI target service.** Every NAS in scope has it, but it ships **off**.
  Turn it on in *Storage & Snapshots → iSCSI & Fibre Channel*. The plugin
  refuses to add a storage while it is off and says so.
* **A storage pool.** This plugin creates block-based LUNs, which live in a
  pool. A NAS whose disks are configured as static volumes has no pool for them.
* **Snapshots.** QNAP's entry-level models do not support snapshots of iSCSI
  LUNs at all, and **this plugin has no way to check that in advance**. It
  warns when the storage is added and asks you to take one snapshot of a test
  disk before relying on the feature. Check your model's specification page for
  "Snapshot".
* **Enough LUNs.** One VM disk is one LUN. QNAP publishes 128 for QTS and 256
  for QuTS hero, and the plugin reads the ceiling from the NAS rather than
  assuming. `pve-qnap-api-probe` prints it. It is the real limit of this
  storage, and no amount of free space changes it. See [LIMITS.md](LIMITS.md).

---

## 6. Proxmox VE

| | Version |
|---|---|
| Proxmox VE | 9.x. 8.x is expected to work, because the storage API version is negotiated down to 10, and it has never been tested |
| Storage plugin API | 10 to 15, negotiated at load time |

The API version is negotiated rather than hardcoded, because claiming a version
higher than the node's makes PVE reject the plugin outright and every storage of
this type disappears from that node.

The package must be installed **on every node of the cluster**.

---

## 7. If your combination is not listed

Run the probe and send its output. It prints the model, the firmware, both
detection flags, the ceilings and the pools, and it creates nothing:

```
pve-qnap-api-probe --host <nas> --user admin --insecure --node
```
