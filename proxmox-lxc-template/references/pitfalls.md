# Pitfalls, each one met for real

Each entry: what you see, why, the fix for a container that already exists,
and the fix in the build.

## 1. The console goes back to `login:` without asking for a password

**Why.** The image has no `/usr/bin/login`. Up to Debian 12 the `login`
package was installed in every system; from Debian 13 it has to be asked
for, and `mmdebstrap --variant=apt` installs only apt and what it depends
on. `agetty` prints the prompt, tries to run `login`, fails, and starts
again. No username or password works. The application itself is unaffected,
which is why this ships unnoticed.

**Existing container.** On the Proxmox host: `pct enter <ctid>` (needs no
login), then `apt update && apt install -y login`, then `passwd` if no root
password was set when the container was created.

**Build.** Add `login` to the package list and assert it:
`[ -x "$root/usr/bin/login" ] || { echo "no login program" >&2; exit 1; }`.

**General lesson.** Moving to a newer distribution release changes what is
installed by default. List every package the container needs, and assert the
ones a person will notice are missing only when it is too late: `login`,
`systemd` as init (`/sbin/init`), `ca-certificates`, the network tools,
`openssh-server` if SSH is promised.

## 2. `root` is refused over SSH, or has no password at all

**Why.** The template sets no root password (it must not). Proxmox sets the
one typed in "Create CT"; if that field was left empty there is none. And
Debian's `sshd` refuses root password logins by default.

**Fix.** `pct enter <ctid>` then `passwd`. Document that the root password
is the one from "Create CT", and that the application's own login is a
different thing. Don't enable root password SSH in the image.

## 3. The service fails with `status=226/NAMESPACE`, or Debian 13 behaves oddly

**Why.** systemd sandboxing (`ProtectSystem=`, `PrivateTmp=`, …) and newer
systemd itself need the container's **nesting** feature in an unprivileged
container.

**Fix.** `pct set <ctid> --features nesting=1` and restart the container.
Say "enable nesting" in the create instructions and set it in any script
that creates the container.

## 4. The app can't write to its bind-mounted data directory

**Why.** In an unprivileged container, UID *n* inside is UID 100000+*n* on
the host. A host directory owned by root or by a NAS user isn't writable by
the service user.

**Fix.** Give the service user a fixed UID in the image (e.g. 990), and
document `chown 100990:100990 <host dir>` (or the NAS's "map all users"
equivalent). Have first boot test the directory and print a clear warning.

## 5. Building on an Ubuntu machine fails to verify Debian packages (or a new Debian release's)

**Why.** apt on Ubuntu doesn't trust Debian's archive keys, and an older
`debian-archive-keyring` doesn't know a newer release's keys.

**Fix.** Write sources with `[signed-by=/usr/share/keyrings/debian-archive-keyring.gpg]`,
check that file exists before starting, and in CI install the keyring
package **from the suite being built** (download the `.deb` from
deb.debian.org, verify its SHA256 from that suite's `Packages` file). Install
the keyring package in the image too, so the same path works inside.

## 6. The distribution's database is too old (or too new to trust yet)

**Why.** Debian 12 ships PostgreSQL 15, Debian 13 ships 17; the project's
own repository (apt.postgresql.org) has every supported version for both.

**Fix.** Add that repository in the customize hook (key downloaded and
checked to be a key, `signed-by`, the suite's codename + `-pgdg`), install
`postgresql-<N>` explicitly, and assert the binary is there. The image needs
`/etc/resolv.conf` for that step only: copy the host's in and remove it
again. Run the tests against the same major version (a `services:` container
in CI) and put matching client tools on the runner if tests call `pg_dump`.

Moving existing servers to a newer major version is a separate, risky job:
back up first, keep the old cluster, `pg_upgradecluster`, check the app
answers, put the old cluster back if it doesn't, and let the admin opt out.
A dump made by a newer `pg_dump` can't be restored by an older server.

## 7. Every container has the same secrets, or the same SSH host keys

**Why.** They were created while building the image.

**Fix.** In the customize hook: `rm -f /etc/ssh/ssh_host_*`, empty
`/etc/machine-id`, remove `/var/lib/dbus/machine-id` and `/etc/hostname`,
and `pg_dropcluster` the cluster the package made. Create all of them at
first boot. `check-template.py` fails an image that still has them.

## 8. The app starts before first boot finished

**Why.** Nothing orders the two units.

**Fix.** A drop-in for the app's unit: `Requires=<app>-firstboot.service`
and `After=` it. The first-boot unit has `ConditionPathExists=!<state file>`;
a unit skipped by its condition still satisfies `Requires=` on later boots.
Write the state file as the very last step.

## 9. "GitHub answered 403" from the container's updater

**Why.** Unauthenticated GitHub API requests are limited to 60 an hour per
address. An updater that checks the app and several plugins, plus a person
pressing "check now", uses that up. The 403 clears within the hour.

**Fix.** Read the `x-ratelimit-remaining` and `x-ratelimit-reset` headers and
say so in the error, with the time to try again. Accept an optional token
from the environment file (5,000 an hour), send it only to GitHub's API
host, and document it. Don't ask GitHub more often than needed; a source
archive URL on the API host counts too.

## 10. Tailscale (or anything needing a device) won't start in the container

**Why.** `tailscaled` needs `/dev/net/tun`, which an unprivileged container
doesn't have.

**Fix (host).** Add to `/etc/pve/lxc/<ctid>.conf`, then `pct reboot <ctid>`:

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

Then `systemctl enable --now tailscaled && tailscale up` inside. This is
per-container configuration; it can't go in a template.

## 11. A program that only listens on 127.0.0.1 can't be reached from the app

**Why.** Bridges and helpers (a mail bridge, a local model server) often
bind to localhost only, so they must run in the same container as the app,
and they count toward its memory.

**Fix.** Install them in the same container and raise its memory
(`pct set <ctid> -memory 1024`). If such a helper uses a certificate it made
itself, the app needs an explicit "accept this server's own certificate"
setting rather than turning verification off everywhere.

## 12. A build succeeds but the template is broken

**Why.** Package installs inside a chroot can fail quietly, and nothing
looked at the result.

**Fix.** After every install step, check the file it should have produced
and stop if it isn't there. Run `check-template.py` on the finished archive.
State in the hand-off whether anyone has booted the template.
