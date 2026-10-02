# Changelog

Every 0.x release is a prerelease. **This plugin has not yet worked against a
QNAP NAS.**

The register of what has been verified against real hardware, and what has not,
is [docs/TESTING.md](docs/TESTING.md). It is more useful than this file for
deciding whether to trust a given release.

## [0.6.1] - 2026-10-02

The first report from a real NAS. It ran QuTS hero h6.0.1, and the plugin does
not work there.

### Fixed

- **QuTS hero h6.0 and later are refused when the storage is added.** On
  h6.0.1 the NAS refuses to create a target or a LUN for this plugin, while
  everything the plugin reads still answers. 0.6.0 reported that from
  `pvesm add` as "-1 (the NAS reported an unspecified error)". It is now refused
  before anything is sent that the NAS would refuse, with a message naming the
  firmware. `pve-qnap-api-probe` says the same.
- **A NAS upgraded to h6 under an existing storage says so.** The storage keeps
  reporting its capacity and listing its disks, and creating or deleting a disk
  is refused by the NAS. Those refusals now name the firmware as well as the
  code.

### Changed

- **The documents no longer say "any QuTS hero".** QuTS hero h5.x is what the
  plugin is written for. h6.0 and later are listed as not supported in
  [docs/SUPPORTED-QNAP-OS.md](docs/SUPPORTED-QNAP-OS.md), with a warning against
  upgrading a NAS that is in use. What the run on h6.0.1 answered, and what it
  did not, is in [docs/TESTING.md](docs/TESTING.md).
- A refused call now ends its message with a full stop. Anything that matches on
  message text needs the same change.
- The Chinese documents call a storage pool 儲存集區 throughout.
- 13 unit tests added for the above, 220 in total.

## [0.6.0] - 2026-10-01

### Fixed

- **Adding a storage with CHAP was refused.** `pvesm add` with
  `qnap-chap-username` and `qnap-chap-password` answered "there is no CHAP
  secret". The secret is written to the credential store only after every check
  has passed, and the target was being created from the stored value, which did
  not exist yet. The target is now created from the secret that was just
  supplied. Adding a storage without CHAP was not affected.
- **A GET request was sent to a NAS that reads POST bodies.** The fallback for a
  firmware that ignores a POST body was taken for any answer without a
  `<result>`, and two ordinary answers have none. Each of them was followed by a
  GET carrying the session id in its URL. The fallback is now taken only when a
  session that was issued a moment ago is still not recognised, and never for a
  call that carries a secret.
- **A snapshot that a clone depends on.** On QuTS hero, a snapshot that a disk
  was cloned from cannot be deleted while that disk exists. The refusal now
  quotes what the NAS answered and names the likely cause.

### Added

- **[docs/LIMITS.md](docs/LIMITS.md)**: the LUN, target and snapshot maxima QNAP
  publishes, with the source of each figure, and what they mean for the number
  of virtual disks one NAS can hold.
- **The documentation site follows the browser's language.** A URL with
  `?lang=zh` or `?lang=en` still decides. Without one, a browser set to Chinese
  gets the Chinese page.
- **A simulated NAS.** The plugin was driven through adding a storage,
  allocating, snapshotting, cloning, rolling back, resizing, templates, linked
  clones, renaming, deleting and removing the storage, against a simulated QTS
  and a simulated QuTS hero that refuse what a NAS is expected to refuse. It is
  what found the two defects above. It is not a substitute for hardware.
- 11 unit tests for the fixes above, 207 in all.

### Changed

- **Messages no longer use a dash.** A colon now separates an operation from the
  reason it failed. Anything that matches these messages by their text needs
  the same change.
- The multipath drop-in this plugin writes carries the same change in its own
  comment, so its content differs from 0.1.0. A node with a `qnapsan` storage
  rewrites it on the next activation and reloads multipathd once.

## [0.1.0] - 2026-10-01

First release. Implemented and unit-tested, **not yet driven on hardware**.

### Added

- **The storage type `qnapsan`.** One VM disk is one thin LUN on a QNAP NAS over
  iSCSI, so the NAS's own snapshots, clones and capacity act on the unit an
  operator thinks about. No LVM layer and no shared LUN carved up locally.
- **Every volume operation Proxmox VE asks a storage for**, for virtual machines
  and for containers: allocate, delete, list, grow, snapshot, delete a snapshot,
  roll back, template, linked clone, full clone, export and import, rename, and
  migration between nodes. Shrinking a disk is refused.
- **QTS and QuTS hero.** The plugin detects which it is talking to. On QuTS hero
  a linked clone shares its template's blocks and is immediate. On QTS the same
  operation copies. A firmware with the legacy Storage Manager is refused at
  `pvesm add`, with the version in the message.
- **Sizes are rounded up to a whole GiB**, which is the step the NAS allocates
  in, and `volume_size_info` reports what the NAS has rather than what was asked
  for. A resize that lands on a different figure says so.
- **CHAP and mutual CHAP.** CHAP is the access control this plugin relies on. A
  username with no secret is refused rather than written, and adding a storage
  without CHAP warns.
- **A clone and a rollback are serialised across the cluster** with Proxmox VE's
  own storage lock, because only one of them may be in flight on the NAS at a
  time.
- **The LUN ceiling is read from the NAS.** One VM disk is one LUN, so the
  plugin warns as the maximum approaches and refuses an allocation at the limit
  with a message that says free space will not help.
- **Credentials are kept in `/etc/pve/priv/storage/<id>.qnap`**, never in
  `storage.cfg`, and every call is a POST so no credential travels in a URL. A
  refused login is tried once and then held until the configuration changes, so
  a wrong password cannot get a node blocked by the NAS.
- **Multipath.** A drop-in for QNAP LUNs with a numeric `no_path_retry`, never
  `queue`. Every device is confirmed against the kernel's own WWID before use,
  and only ever one named map is flushed.
- **`pvesm add` warns when the NAS already holds LUNs under this storage's
  prefix.** A second Proxmox VE cluster using the same storage id on the same
  NAS would otherwise share every disk name with this one.
- **`pve-qnap-api-probe`**, a read-only tool that prints the model, the
  firmware, whether it is QTS or QuTS hero, the LUN and target ceilings, the
  storage pools, and what the node has installed.
- **`pve-qnap-reap`**, which reports multipath maps a node keeps for LUNs it no
  longer uses, and clears them with `--remove`. A dry run by default.
- **Documentation in English and Traditional Chinese**:
  [docs/TESTING.md](docs/TESTING.md) with all sixteen open items and the first
  run, [docs/SUPPORTED-QNAP-OS.md](docs/SUPPORTED-QNAP-OS.md), and
  [docs/QNAP-ACCOUNT.md](docs/QNAP-ACCOUNT.md).
- **196 unit tests and the build guards**: no node-wide multipath flush, no
  credential in a URL, no command outside the tool resolver, every call to a
  sub that exists, and `t/07-api-scope.t`, which lists every QNAP API call the
  plugin makes and fails when the source makes one that is not on the list.

### Not verified

- **Everything that talks to the NAS.** Three questions have to be answered on
  real hardware before anything else is worth doing: whether the NAS's `LUNNAA`
  equals the kernel's WWID, what SCSI vendor string a QNAP LUN reports, and
  whether `authLogin.cgi` accepts a POST. A wrong answer to any of them changes
  the design rather than being a bug to fix.
- The node-facing half (multipath handling, iSCSI node management, the bounded
  command runner, WWID tracking) is ported from the related projects, where it
  has been measured on other storage.
