# VoidL ToolKit

A single-file, post-install configurator for **Void Linux**.

It is the thing you run **after** `void-installer` has finished and the machine
has rebooted into the fresh system. It asks everything a first boot needs —
desktop, user, hostname, Wi-Fi, swap, SSH/VNC, keyboard — then applies it all in
one go, installs `git`, and pulls the companion wireless settings tool from this
repository.

Two files, no dependencies beyond a POSIX shell and Void's base system:

| File | What it is |
| --- | --- |
| `ToolKit.sh` | The main wizard. Drop it on the boot partition, run it as root. |
| `wireless-settings.sh` | A separate Wi-Fi + Bluetooth text GUI, installed as `void-wireless`. |

Neither script needs `dialog`, `whiptail`, `python`, `ncurses` or any library.
They draw their own text interface with escape sequences and read keys with
`dd`, so they work on a bare serial console, in `tmux`, over SSH, or on a
Raspberry Pi with no display attached.

---

## Contents

1. [Requirements](#requirements)
2. [Quick start](#quick-start)
3. [Putting the script on the boot partition](#putting-the-script-on-the-boot-partition)
4. [The wizard, screen by screen](#the-wizard-screen-by-screen)
5. [The wireless settings tool](#the-wireless-settings-tool)
6. [Answers files (non-interactive installs)](#answers-files-non-interactive-installs)
7. [Command line reference](#command-line-reference)
8. [Supported machines and architectures](#supported-machines-and-architectures)
9. [Remote access: SSH, VNC and USB gadget mode](#remote-access-ssh-vnc-and-usb-gadget-mode)
10. [Swap](#swap)
11. [What it changes on disk](#what-it-changes-on-disk)
12. [Testing this yourself (QEMU)](#testing-this-yourself-qemu)
13. [Troubleshooting](#troubleshooting)
14. [Uninstalling](#uninstalling)

---

## Requirements

* **A working, installed Void Linux system.** Not the live installer image — the
  tool refuses to run there. It checks that the root filesystem looks like a
  real installation and that `xbps-install` is present; if not, it stops and
  tells you to run it again after installing.
* Root privileges (`sudo` or a root shell).
* `sh` — any POSIX shell. `/bin/sh` is `dash` on Void and that is what the
  scripts are written and tested against. `bash` also works.
* Internet access for package installation and for fetching the wireless tool.

```console
$ sudo sh /boot/VoidL-ToolKit.sh
```

---

## Quick start

```console
# 1. boot the freshly installed system and log in
# 2. put the script somewhere and run it
sudo sh ToolKit.sh

# 3. answer the questions, review, confirm
# 4. reboot
sudo reboot
```

That is the whole flow. If you would rather script it, skip to
[Answers files](#answers-files-non-interactive-installs).

---

## Putting the script on the boot partition

The script is deliberately a single self-contained file so it can travel on the
boot partition — the one filesystem that is easy to reach from another machine,
a live USB, or a serial console.

**If your machine is already running Void**, the simplest route is:

```console
sudo xbps-install -Sy git
git clone https://github.com/Harshit567834/VoidL-ToolKit.git
sudo sh VoidL-ToolKit/ToolKit.sh
```

**If the machine has no network yet** (very common on a fresh install with
Wi-Fi only), copy the file in from another computer:

```console
# on the other computer
scp ToolKit.sh root@<void-machine>:/boot/

# or put it on the ESP / boot partition with a live USB:
#   mount /dev/sda1 /mnt      # your boot partition
#   cp ToolKit.sh /mnt/
```

Then on the Void machine:

```console
sudo sh /boot/ToolKit.sh
```

**Raspberry Pi and other ARM boards:** the boot partition is a FAT partition
that you can mount on any desktop OS. Copy `ToolKit.sh` onto it, put the card
back, boot, log in on the serial console or via SSH, and run:

```console
sudo sh /boot/ToolKit.sh
```

The script does not care where it lives — `/boot`, `/root`, `/tmp`, a USB stick,
or a path on a network share all work.

---

## The wizard, screen by screen

The interface is a full-screen text menu. Keys:

| Key | Action |
| --- | --- |
| `↑` / `↓` (or `k` / `j`) | move the highlight |
| `Enter` | choose the highlighted entry |
| `1`…`9`, `0` | jump straight to that entry number |
| `g` / `G` | jump to the first / last entry |
| `Esc` | go back one step (or cancel the current menu) |
| `q` | quit from most screens |

Type a number and press `Enter`, or just press the number followed by `Enter` —
both work. Screens with a text field show the current value in brackets; press
`Enter` to keep it.

### 1. Welcome

Shows what was detected: machine model, architecture (and whether it is glibc or
musl), memory, and root filesystem type. Nothing to configure here.

### 2. Device

> *What kind of machine is this?*

| Option | What it selects |
| --- | --- |
| Auto-detect | Uses `uname -m`, the CPU vendor and the device tree to pick for you |
| PC / server (x86_64) | x86_64 packages, `linux` kernel, GRUB |
| PC / server (i686) | 32-bit x86 packages |
| ARM64 board / Raspberry Pi 3–5 | `aarch64`, `rpi-kernel` |
| ARMv7 board | `armv7hl` |
| Raspberry Pi Zero / Zero W / Pi 1 | `armv6hl` — the oldest boards Void supports |
| RISC-V 64 | `riscv64` |
| PowerPC 64 | `ppc64` / `ppc64le` |
| Other / manual | Nothing assumed; you set everything else by hand |

The choice drives the package set, kernel, firmware and microcode later on.

### 3. Hostname, locale, timezone, keymap

| Screen | Notes |
| --- | --- |
| Hostname | Default `void`. Written to `/etc/hostname` **and** `HOSTNAME=` in `/etc/rc.conf`. |
| Locale | e.g. `en_US.UTF-8`, `en_GB.UTF-8`, `de_DE.UTF-8`, `C.UTF-8`. On musl images the locale is forced to `C.UTF-8` because musl has no locale support. |
| Timezone | A full zoneinfo path such as `Asia/Kolkata`, `Europe/London`, `America/New_York`. |
| Console keymap | e.g. `us`, `uk`, `de`, `fr`, `in`. Sets `KEYMAP=` in `/etc/rc.conf`. |
| X11 keyboard layout | Used for `00-keyboard.conf` in `/etc/X11/xorg.conf.d/` when a desktop is installed. |

### 4. User account

| Screen | Notes |
| --- | --- |
| Username | Created with `useradd -m`, shell `/bin/bash`. |
| Full name | The GECOS field. |
| Password | Typed twice, hidden. |
| Extra groups | Default `wheel audio video input plugdev bluetooth lp storage network`. Missing groups are created. |
| sudo | Default yes. Writes `/etc/sudoers.d/<user>` with `<user> ALL=(ALL:ALL) ALL`. |

The first user (UID 1000) is also the account the IP banner suggests for SSH.

### 5. Desktop environment

| Option | Packages |
| --- | --- |
| No desktop (console / server) | none |
| Xfce | `xfce4`, `xfce4-terminal`, `thunar`, `xfce4-power-manager` |
| LXQt | `lxqt` (a metapackage that pulls in Qt and Openbox) |
| MATE | `mate`, `mate-extra` |
| Cinnamon | `cinnamon` |
| GNOME | `gnome`, `gnome-tweaks`, `gnome-terminal` |
| KDE Plasma | `kde-plasma`, `kde-cli-tools`, `ark` |
| i3 | `i3`, `i3status`, `i3lock`, `dmenu`, `xterm` |
| Sway | `sway`, `swaylock`, `swayidle`, `foot`, `wofi` |
| Minimal X | `xorg-server`, `xinit`, `xterm` |

Every desktop also installs PipeWire (`pipewire`, `alsa-pipewire`,
`wireplumber`) plus the session plumbing a desktop needs to work properly:
`dbus`, `elogind` and `polkit`. The `dbus` and `elogind` services are enabled —
without them the desktop's shutdown, reboot, disk-mounting and screen-locking
entries do nothing.

### 6. Login screen (display manager) and autologin

| Option | Notes |
| --- | --- |
| LightDM | `lightdm` + `lightdm-gtk-greeter`. Recommended. |
| SDDM | Good match for Plasma. |
| GDM | For GNOME. |
| LXDM | Lightweight. |
| None | You start the session from the console with `startx`. |

You are then asked **whether to log in automatically**. Answering yes writes
`autologin-user`, `autologin-user-timeout=0` and `autologin-session` into
`/etc/lightdm/lightdm.conf` — or the matching file for the manager you picked
(`/etc/sddm.conf.d/autologin.conf`, `/etc/gdm/custom.conf`,
`/etc/lxdm/lxdm.conf`). If you chose **None**, autologin is applied to the
console `getty` on `tty1` instead, so you land in a shell without typing a
password. Answering no leaves the login screen as is.

### 7. Networking

> *How is this machine connected?*

* **Wired ethernet only (DHCP)** — enables `dhcpcd`.
* **Wi-Fi (wireless)** — see below.
* **Wired + Wi-Fi** — both.
* **No network configuration** — nothing is touched.

If you pick Wi-Fi you also choose the stack:

| Stack | Packages | Notes |
| --- | --- | --- |
| wpa_supplicant | `wpa_supplicant` | Default. Writes `/etc/wpa_supplicant/wpa_supplicant.conf` and enables the service. |
| iwd | `iwd` | Modern and light; good on ARMv6 boards. |
| NetworkManager | `NetworkManager`, `nm-tray`, `network-manager-applet` | Best on laptops that roam. |

Then:

* **Wireless interface** — defaults to the first wireless interface found.
* **Pick the network** — *scan for networks now* (shows signal strength for each
  SSID and lets you choose) or *enter the SSID manually*.
* **Wi-Fi password** — hidden, empty for open networks.
* **Hidden network?** — adds `scan_ssid=1` to the network block.

### 8. Bluetooth

*Enable Bluetooth?* installs `bluez` and `blueman`, enables the `bluetoothd`
runit service, and unblocks the adapter with `rfkill` if it is soft-blocked. You
can name a specific adapter or leave it on auto.

### 9. Swap

Two questions, in this order:

> *Use swap?* — No swap / Swap file (recommended) / zram (compressed RAM swap)

> *How much swap do you want?* — 1 GB / 2 GB / 4 GB / 8 GB / Same as RAM /
> Twice the RAM / Custom size (MB)

The size is asked for both a swap file and zram; only "No swap" skips it. The
default suggestion is 2 GB. Details in [Swap](#swap).

### 10. Remote access

> *How do you want to reach this machine?*

* **LAN / local network (show the IP address)** — SSH over the network.
* **USB gadget mode (Raspberry Pi only: ssh over USB)** — only offered when a
  Raspberry Pi is detected.
* **No remote access**.

Both of the first two show the machine's address on the console at boot. See
[Remote access](#remote-access-ssh-vnc-and-usb-gadget-mode).

### 11. SSH

*Enable SSH?* then:

| Question | Default |
| --- | --- |
| Port | `22` |
| Allow root login | no |
| Allow password authentication | yes |

`openssh` is installed and the `sshd` runit service enabled.

### 12. VNC

*Install a VNC server?* then:

| Question | Default |
| --- | --- |
| Mode | `virtual` (a second, virtual display) or `mirror` (share the physical screen) |
| Geometry | `1280x800` |
| Display number | `:1` |
| Password | optional |

Installs `tigervnc` and enables a `voidl-vnc` runit service that starts
`vncserver` as your user.

### 13. Firmware, microcode, kernel

| Screen | Notes |
| --- | --- |
| Firmware | `linux-firmware` (the metapackage that pulls in every vendor subset). On a Raspberry Pi, `rpi-firmware` instead. |
| Microcode | Auto-detect, Intel, AMD, or none. `intel-ucode` / `linux-firmware-amd`. |
| Kernel | `linux` or `linux-lts`; on a Raspberry Pi also `rpi-kernel`. |

### 14. Extra packages

*Install extra packages?* opens a single-choice list:

| Group | Packages |
| --- | --- |
| None | nothing |
| Browsers | `firefox` |
| Media | `mpv`, `vlc` |
| Office | `libreoffice` |
| Development tools | `git`, `base-devel` |
| All of the above | all of the above |

In an answers file `EXTRAS` also accepts any package name or space-separated
list of names, which is passed straight to `xbps-install`.

### 15. Review and apply

A summary of every choice, then *Apply this configuration now?*. Answering **No**
returns to the wizard; answering **Yes** applies everything and shows a progress
log. At the end:

```
All done.  Reboot to apply everything:
    reboot
```

---

## The wireless settings tool

`ToolKit.sh` installs `git`, then fetches `wireless-settings.sh` from this
repository and installs it as **`/usr/local/bin/void-wireless`**. It is a
separate program — the main wizard does not contain it — so you can update the
wireless tool later without touching the installer.

```console
void-wireless                 # interactive text menu
void-wireless --status        # interfaces, Wi-Fi and Bluetooth status
void-wireless --scan          # list nearby Wi-Fi networks
void-wireless --connect HOME  # connect to an open network
void-wireless --connect HOME s3cret
void-wireless --bt-scan       # list nearby Bluetooth devices
void-wireless --bt-pair AA:BB:CC:DD:EE:FF
void-wireless --services      # enable/disable the wireless services
```

The menu offers:

* **Wi-Fi — scan and connect** — scans, shows signal strength, asks for the
  password, and saves the network.
* **Wi-Fi — status and saved networks** — shows the current link and lets you
  forget saved networks.
* **Bluetooth — scan and pair** — scans, pairs, trusts and connects a device.
* **Bluetooth — status** — adapter state and paired devices.
* **Static IP address** — set an address, gateway and DNS for one interface.
* **Services** — enable or disable `wpa_supplicant`, `iwd`, `NetworkManager`,
  `dhcpcd` and `bluetoothd` under runit.
* **Refresh** / **Quit**.

It auto-detects which stack is installed and uses it: `iwctl` for iwd, `nmcli`
for NetworkManager, `wpa_cli` for wpa_supplicant, and `bluetoothctl` for BlueZ.

---

## Answers files (non-interactive installs)

Every question has a matching key. Generate a template, edit it, and reuse it on
as many machines as you like:

```console
sudo sh ToolKit.sh --dump-answers > my-setup.conf
$EDITOR my-setup.conf
sudo sh ToolKit.sh --answers my-setup.conf
```

With `--answers` the tool does not draw any menus at all, which makes it usable
over a pipe, in a provisioning script, or from a serial console with no cursor
keys. Lines starting with `#` are ignored.

### Keys

| Key | Default | Values |
| --- | --- | --- |
| `DEVICE` | `auto` | `x86_64` `i686` `aarch64` `armv7hl` `armv6hl` `riscv64` `ppc64` `other` |
| `HOSTNAME` | `void` | any valid hostname |
| `LOCALE` | `en_US.UTF-8` | e.g. `en_GB.UTF-8`, `de_DE.UTF-8`, `C.UTF-8` |
| `TIMEZONE` | `UTC` | zoneinfo path, e.g. `Asia/Kolkata` |
| `KEYMAP` | `us` | console keymap |
| `KEYBOARD_LAYOUT` | `us` | X11 layout |
| `XKB_MODEL` | `pc105` | X11 keyboard model |
| `XKB_OPTIONS` | — | e.g. `ctrl:nocaps` |
| `USERNAME` | `user` | |
| `USER_PASSWORD` | — | |
| `USER_FULLNAME` | — | |
| `USER_GROUPS` | `wheel audio video input plugdev bluetooth lp storage network` | space separated |
| `SUDO` | `yes` | `yes` / `no` |
| `DESKTOP` | `none` | `xfce` `lxqt` `mate` `cinnamon` `gnome` `kde-plasma` `i3` `sway` `minimal` |
| `DISPLAY_MANAGER` | `none` | `lightdm` `sddm` `gdm` `lxdm` |
| `AUTOLOGIN` | `no` | `yes` / `no` |
| `AUTOLOGIN_USER` | — | defaults to `USERNAME` |
| `NET_MODE` | `ethernet` | `ethernet` `wifi` `both` `none` |
| `NET_SERVICE` | `dhcpcd` | `dhcpcd` `NetworkManager` `connman` `static` |
| `WIFI_IFACE` | first wireless | e.g. `wlan0` |
| `WIFI_SSID` | — | |
| `WIFI_PASSWORD` | — | |
| `WIFI_HIDDEN` | `no` | `yes` / `no` |
| `WIFI_STACK` | `wpa_supplicant` | `wpa_supplicant` `iwd` `NetworkManager` |
| `STATIC_IP` | — | e.g. `192.168.1.50/24` |
| `STATIC_GATEWAY` | — | e.g. `192.168.1.1` |
| `STATIC_DNS` | — | e.g. `1.1.1.1 8.8.8.8` |
| `BLUETOOTH` | `no` | `yes` / `no` |
| `BLUETOOTH_ADAPTER` | — | e.g. `hci0` |
| `SWAP_MODE` | `none` | `none` `swapfile` `zram` |
| `SWAP_SIZE` | `2048` | megabytes |
| `SSH` | `no` | `yes` / `no` |
| `SSH_PORT` | `22` | |
| `SSH_ROOT_LOGIN` | `no` | `yes` / `no` |
| `SSH_PASSWORD_AUTH` | `yes` | `yes` / `no` |
| `VNC` | `no` | `yes` / `no` |
| `VNC_MODE` | `virtual` | `virtual` / `mirror` |
| `VNC_PASSWORD` | — | |
| `VNC_GEOMETRY` | `1280x800` | |
| `VNC_DISPLAY` | `1` | display number |
| `REMOTE_MODE` | `lan` | `lan` `gadget` `none` |
| `IP_BANNER` | `yes` | `yes` / `no` |
| `KERNEL` | `linux` | `linux` `linux-lts` `rpi-kernel` |
| `FIRMWARE` | `yes` | `yes` / `no` |
| `MICROCODE` | `auto` | `auto` `intel` `amd` `none` |
| `EXTRAS` | — | `firefox` `media` `libreoffice` `devel` `all` or package names |
| `GIT_URL` | this repository | |
| `GIT_BRANCH` | `main` | |
| `SKIP_FETCH` | `no` | `yes` skips installing `void-wireless` |

### Example

```sh
# ~/laptop.conf
DEVICE=x86_64
HOSTNAME=laptop
LOCALE=en_GB.UTF-8
TIMEZONE=Asia/Kolkata
KEYMAP=us
USERNAME=alice
USER_PASSWORD=correct-horse-battery-staple
DESKTOP=xfce
DISPLAY_MANAGER=lightdm
AUTOLOGIN=yes
NET_MODE=wifi
WIFI_SSID=HomeNetwork
WIFI_PASSWORD=hunter2
BLUETOOTH=yes
SWAP_MODE=swapfile
SWAP_SIZE=4096
SSH=yes
SSH_PORT=2222
VNC=yes
EXTRAS=browsers,media
```

```console
sudo sh ToolKit.sh --answers ~/laptop.conf
```

---

## Command line reference

```
ToolKit.sh [options]

  --answers FILE   read answers from FILE (KEY=VALUE per line), non-interactive
  --dump-answers   print the current answers as an answers file and exit
  --dry-run        show what would be done, change nothing
  --yes            accept all defaults (still interactive unless --answers)
  --force          skip the "installed system" check
  --no-install     never call xbps-install (for testing)
  --root DIR       operate on DIR instead of / (for testing)
  --no-color       disable colours
  --quiet          less output
  --log FILE       also write a log to FILE
  --version        print the version and exit
  --help           this help
```

| Flag | When to use it |
| --- | --- |
| `--dry-run` | Preview. Prints every action the tool would take and writes nothing. Combine with `--answers`. |
| `--no-install` | Exercise the whole configuration path without touching packages. Useful on a slow link. |
| `--root DIR` | Apply to a mounted root instead of `/`. For testing an image before flashing it. |
| `--log FILE` | Keep a machine-readable record of what was done. |
| `--force` | Skip the "is this really an installed system" guard. Only if you know better. |
| `--yes` | Take the default on every question, but still show the menus. |

`--dry-run` with `--root` is the safest way to see exactly what a given answers
file would do to a system image.

---

## Supported machines and architectures

Nothing in the scripts is architecture-specific except package and kernel
selection, which is derived from `uname -m` and the device tree.

| Architecture | Detected as | Kernel | Notes |
| --- | --- | --- | --- |
| x86_64 | `x86_64` | `linux` | Most common. Microcode auto-detected. |
| i686 | `i686` | `linux` | 32-bit x86. |
| aarch64 | `aarch64` | `linux`, or `rpi-kernel` on Pi | Pi 3, 4, 5, Zero 2 W, most ARM SBCs. |
| armv7hl | `armv7hl` | `linux` | 32-bit ARMv7 boards. |
| armv6hl | `armv6hl` | `rpi-kernel` | **Raspberry Pi Zero, Zero W, Pi 1** — the smallest boards Void supports. |
| riscv64 | `riscv64` | `linux` | |
| ppc64 / ppc64le | `ppc64` | `linux` | |
| anything else | `other` | `linux` | Manual configuration. |

Both glibc and musl images are supported. The flavour is detected from the
dynamic loader (`/lib/ld-linux-*.so.2` versus `/lib/ld-musl-*.so.1`) and only
affects the locale handling.

The scripts are plain POSIX `sh`. They contain no bashisms — no arrays, no
`read -s`, no `[[ ]]`, no `$'...'` — so they run under `dash`, `bash`, `busybox
ash` and `mksh` alike. That matters on musl and on minimal ARM images where
`/bin/sh` is not bash.

---

## Remote access: SSH, VNC and USB gadget mode

### LAN / local network

The usual case. `openssh` is installed, `sshd` is enabled under runit, and the
port and authentication options from the wizard are written into
`/etc/ssh/sshd_config`.

### USB gadget mode (Raspberry Pi only)

Offered **only** when a Raspberry Pi is detected. It turns the Pi's USB-C or
micro-USB port into a network device, so you can reach it from a laptop with one
cable and no network at all — the classic headless Zero W setup.

What it does:

1. Loads `libcomposite` and `dwc2`, mounts `configfs`, and builds a USB Ethernet
   gadget (CDC ECM by default, RNDIS if you set it) on `usb0`.
2. Gives the Pi `10.55.0.1/24` on `usb0` and runs `dnsmasq` on that interface,
   handing out addresses from `10.55.0.10` to `10.55.0.50`.
3. Installs a `voidl-gadget` runit service that sets the gadget up at boot, and
   enables `dnsmasq` and `sshd`.

Because the Pi runs a DHCP server on the cable, the laptop needs no manual setup
at all — plug in, wait a moment, and:

```console
ssh alice@10.55.0.1       # or whatever 10.55.0.x the laptop was handed
```

The settings live in `/etc/voidl/gadget.conf`:

```sh
VOIDL_GADGET_MODE=ecm      # ecm or rndis
VOIDL_GADGET_IP=10.55.0.1
VOIDL_GADGET_CIDR=24
```

On a Pi Zero W the gadget port is the same micro-USB port used for power, so you
need an OTG cable that also feeds power, or a Pi with a separate power input.
`dwc2` has to be in the kernel — on Void's `rpi-kernel` it is a module, so the
service simply loads it.

### Showing the IP address at boot

Whichever remote mode you pick, the machine prints its address on the console
during boot and puts it in `/etc/issue`, so it shows up on the login screen too:

```
  Void Linux - VoidL ToolKit
  -----------------------------------------
  eth0: 192.168.1.42
  ssh alice@192.168.1.42
  -----------------------------------------
```

This is done by `/usr/local/bin/void-ip-banner`, run from the `voidl-ip-banner`
runit service. The service waits up to 60 seconds for an address before
printing, so it does not show a stale "no address yet" line, and then refreshes
`/etc/issue` every 30 seconds so the login banner stays correct if DHCP renews.
Set `IP_BANNER=no` to skip it.

### VNC

`tigervnc` is installed and a `voidl-vnc` runit service starts `vncserver` as
your user:

* `virtual` — a second desktop on `:<display>`, reachable at
  `<machine-ip>:<5900 + display>`.
* `mirror` — mirrors the physical screen.

---

## Swap

The wizard asks **whether** you want swap and then **how much**, because both are
genuine choices:

| Mode | What happens |
| --- | --- |
| `none` | Nothing is configured. Existing swap is left alone. |
| `swapfile` | Creates `/swapfile` with `dd`, `mkswap`, `chmod 600`, runs `swapon` immediately, and adds it to `/etc/fstab` so it comes back at boot. |
| `zram` | Installs `zramen`, writes `/etc/zramen/zramen.conf` with the size, and enables the service. |

The size choices are 1 GB, 2 GB, 4 GB, 8 GB, same as RAM, twice RAM, or a custom
number of megabytes.

A 1 GB swap file is created with `dd if=/dev/zero of=/swapfile bs=1M count=1024`,
so it is instant on modern filesystems but does take a moment on slow storage.
Whenever a swap mode other than `none` is chosen, `vm.swappiness=10` is written
to `/etc/sysctl.d/99-voidl.conf`.

---

## What it changes on disk

| Path | Written by |
| --- | --- |
| `/etc/hostname`, `/etc/rc.conf` (`HOSTNAME`, `TIMEZONE`, `KEYMAP`) | identity |
| `/etc/locale.conf`, `/etc/profile.d/00-voidl-locale.sh`, `/etc/default/libc-locales` | locale |
| `/etc/localtime` | timezone |
| `/etc/X11/xorg.conf.d/00-keyboard.conf` | keyboard layout |
| `/etc/sudoers.d/<user>` | sudo |
| `/home/<user>` | user creation |
| `/etc/lightdm/lightdm.conf` | display manager and autologin |
| `/etc/wpa_supplicant/wpa_supplicant.conf` | Wi-Fi |
| `/etc/NetworkManager/`, `/etc/iw/` | alternative Wi-Fi stacks |
| `/etc/ssh/sshd_config` | SSH |
| `/etc/voidl/vnc.conf`, `/etc/voidl/vnc.pass`, `/etc/sv/voidl-vnc/` | VNC |
| `/etc/sv/voidl-ip-banner/`, `/usr/local/bin/void-ip-banner`, `/etc/issue` | IP banner |
| `/etc/sv/voidl-gadget/`, `/usr/local/bin/voidl-gadget-setup`, `/etc/voidl/gadget.conf`, `/etc/dnsmasq.d/voidl-gadget.conf` | USB gadget (Pi only) |
| `/swapfile`, `/etc/fstab`, `/etc/sysctl.d/99-voidl.conf` | swap |
| `/etc/zramen/zramen.conf` | zram |
| `/usr/local/bin/void-wireless` | the wireless tool |

Services are enabled by symlinking them into `/etc/runit/runsvdir/default/`.
Nothing is started or stopped behind your back: services are enabled, and the
reboot brings them up.

---

## Testing this yourself (QEMU)

The toolkit is developed and tested inside a real Void Linux VM. The harness is
not shipped (it is a handful of scratch scripts), but reproducing it is
straightforward and is a good way to try a configuration before committing it to
real hardware.

### What you need

* QEMU (`qemu-system-x86_64`), an x86_64 kernel with virtio and 9p support, and
  a Void root filesystem.
* A Void rootfs: any Void image works. If you do not have one, download the
  `void-rootfs` tarball or install Void into a disk image with the normal
  installer.
* KVM if your host has it. Without KVM, TCG is slow — expect boot to take a
  minute or two.

### Build a test image

```console
# 1. a 3 GiB raw disk, ext4
qemu-img create -f raw void-test.img 3G
mkfs.ext4 -L voidroot void-test.img

# 2. copy a Void rootfs into it
sudo mount -o loop void-test.img /mnt
sudo tar -xf void-rootfs.tar.xz -C /mnt --strip-components=1
sudo chroot /mnt /bin/sh -c 'echo "root:voidlinux" | chpasswd'
sudo ln -s /etc/sv/agetty-ttyS0 /mnt/etc/runit/runsvdir/default/agetty-ttyS0
sudo umount /mnt
```

`agetty-ttyS0` is the important one: it gives you a login prompt on the serial
console. Note that the service directory name must encode the tty — the `run`
script derives the device from its own path, so `agetty-ttyS0` runs `agetty …
ttyS0` while `agetty-serial` would try to open a device called `serial`.

### Boot it

```console
qemu-system-x86_64 \
    -machine pc,accel=tcg -m 1024 -smp 1 \
    -kernel arch/x86/boot/bzImage \
    -append "root=/dev/vda rw console=ttyS0,115200n8 panic=-1" \
    -drive file=void-test.img,format=raw,if=virtio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -fsdev local,id=fs0,path=$PWD,security_model=none \
    -device virtio-9p-pci,fsdev=fs0,mount_tag=repo \
    -display none -serial stdio -monitor none
```

The `9p` share is what lets you edit the scripts on the host and run the edited
copy in the guest without rebuilding anything:

```console
# inside the VM
mkdir -p /mnt/repo
mount -t 9p -o trans=virtio,version=9p2000.L repo /mnt/repo
sh /mnt/repo/ToolKit.sh --answers /mnt/repo/test.conf
```

### Serial console automation

`-serial stdio` is fine for watching. To script it, use a socket instead:

```console
-serial telnet:127.0.0.1:4545,server=on,wait=on
```

and connect with a small client that logs everything to a file and forwards
keystrokes. Two things to know when driving it:

* Send `\n`, not `\r`, for Enter — the scripts accept both, but a plain `\n`
  survives cooked and raw mode alike.
* The scripts switch the terminal to raw mode while waiting for a key, so
  terminal-settings commands like `stty size` will not work until the UI exits.

### What the test covers

| Check | How |
| --- | --- |
| Boot to a login prompt | Serial console shows `void login:` |
| The TUI renders | Box-drawing borders line up, menus are padded to the terminal width |
| Key handling | Arrow keys, number jumps, Enter, Esc and `q` all work under `dash` |
| Every prompt | Walk the wizard end to end, then abort at the review screen |
| Full apply | `--answers` with a complete configuration, then verify each file |
| Fetching the wireless tool | Run with `SKIP_FETCH=no` and check `/usr/local/bin/void-wireless` exists |
| Survives a reboot | `reboot`, then check hostname, swap, services and the IP banner |
| Non-destructive preview | `--dry-run --answers …` changes nothing |

### Notes on the sandbox test environment

Two things could not be exercised for real in the sandbox where this was
developed, and both are environmental rather than code issues:

* **Package downloads.** `repo.voidlinux.org` is not reachable from the sandbox,
  so `xbps-install` fails after about a second and the tool logs
  `failed to install some of: … (continuing)` and carries on. Every other step —
  user creation, `rc.conf`, `sudoers`, `wpa_supplicant.conf`, `sshd_config`,
  `lightdm.conf`, the swap file, the runit services — ran for real and was
  verified afterwards.
* **`git clone`.** `git` is not installed in the base rootfs, so the fallback
  path was taken: the tool downloads the repository tarball over HTTPS with
  `openssl s_client` and installs `wireless-settings.sh` from it. That fallback
  was exercised end to end — the VM really did download the archive from GitHub
  over the network and install `/usr/local/bin/void-wireless`. On a normal
  system `git` is installed first and the clone path is used instead.

---

## Troubleshooting

**"this does not look like an installed Void Linux system"**
You are probably running it from the live installer. Finish installing, reboot
into the new system, and run it again. If you are sure, add `--force`.

**The interface looks scrambled / borders do not line up**
The UI pads to the terminal width reported by `stty size`. If that is wrong
(usual after resizing a serial console), fix it with `stty cols 120 rows 40` and
run the tool again. `--no-color` helps on terminals that do not support colour.

**No arrow keys over a serial console**
Some terminal emulators do not send application-mode sequences. Use the number
keys (`1`…`9` then `Enter`), or `j`/`k` to move — both work everywhere.

**Wi-Fi scan finds nothing**
Check that the interface is up and not soft-blocked: `ip link set wlan0 up` and
`rfkill list`. On a Raspberry Pi, `linux-firmware` (or `rpi-firmware`) must be
installed and the `brcmfmac` module loaded. Hidden networks need
`WIFI_HIDDEN=yes`.

**`void-wireless` was not installed**
The tool prints the reason: either the download failed (no network, or a proxy
in the way) or the branch does not contain `wireless-settings.sh`. Install it by
hand with:

```console
sudo xbps-install -Sy git
git clone https://github.com/Harshit567834/VoidL-ToolKit.git /tmp/voidl
sudo cp /tmp/voidl/wireless-settings.sh /usr/local/bin/void-wireless
sudo chmod 755 /usr/local/bin/void-wireless
```

**A package failed to install**
The tool logs `failed to install some of: …` and continues, so one bad package
never aborts the whole run. Re-run just the install step with `xbps-install -Sy
<package>` once the repository is reachable.

**USB gadget mode is not offered**
It only appears when a Raspberry Pi is detected. Check `DEVICE=armv6hl` or
`aarch64` in the answers file, or run the wizard and pick the Pi entry. If your
board is not a Pi but has a USB device controller, set it up by hand — the gadget
service in `/etc/sv/voidl-usb-gadget/run` is readable and easy to adapt.

**The IP banner shows "no network address yet"**
The service waits 60 seconds for an address before printing. If the network
comes up later than that, the banner is refreshed within 30 seconds of the
address appearing — check `/etc/issue` on the login screen rather than the boot
log.

---

## Uninstalling

The tool only writes files and runit symlinks; it never repartitions or
reformats. To undo it:

```console
# stop and remove the services it created
for s in voidl-vnc voidl-ip-banner voidl-gadget; do
    sudo rm -f /etc/runit/runsvdir/default/$s
    sudo rm -rf /etc/sv/$s
done

# remove the files it wrote
sudo rm -f /usr/local/bin/void-wireless /usr/local/bin/void-ip-banner
sudo rm -f /usr/local/bin/voidl-gadget-setup
sudo rm -f /etc/sysctl.d/99-voidl.conf /etc/issue.voidl
sudo rm -rf /etc/voidl
sudo rm -f /etc/dnsmasq.d/voidl-gadget.conf

# restore the login banner
sudo cat /etc/issue.dist >/etc/issue 2>/dev/null || sudo truncate -s0 /etc/issue

# swap: turn it off and drop the fstab line
sudo swapoff /swapfile 2>/dev/null
sudo sed -i '\|^/swapfile|d' /etc/fstab
sudo rm -f /swapfile

# and rebuild /etc/issue.dist's default banner
sudo reboot
```

Packages that were installed stay installed; remove them with `xbps-remove` if
you no longer want them.

---

## Licence

MIT. See the header of either script.
