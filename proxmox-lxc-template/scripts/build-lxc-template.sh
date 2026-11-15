#!/usr/bin/env bash
# Builds a Proxmox LXC template (rootfs .tar.zst) with an application
# pre-installed. A starting point: copy it into the application's repository
# as deploy/lxc-template/build-lxc-template.sh, set the APP section, and adapt
# the customize hook to what the application needs.
#
# Run as root on Debian or Ubuntu (a Proxmox host works too):
#   apt install mmdebstrap zstd
#   sudo deploy/lxc-template/build-lxc-template.sh --release dist/myapp-v1.2.3-linux-amd64.tar.gz
#
# The template holds no secrets: SSH host keys, machine-id and any database
# cluster are removed, and each new container makes its own at first boot
# (<app>-firstboot).
set -euo pipefail

# --- APP: change these ------------------------------------------------------------
APP=myapp                       # lowercase; names the template, units and paths
APP_USER_UID=990                # fixed, so a host directory can be chown'ed for it (100000 + this)
# Packages the container needs. --variant=apt installs almost nothing, so list
# everything, including what a person notices only when it is missing:
#   systemd-sysv  init          login     the console's login prompt (not default from Debian 13)
#   dbus          systemctl     iproute2, ifupdown, isc-dhcp-client   Proxmox's network setup
PACKAGES=(systemd-sysv dbus login iproute2 iputils-ping ifupdown isc-dhcp-client openssh-server ca-certificates curl less nano procps tzdata)
# A newer PostgreSQL than the distribution's, from apt.postgresql.org; empty for none.
PG_VERSION=""
# Units to enable in the image.
UNITS=("$APP-firstboot.service" "$APP.service")
# Files that must exist in the finished image; the build fails if one is missing.
REQUIRE=(usr/bin/login "usr/local/bin/$APP" "usr/local/sbin/$APP-firstboot")
# 1 if the application's installer downloads anything (a voice model, a
# runtime): the image then gets name resolution while the installer runs.
INSTALL_NEEDS_NETWORK=0
# A command run inside the finished image, as the service user, that proves
# the application really works there (see pitfall 12). Empty for none, e.g.
#   SMOKE_TEST="/usr/local/bin/$APP --version"
SMOKE_TEST=""
# ------------------------------------------------------------------------------------

SUITE=trixie # Debian 13
ARCH=amd64
MIRROR=http://deb.debian.org/debian
OUT_DIR=""
RELEASE=""
VERSION=""

usage() {
	cat <<USAGE
Usage: $0 --release FILE [options]

  --release FILE   the application's release tarball (one top-level directory with deploy/install.sh)
  --suite NAME     Debian release to build on (default: $SUITE)
  --arch ARCH      amd64 (default) or arm64; must match the release
  --mirror URL     Debian mirror (default: $MIRROR)
  --version V      version in the file name (default: from the tarball's name)
  --out DIR        output directory (default: ./dist)
USAGE
}
die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--release) RELEASE=${2:?}; shift ;;
	--suite) SUITE=${2:?}; shift ;;
	--arch) ARCH=${2:?}; shift ;;
	--mirror) MIRROR=${2:?}; shift ;;
	--version) VERSION=${2:?}; shift ;;
	--out) OUT_DIR=${2:?}; shift ;;
	-h | --help) usage; exit 0 ;;
	*) usage >&2; die "unknown option: $1" ;;
	esac
	shift
done

[ "$(id -u)" -eq 0 ] || die "run as root (mmdebstrap runs the install inside the image)"
command -v mmdebstrap >/dev/null || die "mmdebstrap not found: apt install mmdebstrap zstd"
command -v zstd >/dev/null || die "zstd not found: apt install zstd"
[ -f "$RELEASE" ] || die "--release FILE is required"
case "$SUITE" in
bookworm) OS_VERSION=12 ;;
trixie) OS_VERSION=13 ;;
*) die "unsupported --suite $SUITE (add its version number here once it has been tested)" ;;
esac
case "$ARCH" in amd64 | arm64) ;; *) die "unsupported --arch $ARCH" ;; esac

here=$(cd "$(dirname "$0")" && pwd)
OUT_DIR=${OUT_DIR:-$PWD/dist}
[ -n "$VERSION" ] || VERSION=$(basename "$RELEASE" | sed -n "s/^$APP-\(.*\)-linux-.*$/\1/p")
[ -n "$VERSION" ] || die "can't tell the version from $RELEASE; pass --version"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/release"
mkdir -p "$stage"
tar -xzf "$RELEASE" -C "$stage" --strip-components=1
[ -f "$stage/deploy/install.sh" ] || die "$RELEASE has no deploy/install.sh"
for f in "$APP-firstboot.sh" "$APP-firstboot.service" "$APP-after-firstboot.conf"; do
	[ -f "$here/$f" ] || die "missing $here/$f"
	cp "$here/$f" "$work/"
done

# Sources name Debian's keyring explicitly, so the build works on any host:
# apt on an Ubuntu machine doesn't trust Debian's keys by default, and an
# old keyring doesn't know a new release's. The keyring package also goes in
# the image so the same path resolves inside containers.
keyring=/usr/share/keyrings/debian-archive-keyring.gpg
[ -s "$keyring" ] || die "$keyring not found on this machine: apt install debian-archive-keyring (from the release being built)"
sources=(
	"deb [signed-by=$keyring] $MIRROR $SUITE main"
	"deb [signed-by=$keyring] $MIRROR $SUITE-updates main"
	"deb [signed-by=$keyring] http://security.debian.org/debian-security $SUITE-security main"
)
pkg_list=$(IFS=,; echo "${PACKAGES[*]},debian-archive-keyring")

