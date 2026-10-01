# Ice Servers

A small macOS app for watching and controlling the Linux servers on your home network.

- Live CPU, memory, network and disk for each server
- Power on (Wake-on-LAN), shut down and restart
- Check for and install `apt` updates, with progress
- Desktop widgets in four sizes, three styles and three looks
- Add and remove servers at any time

Everything goes over plain SSH. Nothing is installed on the servers.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`), full Xcode isn't needed
- Servers running Linux with systemd; update features need `apt` (Debian, Ubuntu)
- SSH key login to each server (`ssh user@host` works without a password prompt)

## Build and run

```sh
./build.sh
open "build/Ice Servers.app"
```

Copy `build/Ice Servers.app` to `/Applications` if you want to keep it.

## Adding servers

On first launch the app imports shell aliases such as
`alias homelab='ssh me@192.168.1.20'` from `~/.zshrc`, `~/.bashrc` and friends.
After that, use **Add Server** in the sidebar (or ⌘N). The SSH field takes whatever you'd
pass to `ssh`: `user@host`, a `Host` from `~/.ssh/config`, or options like `-p 2222 user@host`.

Right-click a server in the sidebar to remove it.

## sudo

Shutting down, restarting and updating need sudo. The first time, the app asks for the
server's sudo password and keeps it in your macOS Keychain. To avoid storing a password,
allow just these commands without one (run `sudo visudo -f /etc/sudoers.d/ice-servers` on the server):

```
youruser ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff, /usr/bin/systemctl reboot, /usr/bin/apt-get
```

## Power on

Turning a server on uses Wake-on-LAN. The app learns each server's MAC address the first
time it sees it online. Wake-on-LAN has to be enabled in the server's BIOS/UEFI and on its
network card (`sudo ethtool -s <interface> wol g`).

## Widgets

**File › Add Widget** (⇧⌘N) puts a widget on the desktop and opens its editor. Drag a widget
to move it; right-click it to edit or remove it. Widgets stay on the desktop while the app runs.

## Where things live

- Settings: `~/Library/Application Support/Ice Servers/config.json`
- sudo passwords: Keychain, service "Ice Servers sudo"

## License

MIT
