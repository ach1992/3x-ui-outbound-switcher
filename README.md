# 3x-ui-outbound-switcher

**Version:** `v1.0.0`

Switch between outbound by your priority on 3X-UI.

This project runs on the **same server where 3x-ui is installed** and automatically switches the active outbound in Xray routing based on outbound health and your tag priority.

Priority is derived from outbound tag names such as:

- `A-Main-Out`
- `B-Backup-Out`
- `C-350-Star`
- `D-350-shayan-WS`
- `E-Test-Out`

The switcher reads outbounds directly from the current 3x-ui `config.json` fetched via the panel API. It only modifies the **last routing rule that contains both `network` and `outboundTag`**, validates the config with Xray, writes it to disk, and restarts Xray through the 3x-ui API with a fallback to `systemctl restart x-ui`.

## Features

- Priority by tag prefix: `A-`, `B-`, `C-`, ...
- Reads outbounds from 3x-ui config automatically
- Health checks each prioritized outbound through a temporary local Xray probe
- Automatic failover after consecutive failures
- Automatic recovery back to higher-priority outbound after consecutive successes
- 3x-ui API login, config download, and restart support
- Fallback restart with `systemctl restart x-ui`
- Online install and offline install support
- Interactive CLI menu
- Logs, state tracking, validation, timer control, uninstall support
- Designed for Debian and Ubuntu

## Supported systems

- Ubuntu 22
- Ubuntu 24
- Ubuntu 25
- Debian 11
- Debian 12
- Debian 13

## Naming rule for outbound tags

Only outbounds with tags matching this pattern are considered prioritized:

```text
^[A-Z]-
```

Examples:

```text
A-Main-Out
B-Backup-Out
C-350-Star
D-350-shayan-WS
E-Test-Out
```

If a tag does not start with `A-` to `Z-`, the switcher ignores it.

## Online install

Run this one-liner on the same server where 3x-ui is installed:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ach1992/3x-ui-outbound-switcher/main/install.sh)
```

What happens next:

1. The installer downloads the required files.
2. It installs the command as:
   ```bash
   /usr/local/bin/3x-ui-outbound-switcher
   ```
3. It **automatically launches** the interactive CLI menu.
4. The CLI asks for your 3x-ui panel URL, username, password, config path, and Xray binary path.
5. It validates everything before saving.

## Offline install

Use this when the server has no internet access.

### 1) Prepare files on another machine

Download or clone this repository and make sure these files exist:

- `install.sh`
- `uninstall.sh`
- `xui-switcher.sh`
- `README.md`

### 2) Upload them to the server

Copy the repository folder to this exact path:

```bash
/root/3x-ui-outbound-switcher
```

Example expected structure:

```text
/root/3x-ui-outbound-switcher/install.sh
/root/3x-ui-outbound-switcher/uninstall.sh
/root/3x-ui-outbound-switcher/xui-switcher.sh
/root/3x-ui-outbound-switcher/README.md
```

### 3) Run the installer

You can run either:

```bash
bash /root/3x-ui-outbound-switcher/install.sh
```

or if you already copied it somewhere else and an offline package exists in `/root/3x-ui-outbound-switcher`, the installer will detect it and ask whether you want to install **offline** or **online**.

If the offline package is not found, the installer automatically proceeds with online installation and does not ask.

## Dependency handling

The installer does **not** run `apt update` automatically.

It only tries to install missing required packages when needed, such as:

- `curl`
- `jq`
- `util-linux` (for `flock`, if missing)

If a dependency already exists, it is not installed again.

## Default paths commonly used with 3x-ui

Typical values on many 3x-ui systems:

```text
config.json: /usr/local/x-ui/bin/config.json
xray binary: /usr/local/x-ui/bin/xray-linux-amd64
```

Your panel URL may look like this:

```text
http://SERVER_IP:PORT/PANEL_BASE_PATH
```

Example:

```text
http://193.242.125.37:2090/ach
```

## CLI command

After installation, the main command is:

```bash
3x-ui-outbound-switcher
```

You can run it anytime to open the interactive menu.

### CLI menu actions

- Install / Reconfigure
- Show current config
- Validate current Xray config
- Start one check now
- Start service once
- Stop auto-run timer
- Restart auto-run timer
- Show status
- Show logs
- Enable auto-run timer
- Disable auto-run timer
- Uninstall
- Exit

### Non-interactive commands

```bash
3x-ui-outbound-switcher install
3x-ui-outbound-switcher show-config
3x-ui-outbound-switcher validate
3x-ui-outbound-switcher run-now
3x-ui-outbound-switcher start
3x-ui-outbound-switcher stop
3x-ui-outbound-switcher restart
3x-ui-outbound-switcher status
3x-ui-outbound-switcher logs
3x-ui-outbound-switcher enable
3x-ui-outbound-switcher disable
3x-ui-outbound-switcher uninstall
3x-ui-outbound-switcher version
```

## How switching works

- The switcher downloads the current 3x-ui config via API.
- It discovers prioritized outbounds from tags like `A-...`, `B-...`, `C-...`.
- It health-checks each one using a temporary local Xray probe.
- If the current outbound fails `FAIL_THRESHOLD` consecutive times, it switches to the first healthy higher-priority choice available by order.
- If a higher-priority outbound becomes healthy again for `RECOVER_THRESHOLD` consecutive checks, it switches back.
- A minimum time gap between switches is enforced.

Default values:

- `FAIL_THRESHOLD=3`
- `RECOVER_THRESHOLD=2`
- `MIN_SWITCH_GAP=60`
- `PROBE_TIMEOUT=8`
- `PROBE_URL=http://connectivitycheck.gstatic.com/generate_204`

## Systemd service and timer

The installer creates:

- `/etc/systemd/system/3x-ui-outbound-switcher.service`
- `/etc/systemd/system/3x-ui-outbound-switcher.timer`

The timer runs every **20 seconds**.

Useful commands:

```bash
systemctl status 3x-ui-outbound-switcher.timer --no-pager
systemctl status 3x-ui-outbound-switcher.service --no-pager
journalctl -u 3x-ui-outbound-switcher.service -f
```

## Logs and state

Main paths:

```text
Env file   : /etc/3x-ui-outbound-switcher/switcher.env
State file : /var/lib/3x-ui-outbound-switcher/state.json
Main log   : /var/log/3x-ui-outbound-switcher/switcher.log
Action log : /var/log/3x-ui-outbound-switcher/actions.log
```

Useful commands:

```bash
tail -f /var/log/3x-ui-outbound-switcher/switcher.log
tail -f /var/log/3x-ui-outbound-switcher/actions.log
cat /var/lib/3x-ui-outbound-switcher/state.json | jq
```

## Uninstall

Using the CLI:

```bash
3x-ui-outbound-switcher uninstall
```

Or directly:

```bash
bash /opt/3x-ui-outbound-switcher/uninstall.sh
```

The uninstaller removes:

- systemd service and timer
- installed scripts
- symlink command
- env file
- state
- logs
- lock file

It also asks whether you want to remove config backup files.

## Security notes

- The panel password is stored in the local env file so the timer can run unattended.
- The env file is saved with `chmod 600`.
- After first setup, it is a good idea to use a dedicated 3x-ui admin account with only the permissions you need.
- Keep repository access and server shell access restricted.

## MIT License

This project is intended to be released under the MIT License.

## Disclaimer

Use at your own risk. Always test on your own server before relying on automatic failover in production.
