#!/bin/sh
# Install or upgrade ais-reporter on an OpenWrt/RutOS host.
#
#   tools/install-remote.sh
#   REMOTE=root@192.168.1.1 tools/install-remote.sh
#
# Uploads alongside the live files and checks the new scripts against the host's
# config before swapping them in, so a bad upload or config leaves the old install
# running. An existing /etc/ais-reporter.conf is kept; the example is only copied
# when there is none, and the cron job isn't added until that copy has been edited.
# An existing cron job keeps its schedule, and is repointed from wherever the
# scripts used to live, whose old copies are removed. Installs socat if it's missing,
# as firmware upgrades can remove it. The installed files are listed in
# /etc/sysupgrade.conf so a firmware upgrade with "keep settings" preserves them.
#
# Uses one multiplexed SSH connection: The host OS may block clients that open several
# SSH connections in quick succession.
set -eu

REMOTE=${REMOTE:-root@192.168.1.1}
ROOT=$(dirname "$0")/..
VERSION=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)
CP=${TMPDIR:-/tmp}/install-remote-$$.sock

for f in src/sh/ais-reporter.sh src/awk/ais-reporter.awk config/ais-reporter.conf.example; do
	[ -s "$ROOT/$f" ] || { echo "missing or empty $ROOT/$f" >&2; exit 1; }
done

echo "connecting to $REMOTE; ssh may ask for its password once, and the connection is reused after that"
ssh -fN -M -S "$CP" -o ControlPersist=10m "$REMOTE"
remote() { ssh -S "$CP" "$REMOTE" "$@" </dev/null; }
put() { scp -O -q -o "ControlPath=$CP" "$1" "$REMOTE:$2"; }

STAMPED=$(mktemp)
cleanup() {
	rm -f "$STAMPED"
	remote 'rm -rf /usr/local/bin/ais-reporter.new' || true
	ssh -S "$CP" -O exit "$REMOTE" 2>/dev/null || true
}
trap cleanup EXIT

echo "making sure socat is installed"
remote 'command -v socat >/dev/null || { opkg update && opkg install socat; }'

echo "uploading ais-reporter $VERSION"
sed "s/^VERSION=dev\$/VERSION=$VERSION/" "$ROOT/src/sh/ais-reporter.sh" >"$STAMPED"
remote 'mkdir -p /usr/local/bin/ais-reporter.new'
put "$STAMPED" /usr/local/bin/ais-reporter.new/ais-reporter.sh
put "$ROOT/src/awk/ais-reporter.awk" /usr/local/bin/ais-reporter.new/ais-reporter.awk
remote 'chmod 755 /usr/local/bin/ais-reporter.new/ais-reporter.sh'

# sysupgrade keeps a symlink but not its target, so the config must be a real file.
# Expansions here are meant for the host's shell.
# shellcheck disable=SC2016
remote 'f=/etc/ais-reporter.conf
	if [ -L $f ]; then
		if [ -e $f ]; then cp $f $f.tmp && mv -f $f.tmp $f; else rm -f $f; fi
	fi'

# Not a plain `if remote test`: a dropped connection must not read as "no config".
config=$(remote 'if [ -e /etc/ais-reporter.conf ]; then echo keep; else echo copy; fi')
if [ "$config" = copy ]; then
	echo "no /etc/ais-reporter.conf on $REMOTE; installing the example"
	put "$ROOT/config/ais-reporter.conf.example" /etc/ais-reporter.conf
else
	echo "checking the new scripts against /etc/ais-reporter.conf"
	remote '/usr/local/bin/ais-reporter.new/ais-reporter.sh check-config' || {
		echo "fix /etc/ais-reporter.conf on $REMOTE and run this again; the old scripts are still in place" >&2
		exit 1
	}
fi

echo "swapping in the new scripts and listing them in /etc/sysupgrade.conf"
# Expansions here are meant for the host's shell.
# shellcheck disable=SC2016
remote 'mv /usr/local/bin/ais-reporter.new/ais-reporter.awk /usr/local/bin/ais-reporter.awk &&
	mv /usr/local/bin/ais-reporter.new/ais-reporter.sh /usr/local/bin/ais-reporter.sh || exit 1
	[ ! -e /etc/sysupgrade.conf ] || sed -i -e "/^[[:space:]]*\/.*\/ais-reporter\.sh[[:space:]]*$/d" \
		-e "/^[[:space:]]*\/.*\/ais-reporter\.awk[[:space:]]*$/d" /etc/sysupgrade.conf
	[ -z "$(tail -c1 /etc/sysupgrade.conf 2>/dev/null)" ] || echo >>/etc/sysupgrade.conf
	files="/usr/local/bin/ais-reporter.sh /usr/local/bin/ais-reporter.awk /etc/ais-reporter.conf /etc/crontabs/root"
	for f in $files; do
		grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >>/etc/sysupgrade.conf
	done
	kept=$(sysupgrade -l 2>/dev/null)
	for f in $files; do
		echo "$kept" | grep -qF "$f" ||
			echo "WARNING: sysupgrade -l does not list $f; it may not survive a firmware upgrade" >&2
	done
	true'

if [ "$config" = copy ]; then
	echo "edit /etc/ais-reporter.conf on $REMOTE, then run this again to add the cron job"
	exit 0
fi

echo "making sure the cron job is in place, then sending a report"
# Expansions here are meant for the host's shell.
# shellcheck disable=SC2016
remote 'mkdir -p /etc/crontabs && touch /etc/crontabs/root || exit 1
	for old in $(grep -o "[^[:space:]]*/ais-reporter\.sh" /etc/crontabs/root); do
		[ "$old" = /usr/local/bin/ais-reporter.sh ] || rm -f "$old" "${old%.sh}.awk"
	done
	sed -i "s#[^[:space:]]*/ais-reporter\.sh#/usr/local/bin/ais-reporter.sh#" /etc/crontabs/root
	[ -z "$(tail -c1 /etc/crontabs/root)" ] || echo >>/etc/crontabs/root
	grep -qF /usr/local/bin/ais-reporter.sh /etc/crontabs/root ||
		echo "*/15 * * * * /usr/local/bin/ais-reporter.sh >> /var/log/ais-reporter.log 2>&1" >>/etc/crontabs/root
	/etc/init.d/cron enable; /etc/init.d/cron restart ||
		echo "WARNING: could not restart cron; the job may not run until a reboot" >&2
	grep -F /usr/local/bin/ais-reporter.sh /etc/crontabs/root
	/usr/local/bin/ais-reporter.sh ||
		echo "WARNING: the test report failed" >&2'
