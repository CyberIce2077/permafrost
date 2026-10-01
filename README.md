# Ice Servers

A small macOS app for watching and controlling the Linux servers on your home network.

- Live CPU, memory, network and disk for each server
- Power on (Wake-on-LAN), shut down and restart
- Check for and install `apt` updates, with progress
- Real macOS widgets (WidgetKit) in four sizes, three styles and three looks; they keep working when the app is closed
- Add and remove servers at any time

Everything goes over plain SSH. Nothing is installed on the servers.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`), full Xcode isn't needed
- Servers running Linux with systemd; update features need `apt` (Debian, Ubuntu)
- SSH key login to each server (`ssh user@host` works without a password prompt)

## Build and install

```sh
./build.sh --install
```

This builds the app and its widget extension, copies them to `/Applications` and opens the app.
`./build.sh` alone only builds `build/Ice Servers.app`.

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

Add them like any other widget: right-click the desktop, choose **Edit Widgets…**, and find
**Ice Servers**. They work on the desktop and in Notification Center, with or without the app running.

- **Ice Servers › Widget Settings…** (⌘,) chooses what each size shows: which server, which
  stats, bars/rings/graphs, and glass/tinted/clear.
- Widgets fetch fresh numbers over SSH on their own. macOS decides how often (usually every few
  minutes); while the app is open it also refreshes them whenever something changes.
- Clicking a widget opens the app. Its power, restart and update buttons open the app, which asks
  before doing anything to the server.

The widget runs in the macOS sandbox. It can read `~/.ssh` and the app's settings, nothing else.
The app passes it each server's resolved SSH settings, so `Include`s in `~/.ssh/config` don't need to be readable.
SSH keys used by the widget can't have a passphrase.

## Where things live

- Settings: `~/Library/Application Support/Ice Servers/config.json`
- sudo passwords: Keychain, service "Ice Servers sudo"

## License

MIT
