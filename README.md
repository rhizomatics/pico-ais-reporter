# pico-ais-reporter

[![boat tech directory](https://boat-tech-directory.rhizomatics.org.uk/images/badge.svg)](https://boat-tech-directory.rhizomatics.org.uk) [![managed by hq](https://raw.githubusercontent.com/rhizomatics/hq/main/assets/badge-managed-by-hq.svg)](https://github.com/rhizomatics/hq)

## What it Does

This was designed for a boat that used plugins on a SignalK server to report AIS data, and post its own position.

Without self-reporting, short station reporting would often leave large gaps between position updates, so the boat could be hours out of date on popular apps. If the SignalK server failed, or was shut down to conserve the house batteries when sailing, the AIS wouldn't get reported.

The pico reporter self-reports to popular AIS aggregators using tiny scripts that can easily run on the boat's router, for example a popular Teltonika cellular modem/router, and by using the router's own GPS it can do so without running any of the boat's NMEA infrastructure, for a minimal power footprint.

Aside from friends and family tracking where you are, this also enables AIS based anchor watches, including for other boats using AIS data to track neighbouring boats swinging or dragging.

## How it Works

The pico AIS position reporter is implemented solely as shell script and awk, taking positions from the host's `gpsd`. It is tested on a Teltonika RUT956 router, with only `socat` installed as an extra package via the RutOS web UI.

It reads the router's internal GPS and broadcasts a standard AIS Class A  position report (`!AIVDM` Type 1) over UDP to public AIS aggregators, such as MarineTraffic / VesselFinder, AISHub etc and will automatically stand down when the primary server - usually a SignalK box - can be pinged.

There may be no space on the router to install Python, so this is plain POSIX `ash` + `awk`, running as a single-shot `cron` job rather than a daemon. It only requires `socat` to be installed first, and the router to have its own internal GPS, with `gpsctl`.

## How it works

1. **GPS**: read directly via the router's `gpsctl` utility (`-s` fix
   status, `-i` latitude, `-x` longitude, `-S` speed over ground in knots,
   `-r` track made good true, `-e` UTC datetime). No NMEA forwarding setup
   needed.
2. **Encode**: `ais-reporter.awk` builds the 168-bit AIS Type 1 payload
   (message id, MMSI, nav status, SOG, position, COG, timestamp) and
   6-bit-armors it into a standard `!AIVDM,1,1,,A,<payload>,<fillbits>*<checksum>`
   sentence. Pure POSIX awk - no gawk extensions - so it runs under BusyBox
   awk.
3. **Send**: one UDP datagram per configured target, via `socat`. The
   on-device BusyBox `nc` (`nc [IPADDR PORT]`) is TCP-only on tested firmware
   build - no `-u`/`-l`/`-w`/`-z` - so `socat` (opkg, ~71KB) is used instead.
4. **Suppression**: before doing anything, optionally checks whether another
   host (e.g. a SignalK server or NMEA-Ethernet bridge) is reachable. If
   so, it's assumed that device is already the vessel's live AIS source, and
   this script stays silent for that run.

## Install

> [!NOTE]
> These instructions assume an OpenWrt-based Teltonika RutOS router. `gpsctl` and `awk` (BusyBox) are already part of stock RutOS firmware.

Use `tools/install-remote.sh` to install or upgrade. The default account is `root` on host at `192.168.1.1`. Use the `REMOTE` environment variable to change that.

```bash
REMOTE=root@192.168.100.10 tools/install-remote.sh
```

It installs `socat` if it's missing, and puts the scripts in `/usr/local/bin`, which is on the writable overlay.

On a first install it copies the example config to `/etc/ais-reporter.conf`. Edit that, then run the script again to check the config, add the cron job and send a first report. Nothing is sent until the config has an `MMSI`, and an existing config is never overwritten.

Fill in these settings in `/etc/ais-reporter.conf`:

- `MMSI` - your vessel's real, licensed MMSI.
- `NAV_STATUS` - defaults to 15 (not defined)
   -  Use 8 for "under way sailing" if you want that reflected instead.
- `TARGETS` - `host:port` UDP endpoints for each AIS aggregator
  - See station/feeder dashboard (MarineTraffic "Add AIS stream", VesselFinder "Set up station",
  AISHub registration )
  - These can be host names (requires DNS) or resolved IP addresses.
- `SUPPRESS_CHECK_HOST` / `SUPPRESS_CHECK_PORT` - optional
  - Leave `SUPPRESS_CHECK_HOST` empty to always report regardless of what else is on
  the network.
  - Port number can be any port on the server that will be up when its actively sending AIS - this could be SignalK web app port, NMEA0183 on 10110 etc.

### Firmware upgrades

A RutOS upgrade removes `ais-reporter`, including its config, unless its files are listed in `/etc/sysupgrade.conf`. `tools/install-remote.sh` adds them, along with `/etc/crontabs/root`, and warns if `sysupgrade -l` doesn't list them.

- Upgrade with "keep settings" on, and keep your own copy of `/etc/ais-reporter.conf`.
- `socat` is a package, not one of those files. Turn on [Package Restore](https://wiki.teltonika-networks.com/view/RUT956_Package_Manager) in the Package Manager before upgrading, but it's not documented whether that covers packages installed with `opkg` on the command line.
- Run `tools/install-remote.sh` after every upgrade. It reinstalls `socat` if needed, and is safe to repeat.

## Run manually

```sh
/usr/local/bin/ais-reporter.sh
```

Logs one line to stderr per run (fix status, sentence sent, target count).
Exits 0 in all "nothing to do" cases (no fix yet, suppressed) so it never
spams cron's error mail. A missing `socat` exits non-zero.

To see what's installed, or check the config and dependencies without sending anything:

```sh
/usr/local/bin/ais-reporter.sh version
/usr/local/bin/ais-reporter.sh check-config
```

## Cron

`tools/install-remote.sh` adds this to `/etc/crontabs/root`:

```
*/15 * * * * /usr/local/bin/ais-reporter.sh >> /var/log/ais-reporter.log 2>&1
```

`/var/log` is tmpfs on this device, so the log doesn't wear flash and is cleared on reboot. To change the reporting period, edit the `*/15` and run `/etc/init.d/cron restart`. The script keeps an existing line's schedule, and repoints it if the scripts used to live somewhere else.


## Future Developments

Paths were chosen to make packaging straightforward later:

- runtime scripts under `/usr/sbin` or a dedicated dir
- config under `/etc`,
- an init.d wrapper if a periodic daemon mode is ever wanted instead of cron
- `socat` as a declared `Depends:` in the control file.

RutOS has announced change to a Yocto based build, so some of these options may change in future.