name="debian-$OS_VERSION-${APP}_${VERSION}_$ARCH.tar.zst"
mkdir -p "$OUT_DIR"
output="$OUT_DIR/$name"

# --- In-image customisation (runs on the build host; $1 is the image's root) ------
cat >"$work/customize.sh" <<CUSTOMIZE
#!/bin/sh
set -eu
root=\$1
in_root() { chroot "\$root" env DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 "\$@"; }
# Checked from inside the image: a symlink with an absolute target would
# otherwise be followed on this machine and look missing (pitfall 13).
need() { in_root test -e "/\$1" || { echo "the image is missing /\$1" >&2; exit 1; }; }
net_on() { made_resolv=0; if [ ! -s "\$root/etc/resolv.conf" ]; then cp /etc/resolv.conf "\$root/etc/resolv.conf"; made_resolv=1; fi; }
net_off() { if [ "\$made_resolv" = 1 ]; then rm -f "\$root/etc/resolv.conf"; fi; }

mkdir -p "\$root/opt/$APP-release"
cp -R "$stage/." "\$root/opt/$APP-release/"

if [ -n "$PG_VERSION" ]; then
	# The image needs name resolution for this step only.
	net_on
	in_root sh /opt/$APP-release/deploy/pgdg.sh
	in_root apt-get update -q >/dev/null
	in_root apt-get install -y -q postgresql-$PG_VERSION >/dev/null
	in_root apt-get clean
	net_off
	need usr/lib/postgresql/$PG_VERSION/bin/postgres
	# Drop the cluster the package made: every container creates its own at first boot.
	for c in "\$root"/etc/postgresql/*/main; do
		[ -d "\$c" ] || continue
		in_root pg_dropcluster "\$(basename "\$(dirname "\$c")")" main
	done
fi

# The application, installed by its own installer (the one a manual install uses).
if [ "$INSTALL_NEEDS_NETWORK" = 1 ]; then net_on; fi
in_root env APP_UID=$APP_USER_UID sh /opt/$APP-release/deploy/install.sh >/dev/null
if [ "$INSTALL_NEEDS_NETWORK" = 1 ]; then net_off; fi
rm -rf "\$root/opt/$APP-release"

# First-boot provisioning, and the application waits for it.
install -m 0755 "$work/$APP-firstboot.sh" "\$root/usr/local/sbin/$APP-firstboot"
install -m 0644 "$work/$APP-firstboot.service" "\$root/etc/systemd/system/$APP-firstboot.service"
install -d "\$root/etc/systemd/system/$APP.service.d"
install -m 0644 "$work/$APP-after-firstboot.conf" "\$root/etc/systemd/system/$APP.service.d/firstboot.conf"
in_root systemctl enable ${UNITS[*]} >/dev/null 2>&1

cat >"\$root/etc/motd" <<'MOTD'

  $APP: first-boot setup has not finished yet.
  Check:  systemctl status $APP-firstboot

MOTD

# What a person finds missing only on their own server: check it now.
for f in ${REQUIRE[*]}; do need "\$f"; done
for u in ${UNITS[*]}; do
	in_root systemctl is-enabled "\$u" >/dev/null || { echo "\$u is not enabled in the image" >&2; exit 1; }
done
# And that it runs: the same binary, user and libraries the container will have.
if [ -n "$SMOKE_TEST" ]; then
	in_root runuser -u $APP -- sh -c 'cd /tmp && $SMOKE_TEST' || { echo "the smoke test failed inside the image" >&2; exit 1; }
	rm -rf "\$root"/tmp/*
fi

# Nothing that must be unique per container, and no caches.
rm -f "\$root"/etc/ssh/ssh_host_*
: >"\$root/etc/machine-id"
rm -f "\$root/var/lib/dbus/machine-id" "\$root/etc/hostname"
rm -rf "\$root"/var/lib/apt/lists/* "\$root"/var/cache/apt/*.bin "\$root"/var/cache/apt/archives/*.deb
find "\$root/var/log" -type f -exec truncate -s 0 {} +
rm -rf "\$root"/tmp/* "\$root"/var/tmp/* "\$root/root/.bash_history"
CUSTOMIZE
chmod +x "$work/customize.sh"

log "building $name ($APP $VERSION on Debian $OS_VERSION, $ARCH)"
mmdebstrap \
	--variant=apt \
	--architectures="$ARCH" \
	--include="$pkg_list" \
	--skip=output/dev \
	--dpkgopt='path-exclude=/usr/share/man/*' \
	--dpkgopt='path-exclude=/usr/share/doc/*' \
	--dpkgopt='path-include=/usr/share/doc/*/copyright' \
	--dpkgopt='path-exclude=/usr/share/locale/*' \
	--dpkgopt='path-include=/usr/share/locale/locale.alias' \
	--customize-hook="$work/customize.sh \"\$1\"" \
	"$SUITE" "$output" "${sources[@]}"

log "template written: $output ($(du -h "$output" | cut -f1))"
cat <<NEXT

Check it:    python3 <this skill>/scripts/check-template.py $output
Use it:      copy to /var/lib/vz/template/cache/ on the Proxmox host, then
             Create CT > Template: $name  (unprivileged, nesting on)
NEXT
