# Changelog

Every 0.x release is a prerelease. **Nothing in this plugin has run against a
QNAP NAS yet.**

The register of what has been verified against real hardware, and what has not,
is [docs/TESTING.md](docs/TESTING.md) — it is more useful than this file for
deciding whether to trust a given release.

## [0.1.0] - 2026-10-01

First release. Implemented and unit-tested, **not yet driven on hardware**.

### Added

- **The storage type `qnapsan`.** One VM disk is one thin LUN on a QNAP NAS over
  iSCSI, so the NAS's own snapshots, clones and capacity act on the unit an
  operator thinks about. No LVM layer and no shared LUN carved up locally.
- **Every volume operation Proxmox VE asks a storage for**, for virtual machines
  and for containers: allocate, delete, list, grow, snapshot, delete a snapshot,
  roll back, template, linked clone, full clone, export and import, rename, and
  migration between nodes. Shrinking a disk is refused, loudly.
- **QTS and QuTS hero.** The plugin detects which it is talking to. On QuTS hero
  a linked clone shares its template's blocks and is immediate; on QTS the same
  operation copies. A firmware with the legacy Storage Manager is refused at
  `pvesm add`, with the version in the message.
- **Sizes are rounded up to a whole GiB**, which is the step the NAS allocates
  in, and `volume_size_info` reports what the NAS has rather than what was asked
  for. A resize that lands on a different figure says so.
- **CHAP and mutual CHAP.** CHAP is the access control this plugin relies on; a
  username with no secret is refused rather than written, and adding a storage
  without CHAP warns.
- **A clone and a rollback are serialised across the cluster** with Proxmox VE's
  own storage lock, because only one of them may be in flight on the NAS at a
  time.
- **The LUN ceiling is read from the NAS.** One VM disk is one LUN, so the
  plugin warns as the model's maximum approaches and refuses an allocation at
  the limit with a message that says free space will not help.
- **Credentials are kept in `/etc/pve/priv/storage/<id>.qnap`**, never in
  `storage.cfg`, and every call is a POST so no credential travels in a URL. A
  refused login is tried once and then latched until the configuration changes,
  so a wrong password cannot get a node blocked by the NAS.
- **Multipath.** A drop-in for QNAP LUNs with a numeric `no_path_retry`, never
  `queue`. Every device is confirmed against the kernel's own WWID before use,
  and only ever one named map is flushed.
- **`pvesm add` warns when the NAS already holds LUNs under this storage's
  prefix** — a second Proxmox VE cluster using the same storage id on the same
  NAS would otherwise share every disk name with this one.
- **`pve-qnap-api-probe`**, a read-only tool that prints the model, the
  firmware, whether it is QTS or QuTS hero, the LUN and target ceilings, the
  storage pools, and what the node has installed.
- **`pve-qnap-reap`**, which reports — and with `--remove` clears — multipath
  maps a node keeps for LUNs it no longer uses. A dry run by default.
- **Documentation in English and Traditional Chinese**:
  [docs/TESTING.md](docs/TESTING.md) with all sixteen open items and the first
  run, [docs/SUPPORTED-QNAP-OS.md](docs/SUPPORTED-QNAP-OS.md), and
  [docs/QNAP-ACCOUNT.md](docs/QNAP-ACCOUNT.md).
- **196 unit tests and the build guards**: no node-wide multipath flush, no
  credential in a URL, no command outside the tool resolver, every call to a
  sub that exists, and
  `t/07-api-scope.t`, which lists every QNAP API call the plugin makes and fails
  when the source makes one that is not on the list.

### Not verified

- **Everything that talks to the NAS.** Three questions have to be answered on
  real hardware before anything else is worth doing — whether the NAS's `LUNNAA`
  equals the kernel's WWID, what SCSI vendor string a QNAP LUN reports, and
  whether `authLogin.cgi` accepts a POST. A wrong answer to any of them changes
  the design rather than being a bug to fix.
- The node-facing half — multipath handling, iSCSI node management, the bounded
  command runner, WWID tracking — is ported from the related projects, where it
  has been measured on other arrays.
