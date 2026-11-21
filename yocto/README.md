# yocto

Author: Hao Tran

The NAS image for the Raspberry Pi 5, built with Yocto (M9, D-044 to D-046).
Same shape as Bootlin yocto-kiss: one order sheet (`build-config/`, read by the kas tool) and one small layer of our own.
Everything else is downloaded.

```
 build-config/nas-pi5.yaml ──► downloads bitbake, openembedded-core, meta-raspberrypi
        │
        ▼
 meta-haotrannas/  distro (rules) + image (what goes on the SD card)
        │
        ▼  bitbake (hours the first time, minutes after)
 build/tmp/deploy/images/raspberrypi5/  ──► SD card ──► Pi 5 boots as nas.local
```

| Owns | kas files, `meta-haotrannas` layer |
|---|---|
| First milestone | M9 |
| Rules | [docs/conventions.md](../docs/conventions.md) |

## Files

| File | Does | yocto-kiss twin |
|---|---|---|
| `build-config/nas-pi5.yaml` | Layers, board `raspberrypi5`, distro, image | `kas/kiss.yaml` + `kas/stompduck.yaml` |
| `build-config/this-pc.yaml` | This PC only: 8 threads, `rm_work`, bench-test root login | `kas/local.yaml` |
| `meta-haotrannas/conf/layer.conf` | Makes the folder a layer | `meta-kiss/conf/layer.conf` |
| `meta-haotrannas/conf/distro/haotrannas.conf` | systemd, headless features only, hostname `nas` | `kiss.conf` |
| `meta-haotrannas/recipes-core/images/haotrannas-image.bb` | boot + SSH + mdadm + avahi | `kiss-image.bb` |

No machine layer: `meta-raspberrypi` already has one (D-044).

## What the names mean

| Name | Means | Can rename? |
|---|---|---|
| `build-config/` | Order sheets read by the kas tool | 🟢 yes, our name |
| `meta-…` | "a Yocto layer" (a folder of recipes) | 🟡 habit, every Yocto doc uses it |
| `conf/layer.conf` | The layer's ID card | 🔴 no, BitBake looks for it |
| `conf/distro/<name>.conf` | Rules; file name = distro name | 🔴 folder fixed |
| `recipes-core/images/` | Group folder / recipe folder | 🟢 yes, `layer.conf` sets the pattern |
| `*.bb` | A recipe: how to build one thing | 🔴 no |

## One-time PC setup

Ubuntu 24.04 blocks the user namespaces that BitBake needs. Without a fix, every
build stops with `User namespaces are not usable by BitBake, possibly due to AppArmor`.
Fix it with an AppArmor rule for BitBake only (from the Yocto docs, ⚪ not yet tested on this PC):

```
sudo nvim /etc/apparmor.d/bitbake
```

```
abi <abi/4.0>,
include <tunables/global>

profile bitbake /**/bitbake/bin/bitbake flags=(unconfined) {
    userns,
}
```

```
sudo apparmor_parser -r /etc/apparmor.d/bitbake
```

## Build · Flash · Test

kas lives in `/mnt/storage/PERSONAL/Yocto/.venv`. Run from this folder (`yocto/`):
the downloads and `build/` land here and are git-ignored.

| What | Command | Where |
|---|---|---|
| Activate kas | `source /mnt/storage/PERSONAL/Yocto/.venv/bin/activate` | this PC |
| Dry run (parse, no build) | `kas shell build-config/nas-pi5.yaml:build-config/this-pc.yaml -c "bitbake -n haotrannas-image"` | this PC |
| Build | `kas build build-config/nas-pi5.yaml:build-config/this-pc.yaml` | this PC |
| Flash | `sudo bmaptool copy build/tmp/deploy/images/raspberrypi5/<image>.wic.bz2 /dev/sdX` (⚪ exact name after the first build) | this PC + SD card |
| Test | Boot the Pi 5 on Ethernet, `ssh root@nas.local`, `mdadm --version` | Pi 5 |

🔴 `build-config/this-pc.yaml` lets root log in with no password. It is for the bench only:
never put the Pi on a network you don't trust with it, and never ship an image
built with it.

## Next in M9

| Step | Status |
|---|---|
| Image boots, SSH, `nas.local` | ⚪ needs the PC setup above, then a build |
| Recipe for `haotrannas-server` (Rust, ARM64) + its systemd unit | ⚪ |
| RAID1 set up on first boot, mounted at `/srv/haotrannas` | ⚪ |
| Phone backs up to the Pi 5 | ⚪ |
