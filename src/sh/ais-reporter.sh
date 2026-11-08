#!/bin/sh
# ais-reporter - broadcast a synthetic AIS position report derived from the
# RUT956's internal GPS, over UDP, to one or more AIS aggregators
# (MarineTraffic / VesselFinder / AISHub / ...).
#
# Intended to run as a single shot from cron every REPORT_INTERVAL_MIN
# minutes (default 15) - there is no long-running daemon.
#
# GPS is read directly from the router's `gpsctl` utility - no NMEA
# forwarding setup needed.
#
# UDP sends use `socat` (opkg install socat) - the on-device BusyBox `nc`
# is TCP-only on this firmware and has no -u/-l/-w/-z options.
#
# Config file: /etc/ais-reporter.conf (see ais-reporter.conf.example)
#
#   ais-reporter.sh               # send one report
#   ais-reporter.sh check-config  # validate the config and dependencies, sends nothing
#   ais-reporter.sh version

set -eu

# Stamped by tools/install-remote.sh.
VERSION=dev

if [ "${1:-}" = version ]; then
    echo "$VERSION"
    exit 0
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
AWK_SCRIPT="$SCRIPT_DIR/ais-reporter.awk"

CONFIG="${AIS_REPORTER_CONF:-/etc/ais-reporter.conf}"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

: "${MMSI:?MMSI must be set (see $CONFIG)}"
: "${NAV_STATUS:=15}"
: "${TARGETS:?TARGETS must be set, e.g. \"1.2.3.4:5321 5.6.7.8:12345\"}"
: "${SUPPRESS_CHECK_HOST:=}"
: "${SUPPRESS_CHECK_PORT:=}"

log() { echo "ais-reporter: $*" >&2; }

encode() {
    awk -v mmsi="$MMSI" -v navstatus="$NAV_STATUS" \
        -v lat="$1" -v lon="$2" -v sog="$3" -v cog="$4" -v sec="$5" \
        -f "$AWK_SCRIPT" </dev/null
}

check_config() {
    ok=0
    case $MMSI in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *) log "MMSI must be 9 digits, got '$MMSI'"; ok=1 ;;
    esac
    for t in $TARGETS; do
        case $t in
            :* | *: | *:*[!0-9]*) log "target '$t' is not host:port"; ok=1 ;;
            *:*) ;;
            *) log "target '$t' is not host:port"; ok=1 ;;
        esac
    done
    for tool in socat gpsctl; do
        command -v "$tool" >/dev/null || { log "$tool is not installed"; ok=1; }
    done
    encode 0 0 0 0 0 | grep -q '^!AIVDM,' || { log "could not encode with $AWK_SCRIPT"; ok=1; }
    return $ok
}

if [ "${1:-}" = check-config ]; then
    check_config && log "$VERSION: $CONFIG OK"
    exit
fi

# A firmware upgrade can remove socat while keeping this script and its cron job.
command -v socat >/dev/null || { log "socat is not installed, re-run tools/install-remote.sh"; exit 1; }

# --- 1. Suppression check ---------------------------------------------
# If a defined host (e.g. the SignalK server or NMEA-Ethernet bridge) is
# reachable, assume it is already the vessel's live AIS source and stay
# silent - this script is only meant to cover the gap when nav electronics
# are switched off.
if [ -n "$SUPPRESS_CHECK_HOST" ]; then
    if [ -n "$SUPPRESS_CHECK_PORT" ]; then
        if socat -t2 /dev/null "TCP:$SUPPRESS_CHECK_HOST:$SUPPRESS_CHECK_PORT" 2>/dev/null; then
            log "$SUPPRESS_CHECK_HOST:$SUPPRESS_CHECK_PORT reachable, staying silent"
            exit 0
        fi
    else
        if ping -c 1 -W 2 "$SUPPRESS_CHECK_HOST" >/dev/null 2>&1; then
            log "$SUPPRESS_CHECK_HOST reachable, staying silent"
            exit 0
        fi
    fi
fi

# --- 2. Read GPS fix directly from gpsctl -------------------------------
FIX_STATUS=$(gpsctl -s 2>/dev/null || echo 0)
if [ "$FIX_STATUS" != "1" ]; then
    log "no GPS fix (gpsctl -s = '$FIX_STATUS'), skipping"
    exit 0
fi

LAT=$(gpsctl -i)
LON=$(gpsctl -x)
SOG=$(gpsctl -S)
COG=$(gpsctl -r)
SEC=$(gpsctl -e | awk -F'[: ]' '{print $NF}')

# --- 3. Encode the AIS sentence -----------------------------------------
SENTENCE=$(encode "$LAT" "$LON" "$SOG" "$COG" "$SEC")

# --- 4. Send to every configured target ---------------------------------
sent=0
total=0
for t in $TARGETS; do
    total=$((total + 1))
    host=${t%:*}
    port=${t##*:}
    if printf '%s' "$SENTENCE" | socat -t2 - "UDP-DATAGRAM:$host:$port" 2>/dev/null; then
        sent=$((sent + 1))
    else
        log "failed to send to $host:$port"
    fi
done

log "sent $SENTENCE to $sent/$total target(s)"
