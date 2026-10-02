# jt-pve-storage-qnap

**Proxmox VE uses a QNAP NAS over iSCSI directly as its VM storage back end.**

Every Proxmox VE VM disk maps to one thin LUN on the NAS. So creating,
removing, resizing, cloning, snapshotting and rolling back a VM all drive the
NAS's own LUN features, instead of carving one large shared LUN up with LVM on
the PVE side. You can look at a disk in *Storage & Snapshots* and know which VM
it belongs to.

**No extra LVM storage layer, and no LUNs to manage by hand.**

QTS · QuTS hero · Shared Storage · Live Migration · Snapshot / Rollback ·
Clone · Multipath. Registers the storage type **`qnapsan`**.

[English](README.md) · [繁體中文](README_zh-TW.md) · **[Documentation site](https://jasoncheng7115.github.io/jt-pve-storage-qnap/)**

---

## ⚠️ TESTED ON ONE QNAP NAS SO FAR

**So far this plugin has been tested on one QNAP NAS.**

**QuTS hero h6.0 and later are not supported**, and the plugin refuses them when
the storage is added.

It is written from the API documentation alone. It compiles, it passes 247 unit
tests, and it has been driven through its whole lifecycle against a simulated
NAS. **None of that proves it works on your NAS.**

| | |
|---|---|
| **Do NOT** | put production data on it, point it at a NAS that holds anything, or plan a cluster around it |
| **Do** | run it against a spare NAS, or a pool you are willing to lose, and tell us what happened |

Three questions have to be answered on real hardware before anything else is
worth doing. A wrong answer to any of them changes the design rather than being
a bug to fix:

1. Does the NAS's `LUNNAA` equal the kernel's `/sys/block/<sd>/device/wwid`?
   Every device is identified by comparing them.
2. What does a QNAP LUN report as its SCSI vendor string?
3. Does `authLogin.cgi` accept a POST? Every call this plugin makes is one.

[docs/TESTING.md](docs/TESTING.md) lists all seventeen open items in the order
they should be settled, with the commands for a first run.

Every 0.x release is a prerelease. This notice comes down when there is a
measurement to replace it with.

---

## Which Proxmox VE operations work

Implemented and unit-tested, for virtual machines and for containers. Testing on
real hardware covers one NAS so far.

A container's disk is the same object as a virtual machine's: one thin LUN, one
multipath device. The difference is what sits on top. Proxmox VE puts a
filesystem on a container's LUN and mounts it *on the host*, where a VM's disk
is handed to the guest whole. That is why only two rows below differ.

| Operation | VM | Container |
|---|---|---|
| Allocate, delete, list | yes | yes¹ |
| Thin provisioning | yes | yes |
| Resize (grow) | yes | yes |
| Snapshot, delete snapshot, roll back | yes | yes² |
| Template | yes | yes |
| Linked clone, clone from a snapshot | QuTS hero only⁵ | QuTS hero only⁵ |
| Full clone, `pvesm export`/`import`, move to another storage | yes | yes |
| Migration between nodes | yes | yes |
| **Live** migration, with the guest running | yes | n/a³ |
| Multipath across several NAS data ports | yes | yes |
| CHAP, mutual CHAP | yes | yes |
| Shrink a disk | **refused** | **refused** |
| Read a snapshot as a device | not possible⁴ | not possible⁴ |

¹ A container needs `rootdir` in the storage's content types:
`--content images,rootdir`.

² The plugin answers `volume_snapshot_needs_fsfreeze` yes, so PVE freezes a
running container's mount points before the NAS takes the snapshot. A
container's root is mounted on the host, unlike a VM's disk.

³ Proxmox VE does not live-migrate a running container at all, on any storage. A
container migrates with a restart, and on this storage that restart moves no
data.

⁴ Roll back to it, or on QuTS hero clone it into a disk of its own. The plugin
declines the capability up front rather than starting an operation and failing
partway.

⁵ On QTS the plugin offers no linked clone and no clone from a snapshot, and
Proxmox VE refuses one before it starts. Clone a template with a full clone. The
reason is the third point below.

## Three things that shape what this can do

### 1. Disks are allocated in whole GiB

A LUN's capacity is a whole number of GiB, with no finer step. So every size is
rounded **up**, and `volume_size_info` reports what the NAS actually has rather
than what Proxmox VE asked for. Ask for a 10.5 GB disk and you get 11 GiB, and
the VM configuration says 11 GiB too.

A resize says so:

```
storage 'qnap1': QTS allocates in whole GiB, so 'pve-qnap1-vm-100-disk-0' is
now 12884901888 bytes rather than the 11811160064 requested.
```

### 2. CHAP is the access control

This plugin does not set up per-host access lists on the target. It configures
CHAP on the target's default policy and nothing narrower. Restricting a LUN to
named hosts is something you do yourself in the QNAP web interface.

So set CHAP unless the NAS is on a storage-only network. The plugin warns when
you add a storage without it, and it refuses a CHAP username with no secret
rather than writing an empty one.

### 3. Linked clones are for QuTS hero. On QTS, make full clones

Every clone this plugin makes is made from a snapshot, on the NAS.

* **QuTS hero (ZFS):** the clone shares the snapshot's blocks. A Proxmox VE
  linked clone is immediate and takes no extra space.
* **QTS (LVM):** the plugin makes **no linked clones and no clones from a
  snapshot**. A clone on QTS copies the whole disk, and Proxmox VE aborts a
  storage-side clone that runs longer than 60 seconds. Clone a template with a
  full clone (`qm clone <vmid> <newid> --full 1`), which Proxmox VE copies
  itself. Snapshots and rollback work on QTS, and a rollback takes as long as
  the NAS needs to write the disk back.

If you are choosing hardware and expect to deploy from templates, this is the
deciding factor.

## Requirements

| | |
|---|---|
| Proxmox VE | 9.x, on **every node**. 8.x is expected to work and has never been tested |
| QNAP firmware | QTS 4.5.1+ or QuTS hero h5.x. **Not QuTS hero h6.0 or later.** See [docs/SUPPORTED-QNAP-OS.md](docs/SUPPORTED-QNAP-OS.md) |
| On the NAS | the iSCSI target service **on**, and a storage pool |
| Account | an **administrator**, without 2-step verification. See [docs/QNAP-ACCOUNT.md](docs/QNAP-ACCOUNT.md) |
| On each node | `open-iscsi`, `multipath-tools` |

The plugin **refuses** a firmware that reports the legacy Storage Manager
instead of Storage Manager V2, at `pvesm add`, with the version in the message.
It does not add cleanly and then list nothing.

## The LUN ceiling

One VM disk is one LUN, and a NAS has a maximum number of them. QNAP publishes
**128 for QTS and 256 for QuTS hero** on its product pages, and **255 for LUNs
and targets combined** in its user guides. The figure is the same on a two-bay
model as on a twelve-bay one. A VM with a system disk and a data disk spends
two, so plan on roughly 64 such VMs per NAS on QTS.

The plugin reads the ceiling from the NAS rather than assuming, warns as it
approaches, and refuses an allocation at the limit with a message that says free
space will not help:

```
storage 'qnap1': the NAS already holds 256 LUNs, which is this model's maximum
(256). Free space is not the problem and adding capacity will not help. Delete
LUNs, or use a second NAS. The count includes LUNs this storage does not own,
such as Virtual Machine Manager disks.
```

`pve-qnap-api-probe` prints the number. Check it before you plan a cluster.
[docs/LIMITS.md](docs/LIMITS.md) has every published figure with its source,
including snapshots per LUN and what `per-volume` target mode costs.

## Installing

On every node of the cluster.

```bash
# on each node: the two packages PVE does not install for you
apt update
apt install -y open-iscsi multipath-tools

cd /tmp
# no version in the filename: this URL always gives you the newest release
wget -O jt-pve-storage-qnap_all.deb \
  https://github.com/jasoncheng7115/jt-pve-storage-qnap/releases/latest/download/jt-pve-storage-qnap_all.deb
apt install -y ./jt-pve-storage-qnap_all.deb
systemctl restart pvedaemon pveproxy pvestatd

dpkg -l jt-pve-storage-qnap | awk '/^ii/{print $3}'    # check what you got
```

**Keep the `-O`.** Without it, `wget` does not overwrite a file that is already
there and saves the download under another name. `apt` then installs the **old**
file left in `/tmp` from last time.

Use `apt install ./file.deb`, not `dpkg -i`. The latter does not resolve
dependencies and leaves the package unconfigured on a node without
`multipath-tools`.

**Every node in the cluster, including the one you browse from**, and keep them
on the same version. A storage operation runs on the node that owns the guest,
and a node *without* the plugin makes the storage invisible in the web interface
rather than reporting an error.

## The discovery tool

Run it before anything else. It is **read-only**: it creates nothing, deletes
nothing, and logs out after itself.

```bash
pve-qnap-api-probe --host <nas> --user admin --insecure --node
```

It prints the model, the firmware, whether it is QTS or QuTS hero, the LUN and
target ceilings, the storage pools with their free space, and what this node has
installed.

## Adding a QNAP storage in Proxmox VE

```bash
pvesm add qnapsan qnap1 \
    --qnap-portal 192.0.2.10 \
    --qnap-username pve \
    --qnap-password '<password>' \
    --qnap-pool 1 \
    --qnap-chap-username pve \
    --qnap-chap-password '<secret>' \
    --qnap-ssl-verify 0 \
    --content images
```

Then use it like any other storage: `qm create --scsi0 qnap1:32`, snapshots,
rollback, templates, clones, live migration.

Adding a storage whose prefix the NAS already has LUNs under produces a warning.
If you added this storage here before, those are its own disks. If a *different*
Proxmox VE cluster uses the same storage id on the same NAS, the two would share
every disk name. In that case remove the storage and add it under another id.

## The cleanup tool

Proxmox VE never tells the *source* node that a shared volume is no longer
needed there. So a node a VM was migrated away from keeps a multipath map for a
LUN it no longer uses, and if the VM was later destroyed elsewhere, for a LUN
that no longer exists. A node that was hard-reset keeps a tracking entry the
same way.

```bash
pve-qnap-reap --all             # report only
pve-qnap-reap --all --remove    # act
```

**Run it after a node crash, and on every node before removing a storage.** It
never touches a device that is in use, and it refuses rather than guessing when
it cannot tell.

## Options

| Option | Default | |
|---|---|---|
| `qnap-portal` | none | management address; a comma-separated list is tried in order |
| `qnap-port` | `443` | QTS's HTTP admin port is usually 8080 |
| `qnap-scheme` | `https` | `http` sends the password over the network unencrypted |
| `qnap-username` | none | must be an administrator |
| `qnap-password` | none | kept in `/etc/pve/priv`, never in `storage.cfg` |
| `qnap-pool` | none | the pool number *Storage & Snapshots* shows |
| `qnap-target-mode` | `shared` | or `per-volume`, which costs a target per disk |
| `qnap-chap-username` / `-password` | none | the access control this plugin relies on |
| `qnap-mutual-chap-username` / `-password` | none | authenticates the NAS to the node |
| `qnap-ssl-verify` | `0` | QTS ships a self-signed certificate |
| `qnap-data-portals` | management address | iSCSI data addresses, comma-separated |
| `qnap-min-free` | `10` | refuse to allocate below this many GiB free in the pool |
| `qnap-no-path-retry` | `18` | multipath; a number, never `queue` |
| `qnap-sector-size` | `512` | or `4096`; some guests will not boot from 4Kn |
| `qnap-thin` | `1` | a thick LUN reserves its whole capacity at creation |
| `qnap-status-timeout` | `5` | seconds, for the health path |

## Documentation

| | |
|---|---|
| [docs/TESTING.md](docs/TESTING.md) | What is verified, what is not, and the first run. **Read this before trusting anything** |
| [docs/LIMITS.md](docs/LIMITS.md) | The published LUN, target and snapshot maxima, with the official source for each figure |
| [docs/SUPPORTED-QNAP-OS.md](docs/SUPPORTED-QNAP-OS.md) | Which firmware works, and what differs between QTS and QuTS hero |
| [docs/QNAP-ACCOUNT.md](docs/QNAP-ACCOUNT.md) | The NAS account, where the password lives, and CHAP |
| [CHANGELOG.md](CHANGELOG.md) | What each release added, fixed and left unverified |

## When something goes wrong

The failures this plugin can produce, each with what it means and what to do,
are on the documentation site under
[When something goes wrong](https://jasoncheng7115.github.io/jt-pve-storage-qnap/#trouble).

Please include the output of `pve-qnap-api-probe --node`, the model, the
firmware version, and whether it is QTS or QuTS hero when you report one.

## Contributing

Reports from real hardware are what this project needs most. See
[docs/TESTING.md](docs/TESTING.md).

**The set of QNAP API calls this plugin makes is fixed.** `t/07-api-scope.t`
lists every one and fails when the source makes a call that is not on the list.
A change that needs a new call is welcome as an issue first. Do not add it to
the list to make the test pass.

## Related projects

Proxmox VE storage plugins for other storage, sharing the host-side layer and
the operational rules this one inherits:

- [jt-pve-storage-synology](https://github.com/jasoncheng7115/jt-pve-storage-synology): Synology NAS
- [jt-pve-storage-dellemc](https://github.com/jasoncheng7115/jt-pve-storage-dellemc): Dell EMC PowerStore, PowerVault ME, PowerFlex, Unity XT
- [jt-pve-storage-netapp](https://github.com/jasoncheng7115/jt-pve-storage-netapp): NetApp ONTAP
- [jt-pve-storage-purestorage](https://github.com/jasoncheng7115/jt-pve-storage-purestorage): Pure Storage FlashArray

## Licence

MIT. See [LICENSE](LICENSE).

The licence covers this plugin's own code. It does not extend to QNAP's API
documentation, software, firmware or trademarks, none of which are part of this
repository.

**This is an independent project. It is not developed, certified, endorsed or
maintained by QNAP Systems, Inc.**, and QNAP gives no warranty for it. QNAP, QTS
and QuTS hero are trademarks of QNAP Systems, Inc.

## Author

Jason Cheng (Jason Tools) &lt;jason@jason.tools&gt;
