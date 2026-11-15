---
name: proxmox-lxc-template
description: Build a ready-to-run Proxmox LXC container template (a Debian rootfs .tar.zst with an application, its database and first-boot setup pre-installed), publish it from GitHub Actions, and get a container made from it running. Use when asked to package an app or service as a Proxmox container or CT template, build or fix an LXC template or its build script, set up first-boot provisioning, or debug a container made from such a template (can't log in on the console, service won't start, Tailscale or bind mounts not working).
---

# Proxmox LXC templates

A **template** is a root filesystem archive (`<distro>-<version>-<app>_<ver>_<arch>.tar.zst`)
that Proxmox unpacks into a new container. A good one starts a working
application the first time the container boots, with nothing secret baked in.

This skill is the method that produced a working template for a Node.js +
PostgreSQL app, including the mistakes that only showed up on a real Proxmox
host. Those are in `references/pitfalls.md`: **read it before writing or
changing a build script**, and again when a container misbehaves.

## What you produce

| File | What it is |
|---|---|
| `deploy/lxc-template/build-lxc-template.sh` | Builds the template with `mmdebstrap` (start from `scripts/build-lxc-template.sh`) |
| `deploy/lxc-template/<app>-firstboot.sh` + `.service` | Runs once in each new container: database, secrets, first login (`assets/firstboot.*`) |
| `deploy/<app>.service` | The application's systemd unit (`assets/app.service`) |
| `.github/workflows/release.yml` | Tests, builds the template, publishes a GitHub Release (`assets/release.yml`) |
| `.github/workflows/ci.yml` | Builds and checks the template on every push, publishing nothing (`assets/ci.yml`) |
| docs | How to create a container from it, in the user's words (`references/proxmox.md` has the commands) |

Copy the files from this skill into the application's repository and adapt
them: they are starting points with `APP`/`app` placeholders, not a tool to
call. Keep the repository's own conventions where it has them.

## 1. Find out what the container must hold

Ask, or read from the repository, before writing anything:

- **What runs**: the program and how it starts (one long-running service? a
  timer?), the port it listens on, the user it should run as.
