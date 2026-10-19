# pico-ais-reporter

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

## Prerequisites on the router

### Teltonika RutOS / OpenWRT

```sh
opkg update
opkg install socat
```

`gpsctl` and `awk` (BusyBox) are already part of stock RutOS firmware.

## Install

Optionally create a new user to own this script, from the *System* / *Administration* / *User Settings* menu.

Copy the two runtime files to the router (paths below assume the scripts will
be owned by the `ais` user, at `/usr/local/home/user/`, which is on the writable
overlay with space to spare):

```sh
scp src/sh/ais-reporter.sh ais@<router>:/usr/local/home/user/
```
```sh
scp src/awk/ais-reporter.awk ais@<router>:/usr/local/home/user/
```

Copy `config/ais-reporter.conf.example` to `/etc/ais-reporter.conf` (or symlink
`/etc/ais-reporter.conf` to a copy kept alongside the scripts) and fill in:

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

### Teltonika RutOS / OpenWRT

Add these lines to `/etc/sysupgrade.conf` to ensure it's not wiped during a firmware upgrade.

```
  /etc/ais-reporter.sh
  /usr/local/home/user/ais-reporter.sh
  /usr/local/home/user/ais-reporter.awk
```


## Run manually

```sh
/usr/local/home/user/ais-reporter.sh
```

Logs one line to stderr per run (fix status, sentence sent, target count).
Exits 0 in all "nothing to do" cases (no fix yet, suppressed) so it never
spams cron's error mail.

## Cron

```
*/15 * * * * /usr/local/home/user/ais-reporter.sh >> /var/log/ais-reporter.log 2>&1
```

Add via `/etc/crontabs/root` (busybox `crond` picks up changes without a
restart). `/var/log` is tmpfs on this device, so the log doesn't wear flash
and is cleared on reboot. Adjust the `*/15` for a different reporting
period.


## Future Developments

Paths were chosen to make packaging straightforward later: 

- runtime scripts under `/usr/sbin` or a dedicated dir
- config under `/etc`,
- an init.d wrapper if a periodic daemon mode is ever wanted instead of cron
- `socat` as a declared `Depends:` in the control file. 

RutOS has announced change to a Yocto based build, so some of these options may change in future.