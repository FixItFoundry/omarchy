# NVIDIA N1x laptop (GB10-class SoC, MediaTek CPU-side peripherals; first seen
# as the Dell XPS 16 DX16263). Runs in the target chroot from
# omarchy-apply-hardware, after the settings package has dropped its Limine and
# mkinitcpio defaults and before the ISO's final limine-update builds the UKIs.

omarchy-hw-n1x || return 0

echo "Detected NVIDIA N1x platform, applying bring-up configuration..."

# The ISO installs linux-n1x through archinstall's kernels list; make sure the
# headers for DKMS are present and the stock kernel is gone so Limine shows a
# single kernel.
omarchy-pkg-add linux-n1x linux-n1x-headers
pacman -Rdd --noconfirm linux linux-headers 2>/dev/null || true
if pacman -Qq linux &>/dev/null; then
  echo "WARNING: stock linux kernel still installed alongside linux-n1x:"
  pacman -Qi linux | grep -i "required by"
fi

# Console and rescue boot contract.
#
# The firmware publishes an ACPI SPCR serial console at 0x16a00000; without
# acpi=nospcr the kernel adopts it and the LUKS prompt and any initramfs
# emergency shell go to a UART nobody is watching. The normal entry otherwise
# boots as quietly as on x86, so Plymouth stays up from the LUKS prompt to the
# login screen; the rescue entry below is the verbose one. BOOT_ORDER is a
# plain assignment where the last file read wins, hence the zz- drop-in.
mkdir -p /etc/limine-entry-tool.d
cat > /etc/limine-entry-tool.d/00-omarchy-n1x-console.conf <<'CONF'
# N1x: keep the console on the panel rather than the firmware's serial port;
# see install/hardware/n1x.sh.
KERNEL_CMDLINE[default]+=" console=tty0 acpi=nospcr"
CONF

# Rescue entry: same kernel and initramfs, NVIDIA blacklisted, multi-user
# target, console on the panel. Limine passes an entry's cmdline as EFI load
# options and systemd-stub prefers those over the UKI's embedded cmdline, so
# the rescue entry needs its own KERNEL_CMDLINE key rather than an embedded one.
root_cmdline=$(cat /etc/kernel/cmdline 2>/dev/null || true)
if [[ -z $root_cmdline || $root_cmdline != *root=* ]]; then
  echo "Error: /etc/kernel/cmdline has no root= (Limine defaults not written yet)" >&2
  return 1
fi
rescue_cmdline="$root_cmdline omarchy.n1x_recovery=1 acpi=nospcr plymouth.enable=0 nomodeset module_blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm,nvidia_peermem,nouveau modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm,nvidia_peermem,nouveau nvidia_drm.modeset=0 systemd.unit=multi-user.target console=tty0 fbcon=map:0 loglevel=7 ignore_loglevel systemd.show_status=1 systemd.log_target=console udev.log_level=debug vt.global_cursor_default=1"
printf '%s\n' \
  '# N1x bring-up: the rescue entry sits right below the normal one.' \
  "KERNEL_CMDLINE[linux-n1x-rescue]=\"$rescue_cmdline\"" \
  'BOOT_ORDER="linux-n1x, linux-n1x-rescue, *fallback, *, Snapshots"' \
  > /etc/limine-entry-tool.d/zz-omarchy-n1x-boot-order.conf