- **What it needs installed**: runtime (ship it inside the release rather
  than using the distribution's, so the version is yours), database, other
  packages. Every package is asked for explicitly: see pitfall 1.
- **What must be unique per container**: database passwords, app secrets,
  the first admin login, SSH host keys. None of these go in the image.
- **Where data lives**: inside the container, or on a host directory
  bind-mounted in (then fix the service user's UID so the host can `chown`
  for it: see `references/proxmox.md`).
- **How big**: memory and disk. Tune the database for it (a 512 MB container
  needs PostgreSQL's defaults turned down) and cap the service
  (`MemoryMax=`).
- **How it is set up**: prefer the application's own web page for
  everything, including choosing the admin password on the first visit, so
  nobody needs the console (pitfall 15). The Proxmox console is text only.
- **How it updates**: nothing, or an updater inside the container. If it
  asks GitHub for releases, read pitfall 9; if it installs them, pitfall 18.

Use the current Debian stable unless told otherwise. Don't add Ubuntu or a
second suite "for flexibility": each one is another thing to test.

## 2. The build script

Start from `scripts/build-lxc-template.sh`. It:

1. checks it is root and has `mmdebstrap` and `zstd`;
2. stages the application's release (a tarball or a build directory);
3. runs `mmdebstrap --variant=apt` with an explicit package list and
   `signed-by` sources, so it builds the same on a Debian or an Ubuntu host;
4. in a customize hook: installs extra package sources (e.g. a newer
   PostgreSQL) and the app, enables its units, **asserts that what the
   container needs is really there**, and strips everything that must be
   unique or is just bulk;
5. writes `dist/<distro>-<version>-<app>_<ver>_<arch>.tar.zst`.

Rules that came from real failures:

- **`--variant=apt` installs almost nothing.** List `systemd-sysv`, `dbus`,
  `login`, the network tools Proxmox expects, `ca-certificates` and anything
  the app shells out to. Then *assert* the important ones exist in the image
  (`[ -x "$root/usr/bin/login" ] || fail`). A missing package builds fine
  and fails only on someone's server.
- **Nothing unique in the image**: remove SSH host keys, empty
  `/etc/machine-id`, remove `/etc/hostname`, drop the database cluster the
  package created, write no passwords.
- **The app is installed by its own installer**, the same one a manual
  install uses, run inside the image with `chroot`. One install path to keep
  right.
- **Fail loudly**: `set -euo pipefail`, and every "did X install" is a check
  that stops the build.
- **Check from inside the image.** A path through an absolute symlink
  resolves on the build machine when tested from outside (pitfall 13); the
  script's `need` uses `chroot`. Make the installer's own links relative.
- **Run it once in the image** (`SMOKE_TEST`): the application doing its
  real job as the service user, before the image is packed.
- **Pin what the installer downloads** with a SHA-256, and set
  `INSTALL_NEEDS_NETWORK=1` for that step (pitfall 17).

Run `python3 scripts/check-template.py dist/<file>.tar.zst --require usr/bin/<your-binary>`
after every build. It lists what is wrong with an image (no login program,
host keys left in, a machine-id, no init, world-readable secrets) without
needing a Proxmox host.

## 3. First boot

`assets/firstboot.sh` runs once, before the app, from a oneshot unit with
`ConditionPathExists=!<state file>`; the app's unit gets a drop-in with
`Requires=` and `After=` on it (`assets/after-firstboot.conf`). It:

- generates SSH host keys if Proxmox didn't;
- creates the database cluster, roles and a random password, written to the
  app's environment file (mode 0640, root and the app's group);
- creates the first login, unless the application asks for the password on
  the first visit to its web page (better: then there is nothing to create
  or to read from a file). If it has to be a known password (so the release
  notes can state it), the app must **force a change at the first login**;
  otherwise generate one and write it to a root-only file named in `/etc/motd`;
- checks the data directory is writable by the service user and says so
  plainly if not (the usual bind-mount ownership mistake);
- replaces `/etc/motd` with where things are: URL, login, logs, users, and
  writes `/etc/issue` so the console shows the web address above the login
  prompt;
- writes the state file last, so a failed run is retried at the next boot.
  The state file is on the container's own disk, never in a data directory
  that may be a mount (pitfall 14).

It must be safe to run twice and must work without systemd (so it can be
tested in a chroot: `pg_ctlcluster` instead of `systemctl start`).

## 4. Publish from GitHub Actions

`assets/release.yml` is a workflow that runs on a version tag or by hand
with a tag as input: tests, release tarball, template, `SHA256SUMS`, GitHub
Release with notes that give the exact `wget` and checksum lines. Points
that matter:

- Install `mmdebstrap` and the **target suite's** `debian-archive-keyring`
  from deb.debian.org (checksummed), not from the runner's Ubuntu mirrors:
  the runner's keyring doesn't know a new Debian release's keys.
- Run the app's tests against the same database version the template ships,
  and install matching client tools if the tests call them.
- A tag with a suffix (`v1.2.3-rc.1`) is published as a pre-release. A
  re-run replaces the assets instead of failing.
- **Build the template on every push too** (`assets/ci.yml`), and tag only
  a green commit. Otherwise the tag is the first real build, and a failed
  tag can't be fixed by re-running it (pitfall 16). Expect the first CI
  build of a new template to fail on something: read the log, fix, push.
- After triggering it, **check the run finished and the release has the
  assets**. A green build is not a booted container: say which of the two
  you checked.

## 5. Getting it running, and when it doesn't

`references/proxmox.md` has the host-side steps: downloading into
`/var/lib/vz/template/cache`, creating the container (unprivileged, nesting
on), bind mounts and their ownership, the root password, `pct enter`, and
extras such as Tailscale that need a device passed in.

When a container made from the template misbehaves, don't guess from the
symptom. Open the image and look:

```sh
python3 scripts/check-template.py <template>.tar.zst --list | grep -E 'bin/login|ssh_host|machine-id'
```

Then find the symptom in `references/pitfalls.md`. Give the user two things:
the one-time fix for the container they already have (through
`pct enter <ctid>` on the host, which needs no login), and the fix in the
build so new containers are right.

## 6. What "done" means

- The build script ran (in CI if not locally) and `check-template.py` passes.
- You have said plainly what was tested and what wasn't. You can rarely boot
  the template on a real Proxmox host yourself; if nobody has, say so, and
  list what to look at on the first boot: the console login, `systemctl
  status <app>-firstboot <app>`, the web page.
- The docs tell someone who has never seen the repository how to get from
  the release page to a logged-in application.
