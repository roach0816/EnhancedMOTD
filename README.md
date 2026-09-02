# EnhancedMOTD

EnhancedMOTD installs a compact system dashboard that is displayed when you log in to a Debian-family host. It reports system health, uptime, load, memory, disk usage, network addresses, failed systemd units, package updates, reboot status, and CPU temperature when available.

The project is distributed as one self-contained Bash installer. The repository does not need to remain on the host after installation, although keeping a clone makes upgrades convenient.

This is a Git source repository, not a Debian APT repository. Clone it or download the installer as shown below; do not add its GitHub URL to `/etc/apt/sources.list` or `/etc/apt/sources.list.d`. Packaging it for `apt install` would require a `.deb` package and a separately published, signed APT repository.

## Features

- Dynamic MOTD generated through Debian's `/etc/update-motd.d` mechanism
- Color and Unicode output with automatic plain-text fallbacks
- Responsive layout for narrow terminals
- Configurable warning and critical thresholds
- Network interface, IPv4 address, and default gateway reporting
- Cached APT update counts refreshed by a systemd timer
- Failed systemd unit and reboot-required warnings
- Repeatable upgrades that preserve the existing configuration
- Uninstaller that restores the prior MOTD, fragments, and MOTD-related timer state

## Supported systems

The installer supports booted, systemd-based installations of:

- Debian
- Ubuntu
- Raspberry Pi OS
- Other Debian-derived distributions that identify Debian in `ID_LIKE`

It is intended to run directly on a host or VM. Installation from a chroot or a build container is not supported because the installer enables a systemd timer.

Required packages are normally present on a standard Debian installation:

- `systemd`
- `debianutils` (`run-parts`)
- `iproute2` (`ip`)
- `util-linux` (`flock`)

The installer checks these requirements and reports the package installation command if anything is missing.

Repository update checks additionally require either `curl` or `wget`.

## Quick start with Git

Install Git if necessary, clone the repository, preview the MOTD, and then install it:

```bash
sudo apt-get update
sudo apt-get install -y git

git clone https://github.com/roach0816/EnhancedMOTD.git
cd EnhancedMOTD

bash homelab-motd-installer.sh --preview
sudo bash homelab-motd-installer.sh --install
```

The preview is read-only. Installation requires root because it writes system configuration under `/etc`, `/usr/local`, and `/var`.

Log out and reconnect over SSH to see the MOTD during login. You can also preview the installed version at any time:

```bash
motdctl preview
```

## Install without Git

Download the installer, inspect it, and run the local copy:

```bash
curl -fL https://raw.githubusercontent.com/roach0816/EnhancedMOTD/main/homelab-motd-installer.sh \
  -o homelab-motd-installer.sh

less homelab-motd-installer.sh
bash homelab-motd-installer.sh --self-test
sudo bash homelab-motd-installer.sh --install
```

For a reproducible installation, replace `main` in the download URL with a release tag or commit SHA. Avoid piping a remote script directly into a root shell; downloading it first gives you an opportunity to review exactly what will run.

## Commands

After installation, `motdctl` is available system-wide:

| Command | Purpose |
| --- | --- |
| `motdctl preview` | Render the MOTD immediately |
| `sudo motdctl refresh` | Refresh APT metadata and cached update counts |
| `motdctl check-update` | Check the repository for a newer version |
| `sudo motdctl update` | Review and install a newer version |
| `motdctl status` | Show the installed version, timer, and cache status |
| `sudo motdctl configure` | Edit the configuration and render a preview |
| `motdctl version` | Show the installed version and project URL |
| `sudo motdctl uninstall` | Remove EnhancedMOTD and restore the previous MOTD setup |

The installer itself also supports:

```text
--install      Install or upgrade (the default action)
--preview      Preview without changing the system
--uninstall    Uninstall using an existing installation
--self-test    Validate the embedded files and renderer
--version      Show the installer version
--help         Show command help
```

## Configuration

Settings are stored in `/etc/default/homelab-motd`. An existing configuration is preserved when the installer is run again.

```bash
sudo motdctl configure
```

The configuration includes:

| Setting | Default | Description |
| --- | ---: | --- |
| `COLOR` | `auto` | Color mode: `auto`, `always`, or `never` |
| `UNICODE` | `auto` | Unicode mode: `auto`, `always`, or `never` |
| `DISPLAY_WIDTH` | `78` | Maximum output width, from 60 to 110 columns |
| `DISK_WARNING_PERCENT` | `80` | Root disk warning threshold |
| `DISK_CRITICAL_PERCENT` | `90` | Root disk critical threshold |
| `MEMORY_WARNING_PERCENT` | `85` | Memory warning threshold |
| `MEMORY_CRITICAL_PERCENT` | `95` | Memory critical threshold |
| `TEMPERATURE_WARNING_C` | `75` | Temperature warning threshold in Celsius |
| `TEMPERATURE_CRITICAL_C` | `85` | Temperature critical threshold in Celsius |
| `CACHE_STALE_HOURS` | `12` | Age at which package data is considered stale |
| `SECURITY_UPDATES_ARE_WARNING` | `1` | Warn when security updates are available |
| `REBOOT_REQUIRED_IS_WARNING` | `1` | Warn when a reboot is required |
| `SHOW_DOWN_INTERFACES` | `1` | Include relevant interfaces whose link is down |
| `SHOW_VIRTUAL_INTERFACES` | `0` | Include common virtual network interfaces |
| `SHOW_PROCESS_COUNT` | `1` | Display the current process count |
| `CHECK_FOR_UPDATES` | `1` | Check GitHub daily and cache the result |
| `AUTO_UPDATE` | `0` | Automatically install a newer version as root |

