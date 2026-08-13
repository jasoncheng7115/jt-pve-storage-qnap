# The NAS account this plugin uses

## It has to be an administrator

There is no way around this, and it is worth being explicit about rather than
leaving an operator to discover it.

The calls this plugin makes — `iscsi_lun_setting.cgi`,
`iscsi_target_setting.cgi`, `iscsi_portal_setting.cgi`, `disk_manage.cgi`,
`snapshot.cgi` — are administrator-only in QTS. A standard user, or a user with
delegated permissions on a shared folder, gets a session that logs in perfectly
well and then answers every one of those calls with a refusal.

So: **an account in the `administrators` group.**

## Do not use `admin`

Use a *second* administrator account, created for this purpose:

* it can be disabled without locking anyone out of the NAS;
* the NAS's own logs then show which actions were Proxmox VE's;
* `admin` is the account that QTS's brute-force protection and every scanner on
  the internet already knows the name of.

Create it in *Control Panel → Privilege → Users*, and put it in
*administrators*.

```
Username   pve
Group      administrators
Password   long, and used nowhere else
```

## Two-factor authentication: turn it OFF for this account

This plugin logs in with a username and a password and nothing else; it does
not implement 2-step verification. An account with it enabled cannot be used by
this plugin.

That is a real reason to give this account its own name and its own long
password, and to leave 2FA on for the human accounts.

## Where the password is kept

**Not in `/etc/pve/storage.cfg`.** That file is `root:www-data 0640`, and PVE
returns any property it does not know is a secret from `GET /storage/<id>` to
any user holding `Datastore.Audit` — a read-only auditor would have been handed
an administrator credential for your NAS.

The plugin declares `qnap-password`, `qnap-chap-password` and
`qnap-mutual-chap-password` as sensitive, so PVE strips them from the
configuration and hands them to the plugin's hooks instead. They are written to:

```
/etc/pve/priv/storage/<storeid>.qnap     root only, replicated to every node
```

If you upgrade from a version that stored the password in `storage.cfg`, the
plugin reads it from there so nothing breaks — and says so, once, with the
command that moves it:

```
pvesm set <storeid> --qnap-password <password>
```

## Use HTTPS

`qnap-scheme` defaults to `https` on port 443. With `http` the password and any
CHAP secret travel in clear on **every** call, and `status()` runs every ten
seconds per node. The plugin warns once per storage when it is set to `http`.

QTS ships a self-signed certificate, so `qnap-ssl-verify` defaults to off — a
default nobody can use protects nobody. If you have installed a real certificate
on the NAS, turn verification on:

```
pvesm set <storeid> --qnap-ssl-verify 1
```

## CHAP is not optional in the way it looks

**This plugin does not set up per-host access lists on the target.** It
configures CHAP on the target's default policy and nothing narrower. If you want
a LUN restricted to named hosts as well, that is done in the QNAP web interface.

So CHAP is what decides who can attach these disks. Set it:

```
pvesm set <storeid> --qnap-chap-username pve --qnap-chap-password <secret>
```

Both together, always. A username with no secret would write an *empty* CHAP
secret — access control that reports itself as on and protects nothing — and the
plugin refuses that rather than doing it.

Mutual CHAP authenticates the NAS to the node, which is the half that stops a
node being pointed at an impostor. It requires one-way CHAP as well:

```
pvesm set <storeid> \
    --qnap-chap-username pve --qnap-chap-password <secret> \
    --qnap-mutual-chap-username nas --qnap-mutual-chap-password <other-secret>
```

## A wrong password locks the node out, once

QTS blocks a source address after a few failed logins. Proxmox VE polls every
storage every ten seconds on every node, so a wrong password would reach that
threshold in well under a minute — and the symptom afterwards is a refused
connection, which looks like a dead NAS rather than a bad credential.

The plugin therefore **latches** a refused credential: it makes one failed
attempt, records it under `/run/jt-pve-storage-qnap/`, and refuses to try again
until the storage configuration changes. Any `pvesm set` on the storage clears
the latch.

If you see

```
storage 'qnap1': not retrying after the NAS did not accept the account...
```

fix the credential and run `pvesm set qnap1 --qnap-password <password>`.