# Build the compact rescue UKI from the normal hardware-selected initramfs and
# register it as a custom entry. --no-hooks: this runs inside the installer's
# masked-hooks window; the final limine-update owns the normal UKI.
mapfile -t n1x_pkgbase_files < <(grep -lFx linux-n1x /usr/lib/modules/*/pkgbase 2>/dev/null || true)
if (( ${#n1x_pkgbase_files[@]} != 1 )); then
  echo "Error: expected one installed linux-n1x module tree, found ${#n1x_pkgbase_files[@]}" >&2
  return 1
fi
n1x_kernel_version=${n1x_pkgbase_files[0]#/usr/lib/modules/}
n1x_kernel_version=${n1x_kernel_version%/pkgbase}
n1x_rescue_cmdline_file=$(mktemp)
n1x_rescue_uki=$(mktemp --suffix=.efi)
printf '%s\n' "$rescue_cmdline" > "$n1x_rescue_cmdline_file"
if ! mkinitcpio --kernel "$n1x_kernel_version" --cmdline "$n1x_rescue_cmdline_file" --uki "$n1x_rescue_uki"; then
  rm -f "$n1x_rescue_cmdline_file" "$n1x_rescue_uki"
  echo "Error: failed to build the N1x rescue UKI" >&2
  return 1
fi
if ! limine-entry-tool --add-uki linux-n1x-rescue "$n1x_rescue_uki" \
  --comment "N1x rescue (text console, graphics off)" --overwrite --quiet --no-mutex --no-hooks; then
  rm -f "$n1x_rescue_cmdline_file" "$n1x_rescue_uki"
  echo "Error: failed to register the N1x rescue UKI" >&2
  return 1
fi
rm -f "$n1x_rescue_cmdline_file" "$n1x_rescue_uki"

# GPU policy, decided by the system firmware version.
#
# Pre-release firmware (0.x, e.g. 0.60.1) leaves the GPU's secure boot
# unanswered: the 610.57.04 open driver binds 10de:2e06 but cannot boot the
# GSP (FWSEC chain-of-trust timeout), and its dead render node aborts
# Hyprland. Keep the whole stack unloaded there so Hyprland renders in
# software on the firmware framebuffer. install lines also stop explicit
# modprobe calls (nvidia-smi, session start) that a blacklist alone allows.
#
# Firmware 1.0.4 and later boots the GSP. There the GPU drives the panel:
# early KMS so the console and LUKS prompt land on nvidia-drm's fbdev, and
# the firmware framebuffer driver is blacklisted (as NVIDIA ships on the
# Spark) so Hyprland sees exactly one DRM device. Verified 2026-09-11:
# eDP-1 at 1920x1200@120 with nothing else configured.
bios_version=$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo 0)
rm -f /etc/modprobe.d/nvidia.conf /etc/mkinitcpio.conf.d/nvidia.conf /etc/modprobe.d/omarchy-n1x-nvidia-disable.conf
cat > /etc/modprobe.d/omarchy-n1x-nvidiafb.conf <<'CONF'
# The legacy nvidiafb driver also claims this GPU and must never load.
blacklist nvidiafb
install nvidiafb /bin/false
CONF
n1x_gpu_driver=unloaded
if [[ $(printf '%s\n' 1.0.0 "$bios_version" | sort -V | head -1) == 1.0.0 ]]; then
  omarchy-pkg-add nvidia-open-dkms nvidia-utils libva-nvidia-driver
  # Early KMS lists the NVIDIA modules in the initramfs, so a DKMS build that
  # failed for this kernel would fail every UKI build. Fall back to the
  # firmware framebuffer instead: a software-rendered desktop beats no boot.
  if modinfo -k "$n1x_kernel_version" nvidia nvidia_modeset nvidia_uvm nvidia_drm &>/dev/null; then
    n1x_gpu_driver=nvidia
  else
    echo "WARNING: no NVIDIA DKMS modules for $n1x_kernel_version; keeping the NVIDIA stack unloaded" >&2
  fi
else
  echo "N1x firmware $bios_version: GPU firmware cannot boot on this BIOS; keeping the NVIDIA stack unloaded"
fi
if [[ $n1x_gpu_driver == nvidia ]]; then
  echo "N1x firmware $bios_version: GPU drives the panel"
  cat > /etc/modprobe.d/nvidia.conf <<'CONF'
options nvidia_drm modeset=1 fbdev=1
CONF
  cat > /etc/mkinitcpio.conf.d/nvidia.conf <<'CONF'
MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
CONF
  printf '%s\n' \
    '# N1x on firmware >= 1.0: the GPU owns the panel; drop the firmware' \
    '# framebuffer so Hyprland sees one DRM device.' \
    'KERNEL_CMDLINE[default]+=" initcall_blacklist=simpledrm_platform_driver_init"' \
    > /etc/limine-entry-tool.d/00-omarchy-n1x-gpu.conf

  # The panel stays at its dim power-on backlight until the NVIDIA backlight
  # is first written: its DPCD brightness registers read zero and nvidia_0
  # reports 100 regardless. systemd-backlight only writes it once the root
  # filesystem is unlocked, so the LUKS prompt is nearly black. An initramfs
  # hook right after plymouth writes it first.
  mkdir -p /etc/initcpio/install /etc/initcpio/hooks
  cat > /etc/initcpio/install/omarchy-n1x-boot-brightness <<'HOOK'
#!/bin/bash

build() {
    add_runscript
}

help() {
    cat <<HELPEOF
Light the NVIDIA N1x panel for Plymouth's LUKS prompt.
HELPEOF
}
HOOK
  cat > /etc/initcpio/hooks/omarchy-n1x-boot-brightness <<'HOOK'
#!/usr/bin/ash

# The panel stays at its dim power-on backlight until the NVIDIA backlight is
# first written, which systemd-backlight only does once the root filesystem is
# unlocked. Write it here so Plymouth's LUKS prompt is readable;
# systemd-backlight restores the saved level after unlock.
run_hook() {
    if [ -w /sys/class/backlight/nvidia_0/brightness ]; then
        echo 60 > /sys/class/backlight/nvidia_0/brightness
    fi
}
HOOK
  cat > /etc/mkinitcpio.conf.d/zz-omarchy-n1x-boot-brightness.conf <<'CONF'
# N1x: light the panel for Plymouth's LUKS prompt; see install/hardware/n1x.sh.
# Sorts after omarchy_hooks.conf so HOOKS is already set.
_omarchy_n1x_hooks=()
for _omarchy_n1x_hook in "${HOOKS[@]}"; do
  _omarchy_n1x_hooks+=("$_omarchy_n1x_hook")
  [[ $_omarchy_n1x_hook == plymouth ]] && _omarchy_n1x_hooks+=(omarchy-n1x-boot-brightness)
done
HOOKS=("${_omarchy_n1x_hooks[@]}")
unset _omarchy_n1x_hooks _omarchy_n1x_hook
CONF
else
  rm -f /etc/limine-entry-tool.d/00-omarchy-n1x-gpu.conf \
    /etc/mkinitcpio.conf.d/zz-omarchy-n1x-boot-brightness.conf
  cat > /etc/modprobe.d/omarchy-n1x-nvidia-disable.conf <<'CONF'
# N1x bring-up: the NVIDIA stack cannot drive this panel here; see install/hardware/n1x.sh.
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
install nvidia /bin/false
install nvidia_drm /bin/false
install nvidia_modeset /bin/false
install nvidia_uvm /bin/false
CONF
fi

# A hardware probe on every boot, for bring-up evidence. Remote access is
# deliberately not configured here: the N1x development ISO carries its own,
# separately removable SSH setup.
omarchy-pkg-add pciutils
# The probe ships in the runtime package (bin/omarchy-n1x-probe) so pacman
# owns it; only the unit file is written here.
cat > /etc/systemd/system/omarchy-n1x-probe.service <<'CONF'
[Unit]
Description=Capture N1x bring-up hardware and boot evidence
After=local-fs.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/share/omarchy/bin/omarchy-n1x-probe
StandardOutput=journal+console
StandardError=journal+console
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
CONF
systemctl enable omarchy-n1x-probe.service
