#!/bin/sh
# First boot of a container made from the template. Installed as
# /usr/local/sbin/myapp-firstboot and run once by myapp-firstboot.service,
# before myapp.service. It gives every container its own:
#   - SSH host keys (if Proxmox didn't make them)
#   - database cluster, roles and password (written to /etc/myapp/myapp.env)
#   - first login
# Safe to run again: it stops at once if the state file exists, and each step
# checks before it acts. Works without systemd, so it can be tried in a chroot.
set -eu

APP=myapp
STATE=/var/lib/$APP/provisioned
ENV_FILE=/etc/$APP/$APP.env
DATA_DIR=/app/data
ADMIN_USER=admin
# A known first password lets the release notes say how to log in, but then the
# application MUST force a change at the first login. If it can't, generate one
# instead (see below) and tell the admin where it is.
FIRST_PASSWORD=""

log() { echo "$APP-firstboot: $*"; }
[ -f "$STATE" ] && { log "already provisioned"; exit 0; }

if command -v ssh-keygen >/dev/null 2>&1 && ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
	log "generating SSH host keys"
	ssh-keygen -A
fi

# --- PostgreSQL: one cluster per container (the template ships none) -----------
ver=$(find /usr/lib/postgresql -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -V | tail -n1)
if [ -n "$ver" ]; then
	if [ ! -d "/etc/postgresql/$ver/main" ]; then
		log "creating PostgreSQL $ver cluster"
		pg_createcluster --locale C.UTF-8 "$ver" main >/dev/null
	fi
	# Settings sized for this container, if the application ships them.
	[ -f "/usr/local/share/$APP/postgresql.conf" ] && install -m 0644 "/usr/local/share/$APP/postgresql.conf" "/etc/postgresql/$ver/main/conf.d/$APP.conf"
	if [ -d /run/systemd/system ]; then systemctl start "postgresql@$ver-main"; else pg_ctlcluster "$ver" main start; fi
	for _ in $(seq 1 30); do pg_isready -q && break; sleep 1; done
	pg_isready -q || { log "PostgreSQL did not start"; exit 1; }

	if ! grep -q '^DATABASE_URL=' "$ENV_FILE" 2>/dev/null; then
		log "creating the database"
		db_pw=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-28)
		runuser -u postgres -- psql -qv ON_ERROR_STOP=1 <<SQL
CREATE ROLE $APP LOGIN PASSWORD '$db_pw';
CREATE DATABASE $APP OWNER $APP;
SQL
		install -d -m 0750 -g "$APP" "$(dirname "$ENV_FILE")"
		(umask 027 && printf 'DATABASE_URL=postgres://%s:%s@127.0.0.1:5432/%s\n' "$APP" "$db_pw" "$APP" >>"$ENV_FILE")
		chgrp "$APP" "$ENV_FILE"
	fi
fi

# --- First login ---------------------------------------------------------------
if [ -z "$FIRST_PASSWORD" ]; then
	FIRST_PASSWORD=$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | cut -c1-14)
	(umask 077 && printf '%s\n' "$FIRST_PASSWORD" >"/root/$APP-admin-password")
	login_note="$ADMIN_USER / the password in /root/$APP-admin-password"
else
	login_note="$ADMIN_USER / $FIRST_PASSWORD the first time; you then choose your own"
fi
# Replace with the application's own way of creating a user, e.g.:
#   myapp-user add "$ADMIN_USER" --password-stdin --must-change
log "creating login user $ADMIN_USER"

# --- The data directory (often a bind mount from the host) ---------------------
if ! runuser -u "$APP" -- sh -c "touch $DATA_DIR/.write-test && rm $DATA_DIR/.write-test" 2>/dev/null; then
	log "WARNING: $DATA_DIR is not writable by the $APP user (UID $(id -u "$APP"))."
	log "         On the Proxmox host: chown $((100000 + $(id -u "$APP"))):$((100000 + $(id -g "$APP"))) <the mounted directory>"
fi

cat >/etc/motd <<MOTD

  $APP
  Web:     http://<this container's address>:8080/   (hostname -I)
  Login:   $login_note
  Logs:    journalctl -u $APP -f
  Data:    $DATA_DIR

MOTD

# Last, so a run that failed part-way is tried again at the next boot.
mkdir -p "$(dirname "$STATE")"
date -u +%Y-%m-%dT%H:%M:%SZ >"$STATE"
log "done"
