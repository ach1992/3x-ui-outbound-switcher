# 3x-ui-outbound-switcher

Version: `v1.0.2`

Switch between outbounds by priority on **3X-UI**.

Priority is derived from outbound tags that begin with uppercase letters:

- `A-Primary`
- `B-Backup`
- `C-Node-1`
- `D-Node-2`

The switcher always prefers the highest healthy outbound. If the current outbound fails repeatedly, it moves to the next healthy one. When a higher-priority outbound recovers, it switches back.

## Highlights

- Works on the **same server** where 3x-ui is installed
- Supports **Ubuntu 22/24/25** and **Debian 11/12/13**
- Online and offline installation
- Interactive CLI menu
- Automatic timer via systemd
- Backup before every routing switch
- Xray config validation before applying changes
- Restart via **3x-ui API** with fallback to `systemctl restart x-ui`
- **Default probe mode is TCP**, so it does not depend on external URLs

## How priority works

Only outbound tags matching `^[A-Z]-` are included in the priority list.

Example:

- `A-Primary`
- `B-Backup`
- `C-Node-One`
- `D-Node-Two`

The switcher sorts them alphabetically and uses that as priority order.

## Important note about health checks

By default, `v1.0.2` uses **TCP probe mode**.

That means it checks whether the server can open a TCP connection to each outbound's configured `address:port`. This avoids false failures on servers that cannot directly access public test URLs.

There is also an optional **HTTP probe mode** for advanced users, but TCP mode is the recommended default.

## Install online

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ach1992/3x-ui-outbound-switcher/main/install.sh)
```

After installation, the interactive CLI starts automatically.

## Install offline

If the server has no internet access:

1. Download the repository files on another machine.
2. Copy these files to the server inside:

```bash
/root/3x-ui-outbound-switcher
```

Required files:

- `install.sh`
- `uninstall.sh`
- `xui-switcher.sh`
- `README.md`

3. Run:

```bash
cd /root/3x-ui-outbound-switcher
bash install.sh
```

If the offline folder is detected, the installer asks whether you want to install offline or online.

## CLI command

After installation:

```bash
3x-ui-outbound-switcher
```

You can also use subcommands:

```bash
3x-ui-outbound-switcher install
3x-ui-outbound-switcher show-config
3x-ui-outbound-switcher validate
3x-ui-outbound-switcher run-now
3x-ui-outbound-switcher status
3x-ui-outbound-switcher logs
3x-ui-outbound-switcher uninstall
```

## Menu features

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

## What the installer asks for

- 3x-ui panel base URL
- 3x-ui username
- 3x-ui password
- `config.json` path
- Xray binary path
- fail threshold
- recover threshold
- minimum switch gap
- probe timeout
- probe mode (`tcp` or `http`)

## Default paths commonly used by 3x-ui

Typical examples:

- Config: `/usr/local/x-ui/bin/config.json`
- Xray binary: `/usr/local/x-ui/bin/xray-linux-amd64`

## Logs and state

- Log file: `/var/log/3x-ui-outbound-switcher/switcher.log`
- Action log: `/var/log/3x-ui-outbound-switcher/actions.log`
- State file: `/var/lib/3x-ui-outbound-switcher/state.json`

## Uninstall

From the menu, choose `Uninstall`, or run:

```bash
bash /opt/3x-ui-outbound-switcher/uninstall.sh
```

## Notes

- The switcher only changes the **last routing rule** that has both `network` and `outboundTag`.
- It does **not** rename panel objects or rewrite unrelated parts of the config.
- It validates the modified Xray config before applying it.
- If restart via 3x-ui API fails, it tries `systemctl restart x-ui`.

## License

MIT
