# Ice Servers

A small macOS app for watching and controlling the Linux servers on your home network.

- Live CPU, memory, network, disk and temperature for each server
- Power on (Wake-on-LAN), shut down and restart
- Check for and install `apt` updates, with progress
- Real macOS widgets (WidgetKit) in four sizes, three styles and three looks; they keep working when the app is closed
- Add, edit and remove servers at any time
- A menu bar item with status dots and quick actions, and notifications (offline, high CPU or
  temperature, disk almost full, updates)
- Light, dark or automatic theme, glass strength, tint and accent color

Everything goes over plain SSH. Nothing is installed on the servers.

## Requirements

- macOS 14 or later
- Xcode, installed from the App Store (it never needs to be opened): the widget's Edit Widget options need its App Intents tool
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
After that, use **Add Server** in the sidebar (⌘N). It walks through the server's address,
how to sign in, how to handle sudo, and then tests everything for real: reaching the host,
the host key (you confirm its fingerprint the first time), signing in, sudo and reading stats.

Signing in with a password uses it once to add this Mac's SSH key (`~/.ssh/id_ed25519`, created
if needed) to the server; after that everything, including the widgets, uses the key.

**Settings › Servers** (the gear in the sidebar, or ⌘,; Settings opens in the main window, ‹ Servers or Esc goes back) edits a server's name, address, port and icon
color, chooses whether it appears in widgets and the menu bar, and removes it (with Undo).

## sudo

Shutting down, restarting and updating need sudo. For each server you choose:

- **Ask once, remember securely**: kept in your macOS Keychain, optionally behind Touch ID.
- **Remember, never ask**: kept outside the Keychain, so macOS never asks: encrypted (AES-GCM) with a
  key derived from this Mac's hardware UUID, in `~/Library/Application Support/Ice Servers/sudo-passwords`
  (readable only by you). A copy of that file is useless on another Mac, but any app running as you on
  this Mac could decrypt it, and anyone using your unlocked Mac can restart, shut down or update the server.
- **Ask every time**: never saved.
- **Passwordless sudo**: for servers that allow these commands without a password. Add Server
  checks the server's rules for each command and shows which ones still ask for a password.

**Settings › Sudo & Passwords** (⌘,) shows what's saved, and can save, forget or require Touch ID.

While a sudo command runs, the other power, restart and update controls are locked and a banner
shows how long it has been running. Shutdown and restart are scheduled 3 seconds out, so SSH closes
cleanly before the server goes down. Each kind of command has a time limit (Settings › Sudo &
Passwords, Command time limits): past it, the app stops waiting, marks the server Not responding,
unlocks the controls and offers Retry. Nothing is stopped on the server, and it goes back to Online
as soon as it answers.
For passwordless sudo, allow just these commands (run `sudo visudo -f /etc/sudoers.d/ice-servers` on the server):

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

- **Settings › Widgets** (or **Custom Widgets** in the sidebar) is where you design widgets:
  name, size, servers (or all of them), stats in the order you pick, bars/rings/graphs/numbers,
  glass/tinted/clear, and power & restart buttons on Large and Extra Large. Start from a template
  or from scratch; each size shows as many servers and stats as fit, then "+N more".
- The widget gallery has one Ice Servers widget per size. **Right-click a widget › Edit Widget**
  picks which design it shows, from the designs made for its size. A new widget asks you to choose
  one first. Saving a design updates every widget that uses it; a widget whose design is deleted
  asks for another. There's no built-in design: until you make one of a size, its widget says so.
- While the app runs, widgets use its live stats. Otherwise they fetch fresh numbers over SSH on their own. macOS decides how often (usually every few
  minutes); while the app is open it also refreshes them whenever something changes.
- Clicking a widget opens the app. Its restart, update and power buttons work in the background:
  the app does the work (launching hidden if it isn't running) and only shows the same
  confirmation it would in its window for restart and power off.

The widget runs in the macOS sandbox. It can read `~/.ssh` and the app's settings, nothing else.
The app passes it each server's resolved SSH settings, so `Include`s in `~/.ssh/config` don't need to be readable.
SSH keys used by the widget can't have a passphrase.

## Settings

- **General**: open at login, menu bar item (while it's on, closing the window keeps the app running
  for the menu bar and notifications), refresh rate, °C/°F, MB/s or Mbit/s, confirm before power off.
- **Appearance**: glass effect, background blur (0 turns the glass off), theme, tint, accent color,
  reduce transparency.
- **Notifications**: server offline, CPU above a limit for 5 minutes, temperature, disk space and
  daily update reminders. They come from the app, so they need it running (in the menu bar is enough).
- **Passwords**: saved sudo passwords and Touch ID.

## Temperatures

Read from the kernel's hwmon sensors, no root needed. SATA drive temperatures need the
`drivetemp` module (`echo drivetemp | sudo tee /etc/modules-load.d/drivetemp.conf`, then reboot);
NVMe drives work out of the box.

## Where things live

- Settings: `~/Library/Application Support/Ice Servers/config.json`
- sudo passwords: Keychain, service "Ice Servers sudo"; "never ask" ones in `sudo-passwords` (see above)

## License

MIT
