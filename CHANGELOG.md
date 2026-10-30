# Changelog

## 0.1.0 - 2026-10-30

First versioned release.

### Added

- `tools/install-remote.sh` installs or upgrades `ais-reporter` on an OpenWrt/RutOS host, replacing the manual `scp` and cron steps in the README. The `REMOTE` environment variable selects the host.
  - The new scripts are checked against the host's config before the old ones are replaced, so a bad upload or config leaves the old install running.
  - An existing `/etc/ais-reporter.conf` is kept. The example config is only copied when there is none, and the cron job isn't added until that copy has been edited and the script run again.
  - `socat` is installed if it's missing, and an existing cron job keeps its schedule.
- `ais-reporter.sh version` prints the installed version, which `tools/install-remote.sh` stamps from `git describe`.
- `ais-reporter.sh check-config` validates the config and dependencies without sending anything.

### Changed

- Scripts now install to `/usr/local/bin`. `tools/install-remote.sh` moves an existing install from wherever its cron job points, and updates its `/etc/sysupgrade.conf` entries. Only the old `ais-reporter.sh` and `ais-reporter.awk` are removed, so anything else in the old directory stays.
- A symlinked `/etc/ais-reporter.conf`, which the README used to suggest, is replaced with a real file, as `sysupgrade` keeps a symlink but not its target.
- `MMSI` is blank in the example config, so an unedited copy sends nothing rather than reporting positions for a placeholder MMSI. Existing configs aren't affected.

### Fixed

- `ais-reporter` can now be kept across RutOS firmware upgrades. Previously an upgrade could remove the install: the README's `/etc/sysupgrade.conf` list had the wrong config path (`/etc/ais-reporter.sh`), and only covered scripts installed in `/usr/local/home/user`. `tools/install-remote.sh` lists all the files and warns if `sysupgrade -l` doesn't report them. Existing installs need to run the script once to be registered, and firmware upgrades need "keep settings" on. This has not yet been confirmed across a real upgrade, so keep your own copy of `/etc/ais-reporter.conf`.
- `ais-reporter.sh` now logs a clear error and exits non-zero when `socat` is missing. Previously every send failed separately, and a suppression port check could never succeed. A firmware upgrade can remove `socat`, so run `tools/install-remote.sh` after upgrading to restore it.
