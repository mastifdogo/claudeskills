# On the Proxmox host

Commands run in the **node's** shell (Datacenter → the node → Shell), not
inside a container. `<ctid>` is the container's number.

## Get the template onto the host

```sh
cd /var/lib/vz/template/cache
wget https://github.com/<owner>/<repo>/releases/download/<tag>/<template>.tar.zst
sha256sum <template>.tar.zst      # compare with SHA256SUMS on the release
```

Or in the GUI: the storage → CT Templates → Download from URL (paste the URL
and the SHA-256) or Upload. It then appears when creating a container.

## Create the container

GUI: Create CT → pick the template → **Unprivileged: yes** → set a root
password (this is the console password; the template has none) → after
creating, Options → Features → **Nesting: on**.

Shell:

```sh
pct create <ctid> local:vztmpl/<template>.tar.zst \
  --hostname <name> --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 256 --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp --password
pct start <ctid>
```

## Data on the host (bind mount)

```sh
pct set <ctid> -mp0 /mnt/pve/<share>/<dir>,mp=/app/data
chown 100990:100990 /mnt/pve/<share>/<dir>   # 100000 + the service user's UID in the container
```

Do this before the first start, so first boot finds the directory writable.
On an NFS share that maps users, set the mapping on the NAS instead.

## Getting in

| | |
|---|---|
| `pct enter <ctid>` | A root shell in the container. Needs no password and no login program: the way in when the console or SSH doesn't work. |
| Console tab | Username `root`, the password from Create CT. |
| `pct exec <ctid> -- journalctl -u <app>-firstboot` | First-boot progress without entering. |
| `pct set <ctid> -memory 1024` | More memory, applied at once. |

SSH as root with a password is refused by Debian's default configuration;
use a key (Create CT takes one) or `pct enter`.

## First things to check after the first start

```sh
pct exec <ctid> -- systemctl status <app>-firstboot <app> --no-pager
pct exec <ctid> -- hostname -I
```

Then open `http://<address>:<port>/` and log in with what the release notes
and `/etc/motd` say.

## Changes that are per-container, not in the template

Device passthrough (Tailscale's `/dev/net/tun`: pitfall 10), extra mounts,
memory and CPU, the network. Document them; a template can't carry them.