Configuration values are sanitized at render time. A value outside its supported range falls back to the default.

## What installation changes

The installer creates or manages the following paths:

| Path | Purpose |
| --- | --- |
| `/usr/local/libexec/homelab-motd` | MOTD renderer and control implementation |
| `/usr/local/sbin/motdctl` | Symlink to the renderer/control command |
| `/etc/default/homelab-motd` | Administrator configuration |
| `/etc/update-motd.d/00-homelab-motd` | Dynamic MOTD entry point |
| `/etc/systemd/system/homelab-motd-refresh.service` | APT cache refresh service |
| `/etc/systemd/system/homelab-motd-refresh.timer` | Six-hour refresh schedule with randomized delay |
| `/etc/systemd/system/homelab-motd-update.service` | Repository update checker/installer |
| `/etc/systemd/system/homelab-motd-update.timer` | Daily update-check schedule with randomized delay |
| `/var/cache/homelab-motd` | Cached package update information |
| `/var/lib/homelab-motd` | Version and restoration state |

During the first installation, the current `/etc/motd` is saved and replaced with an empty static MOTD so that the dashboard is not followed by duplicate text. Every other executable fragment in `/etc/update-motd.d` is disabled; file modes and symlink targets are recorded, including locally generated integrations such as Ubuntu's Landscape system information. On Ubuntu, the now-unused `motd-news.timer` is also disabled and its previous state is recorded. Uninstall restores this saved state.

The initial installation runs `apt-get update` through the refresh service. The systemd timer repeats the refresh at approximately 00:00, 06:00, 12:00, and 18:00, with up to 15 minutes of randomized delay.

## Upgrade

EnhancedMOTD checks the repository once per day without delaying SSH login. The result is stored locally; when a newer version is available, the maintenance section tells the user to run:

```bash
sudo motdctl update
```

The command downloads `VERSION` and the installer over HTTPS, verifies that both versions match, validates the installer with `bash -n`, asks for confirmation, and then performs the same in-place installation used for normal upgrades. Existing configuration and restoration state are preserved.

To check without installing:

```bash
motdctl check-update
```

### Automatic updates

Automatic installation is deliberately disabled by default. To opt in, edit the configuration:

```bash
sudo motdctl configure
```

Set:

```bash
CHECK_FOR_UPDATES=1
AUTO_UPDATE=1
```

The next daily timer run will install a newer version without prompting. To run the scheduled workflow immediately:

```bash
sudo systemctl start homelab-motd-update.service
```

To prevent all repository checks, set both values to `0`. The timer remains installed but exits without network access.

Automatic updates execute repository code as root. The version and syntax checks protect against incomplete or inconsistent publishing, but they are not a cryptographic signature. Leave `AUTO_UPDATE=0` if you prefer to review each change before installation.

### Manual Git upgrade

If you installed from a Git clone:

```bash
cd EnhancedMOTD
git pull --ff-only
sudo bash homelab-motd-installer.sh --install
```

Running `--install` again replaces the managed runtime and systemd units but preserves `/etc/default/homelab-motd`.

If you downloaded the script directly, download a fresh copy and run the same `--install` command.

### Publishing a new version

The updater follows the repository's `main` branch. Before publishing an update:

1. Change `INSTALLER_VERSION` and the embedded `MOTD_VERSION` in `homelab-motd-installer.sh`.
2. Put the same semantic version in `VERSION`.
3. Run `bash homelab-motd-installer.sh --self-test`.
4. Commit and push the installer, README, and `VERSION` together.

Clients will not advertise a code change until `VERSION` is increased. The updater refuses installation if `VERSION` and the downloaded installer's version do not match.

## Uninstall

The preferred uninstall command uses the installed control utility, so the repository or installer file is not required:

```bash
sudo motdctl uninstall
```

You can also uninstall with a downloaded copy of the installer:

```bash
sudo bash homelab-motd-installer.sh --uninstall
```

Uninstall removes EnhancedMOTD's runtime, timers, services, configuration, and caches. It restores the original `/etc/motd`, fragment permissions, and any recognized legacy MOTD timer state saved during installation. If `/etc/motd` was changed after installation, that content is preserved in a timestamped backup before the original is restored.

## Troubleshooting

Check the generated output and timer state:

```bash
motdctl preview
motdctl status
systemctl status homelab-motd-refresh.timer
systemctl status homelab-motd-refresh.service
```

If the MOTD previews correctly but does not appear during SSH login, confirm that SSH uses PAM and that the host's PAM configuration invokes `pam_motd`/`/etc/update-motd.d`. Debian-family systems normally configure this by default.

If a preview has color but an SSH login does not, Unicode rows do not align at the right edge, Ubuntu's standard system-information block appears below the dashboard, or `run-parts` rejects `50-landscape-sysinfo`, upgrade to version 1.0.4 or newer and rerun the installer. Earlier versions could misinterpret PAM's cleaned login environment or mishandle locally generated Ubuntu fragments. As an administrator-controlled fallback for color, you can also set `COLOR="always"` in `/etc/default/homelab-motd`; explicit `never` settings continue to disable color and Unicode.

To verify that the fragment is selected by `run-parts`:

```bash
run-parts --test /etc/update-motd.d
```

The output should include `/etc/update-motd.d/00-homelab-motd`.

## Contributing

Issues and pull requests are welcome. Before submitting a change, run:

```bash
bash -n homelab-motd-installer.sh
bash homelab-motd-installer.sh --self-test
```

Installation and uninstall changes should also be tested on a disposable Debian-family VM because they modify login and systemd configuration.

## License

EnhancedMOTD is available under the [MIT License](LICENSE).
