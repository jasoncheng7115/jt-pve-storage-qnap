# QNAP LUN and target limits

[English](LIMITS.md) · [繁體中文](LIMITS_zh-TW.md) · [Documentation site](https://jasoncheng7115.github.io/jt-pve-storage-qnap/)

**One VM disk is one LUN in this plugin.** So the LUN ceiling is the maximum
number of virtual disks the storage can ever hold, and it is reached long before
the space runs out.

Three consequences that are easy to miss, and all three are about counting rather
than capacity:

- **It is per NAS, not per node.** A three-node cluster sharing one NAS shares one
  ceiling.
- **It counts every LUN on that NAS**, including ones you created in *Storage &
  Snapshots* for something else entirely. The plugin counts them too, which is why
  it can refuse before the NAS does.
- **A VM usually spends more than one.** A system disk plus a data disk is two, so
  a NAS that allows 128 holds roughly **64 such VMs**.

Every figure on this page is quoted from a page QNAP publishes, with the URL.
Nothing is interpolated, and **none of it has been measured by this project**:
this plugin has not yet worked against a NAS.

---

## What QNAP publishes, and the three places do not say the same thing

### 1. The product pages: 128 on QTS, 256 on QuTS hero

Each model's *Software Specifications* page carries one line per operating
system:

| Operating system | "Maximum number of targets LUN" | "Maximum LUN size" |
|---|---:|---:|
| QTS 5.2 | **128** | 250 TB |
| QuTS hero h6.0 | **256** | 1024 TB |

The QuTS hero line is the one the product pages give for h6.0. **This plugin
does not support QuTS hero h6.0 or later**, see
[SUPPORTED-QNAP-OS.md](SUPPORTED-QNAP-OS.md). The user guide's figure for QuTS
hero h5.1.x is under the user guides, below.

The same two figures appear on every model that was looked up:

| Model | QTS | QuTS hero | Source |
|---|---:|---:|---|
| TS-233 (2-bay, ARM) | 128 | not offered | [specs](https://www.qnap.com/en/product/ts-233/specs/software) |
| TS-464 (4-bay) | 128 | 256 | [specs](https://www.qnap.com/en/product/ts-464/specs/software) |
| TS-873A (8-bay, AMD) | 128 | 256 | [specs](https://www.qnap.com/en/product/ts-873a/specs/software) |
| TVS-h874 (8-bay) | 128 | 256 | [specs](https://www.qnap.com/en/product/tvs-h874/specs/software) |
| TS-h1290FX (12-bay all-flash) | 128 | 256 | [specs](https://www.qnap.com/en/product/ts-h1290fx/specs/software) |

So, unlike some other vendors, **the number follows the operating system, not the
model**: a two-bay entry model and a twelve-bay all-flash one publish the same
figure. A model that offers both operating systems doubles its ceiling by running
QuTS hero.

### 2. The FAQ: the same numbers, called theoretical

QNAP's FAQ on storage limits gives the maximum number of objects per operating
system:

| | QTS | QuTS hero |
|---|---:|---:|
| LUNs | **128** | **256** |
| LUN size | 250 TB | 1024 TB |
| Volumes | 128 | 256 |
| Snapshots | 1024 | 65536 |

and says of all of them that they are *theoretical maximums and may be lower on
some hardware models or specific configurations*.

Source: [What are the maximum storage capacities and limits for QNAP NAS operating systems?](https://www.qnap.com/en/how-to/faq/article/what-are-the-maximum-storage-capacities-and-limits-for-qnap-nas-operating-systems)

### 3. The user guides: 255, LUNs and targets together

The *Storage limits* page of each user guide states one iSCSI figure, and it is a
**combined** one:

| User guide | iSCSI LUNs and targets per NAS |
|---|---:|
| [QTS 5.1.x](https://docs.qnap.com/operating-system/qts/5.1.x/en-us/storage-limits-0A2EB80.html) | **255 (combined)** |
| [QTS 5.2.x](https://docs.qnap.com/operating-system/qts/5.2.x/en-us/storage-limits-0A2EB80.html) | **255 (combined)** |
| [QuTS hero h5.1.x](https://docs.qnap.com/operating-system/quts-hero/5.1.x/en-us/storage-limits-0A2EB80.html) | **255 (combined)** |

The same pages give 8 connections per iSCSI session, and say the number of
sessions per target and per NAS is decided by the NAS's CPU, memory and network
rather than by a fixed figure.

### Which one is yours

They cannot all be the whole truth for QTS: 128 from the product page and the FAQ,
255 combined from the user guide. **This project has not measured which governs.**
Until it has, plan on the smaller one:

| | Plan on |
|---|---|
| QTS | **128 LUNs**, less whatever the NAS already holds |
| QuTS hero | **255 LUNs and targets together**, less whatever the NAS already holds |

---

## So ask the NAS, and this plugin does

A NAS reports its own maximum number of LUNs and of targets, and
`pve-qnap-api-probe` prints both:

```bash
pve-qnap-api-probe --host <nas> --user admin --insecure
```

The plugin reads them rather than assuming, and refuses **before** the NAS does,
so the message names the real reason instead of an error number:

| Ceiling | What the plugin does |
|---|---|
| LUNs | refuses the allocation, and warns from 16 remaining. Counts **every** LUN on the NAS, including ones this storage does not own |
| Targets | refuses target creation. Only reachable with `qnap-target-mode=per-volume`; `shared` uses one target for the whole storage and is the default for this reason |

When a NAS reports no figure, the guard stands down rather than inventing one. It
never reads that as "no limit".

**The plugin checks the two ceilings separately.** If the combined figure in the
user guide is the one a NAS enforces, the NAS will refuse first and the plugin
will report that refusal as it came. This is open item 12 in
[TESTING.md](TESTING.md).

### Why `shared` is the default target mode

`per-volume` gives each disk its own target, so each disk spends a LUN **and** a
target. Against a combined ceiling of 255 that is **127 disks**, where `shared`, with
one target for the whole storage, leaves 254. `shared` also keeps the number of
iSCSI sessions per node at one per data address instead of one per disk.

---

## Snapshots per LUN

### QuTS hero

**65,536 per LUN**, per shared folder and per NAS, and a storage pool needs at
least 32 GB free before a new snapshot can be taken.

Source: [Snapshot storage limitations, QuTS hero h5.1.x](https://docs.qnap.com/operating-system/quts-hero/5.1.x/en-us/snapshot-storage-limitations-91D8C464.html)

### QTS: it depends on the CPU and the installed memory

| CPU | Installed memory | Per NAS | Per volume or LUN |
|---|---|---:|---:|
| Intel, AMD, Zhaoxin | 1 GB or more | 32 | 16 |
| | 2 GB or more | 64 | 32 |
| | 4 GB or more | **1024** | **256** |
| Marvell, Annapurna Labs | 1 GB or more | 32 | 16 |
| | 2 GB or more | 64 | 32 |
| | 4 GB or more | 256 | 64 |
| Realtek | 1 GB or more | 32 | 16 |
| | 2 GB or more | 64 | 32 |

Snapshots need at least 1 GB of memory, and some older series do not support them
at all.

Source: [How many snapshots can I create on my QNAP NAS?](https://www.qnap.com/en/how-to/faq/article/how-many-snapshots-can-i-create-on-my-qnap-nas)

Three things about those numbers:

- **The per-NAS figure is the one that is reached first.** On QTS with 4 GB or
  more, 1024 snapshots across the whole NAS is four snapshots each on 256 disks,
  or eight each on 128.
- **The budget is shared.** A snapshot schedule you set up on the NAS yourself
  draws on the same per-LUN and per-NAS figures as the snapshots Proxmox VE takes.
- **The plugin does not know these ceilings in advance.** It takes the snapshot
  and reports what the NAS answers. A template also keeps one snapshot of its own
  for its linked clones to hang off.

### A snapshot with RAM takes a LUN of its own

Tick *Include RAM* and Proxmox VE writes the memory to a separate volume,
`vm-<vmid>-state-<snapname>`. On this storage that is another LUN, against the
same LUN ceiling. It is sized from the VM's memory and rounded up to a whole GiB
like any other disk, and it lands on this storage by default because Proxmox VE
prefers a shared storage the VM already has a disk on. Set `vmstatestorage` on the
VM to send it somewhere else. It is freed when the snapshot is deleted.

---

## LUN size

| | Maximum | Minimum this plugin creates |
|---|---:|---:|
| QTS | 250 TB | 1 GiB |
| QuTS hero | 1024 TB | 1 GiB |

The product pages note that the QTS maximum needs at least 4 GB of memory. The
plugin allocates in whole GiB, so the smallest disk (an EFI disk, a TPM state, a
cloud-init drive) is 1 GiB.

---

## What is not published, and what is not measured

Stated plainly, because a gap is more useful than a guess:

- **No figure for LUNs per target.** With `shared`, every disk of the storage is
  on one target, so this matters; nothing QNAP publishes states it.
- **No statement of which figure wins** between the product page's 128 and the
  user guide's combined 255 on QTS.
- **Only five product pages were read.** They agree, and the FAQ gives the same
  numbers per operating system, but the FAQ also says a model may be lower. Check
  your own model's page, or ask the NAS.
- **Nothing here has been measured.** Every figure is QNAP's. When this project
  has a NAS to measure, what the NAS reports and what it actually refuses will be
  written beside these.

---

## Official references

- [QTS 5.1.x User Guide: Storage limits](https://docs.qnap.com/operating-system/qts/5.1.x/en-us/storage-limits-0A2EB80.html)
- [QTS 5.2.x User Guide: Storage limits](https://docs.qnap.com/operating-system/qts/5.2.x/en-us/storage-limits-0A2EB80.html)
- [QuTS hero h5.1.x User Guide: Storage limits](https://docs.qnap.com/operating-system/quts-hero/5.1.x/en-us/storage-limits-0A2EB80.html)
- [QuTS hero h5.1.x User Guide: Snapshot storage limitations](https://docs.qnap.com/operating-system/quts-hero/5.1.x/en-us/snapshot-storage-limitations-91D8C464.html)
- [FAQ: What are the maximum storage capacities and limits for QNAP NAS operating systems?](https://www.qnap.com/en/how-to/faq/article/what-are-the-maximum-storage-capacities-and-limits-for-qnap-nas-operating-systems)
- [FAQ: How many snapshots can I create on my QNAP NAS?](https://www.qnap.com/en/how-to/faq/article/how-many-snapshots-can-i-create-on-my-qnap-nas)
- [TS-464 Software Specifications](https://www.qnap.com/en/product/ts-464/specs/software)
