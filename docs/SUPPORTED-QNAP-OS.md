# Which QNAP operating systems this plugin supports

Short version: **QTS 5.1 and QuTS hero h5.1 are what it is written against.**
Anything older than QTS 4.5.1 is refused when the storage is added, not
discovered later.

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
| absent, or `0` | — | Legacy Storage Manager | **Refused** |
| `1` | `0` | Storage Manager V2 on LVM — QTS | Supported |
| `1` | `1` | ZFS — QuTS hero | Supported, and gets instant clones |

`pvesm add` calls this before it writes anything, so a firmware that is too old
fails immediately with a message naming its version, rather than producing a
storage that adds cleanly and then lists nothing.

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
| QTS | 4.5.1 – 5.0.x | Expected to work | The first release with `storage_v2`. Not verified. |
| QTS | 4.5.0 and older | **Not supported** | Legacy Storage Manager. Refused at `pvesm add`. |
| **QuTS hero** | **h5.1.x** | **Supported** | ZFS. Instant clones, so a Proxmox VE linked clone is instant |
| QuTS hero | h5.2.x | Expected to work | Not verified |
| QuTS hero | h4.5.x – h5.0.x | Expected to work | Not verified |
| QuTScloud | any | **Not supported** | A cloud image with no local storage pools of this shape |
| QNE Network OS | any | **Not supported** | A different product; it has no Storage Manager |
| QTS on a TR-series expansion unit | — | n/a | An expansion unit is not a NAS |

"Expected to work" means nothing in what this plugin uses is known to differ —
not that anyone has run it. Treat it
as you would any untested combination.

---

## 3. QTS or QuTS hero? It changes what a clone costs

Both are supported and the plugin works on either. The difference is one
operation, and it is a big one.

Every clone this plugin makes is made from a snapshot. On **QTS** that clone is
a copy: a linked clone of a 200 GB template writes 200 GB and takes as long as a
full clone. On **QuTS hero** it is an *instant* clone that shares the snapshot's
blocks, so a linked clone is immediate and takes no extra space.

| | QTS (LVM) | QuTS hero (ZFS) |
|---|---|---|
| Snapshot | yes | yes |
| Rollback | yes | yes |
| Linked clone (`qm clone`) | works, but **copies** | instant |
| Full clone | copies | copies |
| Template deployment at scale | slow | fast |

If you are choosing hardware for a Proxmox VE cluster and expect to deploy from
templates, this is the deciding factor.

One consequence to know about on QuTS hero: an instant clone keeps the snapshot
it was made from as its backing store. The plugin therefore leaves a snapshot on
a template, and deleting a template while linked clones still exist fails — with
a message that says exactly that, rather than a bare error number.

---

## 4. Model requirements, which are not the same as firmware

A model can run a supported firmware and still not do what is needed.

* **iSCSI target service.** Every NAS in scope has it, but it ships **off**.
  Turn it on in *Storage & Snapshots → iSCSI & Fibre Channel*. The plugin
  refuses to add a storage while it is off and says so.
* **A storage pool.** This plugin creates block-based LUNs, which live in a
  pool. A NAS whose disks are configured as static volumes has no pool for them.
* **Snapshots.** QNAP's entry-level models do not support snapshots of iSCSI
  LUNs at all, and **this plugin has no way to check that in advance**. It warns when the storage is added
  and asks you to take one snapshot of a test disk before relying on the
  feature. Check your model's specification page for "Snapshot".
* **Enough LUNs.** One VM disk is one LUN. The ceiling is per model and the
  plugin reads it from the NAS rather than assuming; `pve-qnap-api-probe` prints
  it. It is the real limit of this storage, and no amount of free space changes
  it.

---

## 5. Proxmox VE

| | Version |
|---|---|
| Proxmox VE | 8.0 or later |
| Storage plugin API | 10 – 15, negotiated at load time |

The API version is negotiated rather than hardcoded, because claiming a version
higher than the node's makes PVE reject the plugin outright and every storage of
this type disappears from that node.

The package must be installed **on every node of the cluster**.

---

## 6. If your combination is not listed

Run the probe and send its output — it prints the model, the firmware, both
detection flags, the ceilings and the pools, and it creates nothing:

```
pve-qnap-api-probe --host <nas> --user admin --insecure --node
```
