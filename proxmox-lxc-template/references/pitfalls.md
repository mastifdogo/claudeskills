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

Run the application for real inside the image before it is packed: in the
customize hook, `chroot` in as the service user and make it do its job once
(start and print its version, open its database library, produce one output
file). That is the same binary, user and libraries the container will have,
and it catches a missing shared library or a wrong path that no file check
does. The build script's `SMOKE_TEST` is for this.

## 13. The build says a file is missing from the image, but the installer put it there

**Why.** The path goes through a symlink with an absolute target, such as
`/opt/myapp/current -> /opt/myapp/releases/v1.2.3`. A check made from
outside the image (`[ -e "$root/opt/myapp/current/bin/myapp" ]`) follows
that link on the *build machine*, where the target doesn't exist. Inside a
running container it would have been fine.

**Fix.** Check from inside (`chroot "$root" test -e /opt/…`, which the build
script's `need` does), and make links the installer creates relative
(`ln -sfn "releases/$version" /opt/myapp/current`) so they mean the same
thing from anywhere. `check-template.py --require` follows links inside the
archive, and notes links that point at a build directory.

## 14. A new container skips first-boot setup, or the app starts unconfigured

**Why.** The "already set up" state file was inside the data directory, and
the data directory is a mount from the host that an earlier container
already used. The new container finds the file and never runs its own setup.

**Existing container.** `pct exec <ctid> -- rm <state file>` and restart
it; first boot then runs.

**Build.** Keep the state file on the container's own disk
(`/etc/<app>/provisioned`), never under the data directory. The same goes
for anything else that belongs to one container rather than to the data.

## 15. "I don't want to set it up on the command line"

**Why.** A container's Console tab in Proxmox is a text terminal; nothing
graphical can be shown there. Setup that needs the console (reading a
generated password out of a file, editing an environment file) is the part
people get stuck on.

**Fix.** Put all setup in the application's own web page, and make the
console's only job to say where that page is:

- First visit, no password yet: the page asks the visitor to choose the
  admin password (stored hashed). Then first boot has no password to make,
  and nothing has to be read from a file. Refuse a second setup once a
  password exists.
- Keys, tokens and other settings are saved from that page into the
  application's database, not typed into `/etc/<app>/<app>.env`.
- `/etc/issue` shows the address above the login prompt:
  `http://\4:8080/` (agetty replaces `\4` with the container's IPv4
  address each time it draws the prompt).
- One way back in from the host for a forgotten password, documented:
  `pct exec <ctid> -- <app> reset-admin-password`, after which the page
  asks for a new one. If that command runs as root, have it switch to the
  service user first (`runuser -u <app> --`), or it leaves root-owned
  files in the data directory that the service can't write.

## 16. A release tag was pushed and the release failed; re-running it fails again

**Why.** The template is first built for real by the release workflow, so
the tag was the first time anyone found out it doesn't build. A tag points
at one commit: re-running the workflow builds the same broken commit.

**Fix.** Build the template on every push as well (`assets/ci.yml`: the
release tarball, the template and `check-template.py`, nothing published),
and tag only a commit whose CI is green. After a failed release, publish
the fix under a new tag; don't move the old one unless the owner asks.

## 17. The installer downloads something, and the build can't check it

**Why.** A voice model, a runtime or a prebuilt binary fetched while the
image is built. Two things go wrong: the chroot has no `/etc/resolv.conf`,
so the download fails; or it succeeds with no checksum, and the image
contains whatever the server sent that day.

**Fix.** Set `INSTALL_NEEDS_NETWORK=1` (name resolution for that step only).
Pin a SHA-256 for every download and stop on a mismatch. If the checksum
can't be found beforehand, have the first CI build print it, then pin that
value and remove the printing. A size check is not a checksum.

## 18. The application should update itself, but it runs unprivileged

**Why.** The service user can't (and shouldn't) replace root-owned code or
restart its own unit.

**Fix.** The application only *names* a version. It writes the release tag
to a request file in its data directory; a `.path` unit
(`PathExists=<that file>`) starts a root oneshot that:

1. reads the tag, deletes the request file first (a failing update must
   not be started over and over), and checks the tag against a strict
   pattern;
2. downloads that release itself from the repository named in a root-owned
   file, never from anything the service wrote, and verifies it against
   the release's `SHA256SUMS`;
3. runs the release's own installer (the one path again) and restarts the
   service.

Keep the previous release directory so going back is a symlink change.
Checking for a new version is separate and only on demand: see pitfall 9.
