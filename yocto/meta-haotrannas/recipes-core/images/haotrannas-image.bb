# What goes on the NAS SD card (D-044).
# Step 1 of M9: boot, SSH, RAID tools, found as nas.local.
# The Rust server recipe comes next (roadmap M9).

SUMMARY = "HaoTranNAS image: boots, SSH, mdadm RAID1, mDNS"

IMAGE_FEATURES += "ssh-server-openssh"

IMAGE_INSTALL = " \
    packagegroup-core-boot \
    mdadm \
    e2fsprogs \
    avahi-daemon \
"

IMAGE_LINGUAS = " "

inherit core-image
