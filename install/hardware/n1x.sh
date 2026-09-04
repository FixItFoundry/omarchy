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
# emergency shell go to a UART nobody is watching. limine-entry-tool prepends
# each "+=" fragment, reading drop-ins alphabetically after /etc/default/limine,
# so the fragment from the alphabetically FIRST drop-in ends up LAST on the
# kernel command line and wins every last-wins parameter (loglevel,
# systemd.show_status, ...) over omarchy-defaults.conf. BOOT_ORDER is a plain
# assignment where the last file read wins, hence the second, zz-, drop-in.
mkdir -p /etc/limine-entry-tool.d
cat > /etc/limine-entry-tool.d/00-omarchy-n1x-console.conf <<'CONF'
# N1x bring-up: keep the console on the panel and the boot verbose. Sorted first
# on purpose; see install/hardware/n1x.sh.
KERNEL_CMDLINE[default]+=" console=tty0 acpi=nospcr loglevel=7 systemd.show_status=1 rd.udev.log_level=info vt.global_cursor_default=1"
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
  '# N1x bring-up: rescue entry first until the GPU driver is proven.' \
  "KERNEL_CMDLINE[linux-n1x-rescue]=\"$rescue_cmdline\"" \
  'BOOT_ORDER="linux-n1x-rescue, linux-n1x, *fallback, *, Snapshots"' \
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
  --comment "N1x SSH recovery (graphics disabled)" --overwrite --quiet --no-mutex --no-hooks; then
  rm -f "$n1x_rescue_cmdline_file" "$n1x_rescue_uki"
  echo "Error: failed to register the N1x rescue UKI" >&2
  return 1
fi
rm -f "$n1x_rescue_cmdline_file" "$n1x_rescue_uki"

# GPU policy. The pinned open driver (610.57.04) binds 10de:2e06 but cannot
# boot its GSP (FWSEC chain-of-trust timeout), and a dead NVIDIA render node
# makes Hyprland abort. Keep the whole stack unloaded so Hyprland renders in
# software on the firmware framebuffer. install lines also stop explicit
# modprobe calls (nvidia-smi, session start) that a blacklist alone allows.
# Drop this file once a driver boots the GPU.
rm -f /etc/modprobe.d/nvidia.conf /etc/mkinitcpio.conf.d/nvidia.conf
cat > /etc/modprobe.d/omarchy-n1x-nvidia-disable.conf <<'CONF'
# N1x bring-up: 610.57.04 cannot boot this GPU's GSP; see install/hardware/n1x.sh.
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
blacklist nvidiafb
install nvidia /bin/false
install nvidia_drm /bin/false
install nvidia_modeset /bin/false
install nvidia_uvm /bin/false
install nvidiafb /bin/false
CONF

# Out-of-band access for bring-up: key-only SSH for the install user and a
# hardware probe on every boot. Networking stays with Omarchy's stack
# (hardware/network.sh disables systemd-networkd on purpose); the USB Ethernet
# dongle gets DHCP from NetworkManager like any other wired interface.
omarchy-pkg-add openssh pciutils
if [[ -n ${OMARCHY_INSTALL_USER:-} ]]; then
  user_home=$(getent passwd "$OMARCHY_INSTALL_USER" | cut -d: -f6)
  if [[ -n $user_home ]]; then
    install -d -m0700 -o "$OMARCHY_INSTALL_USER" -g "$OMARCHY_INSTALL_USER" "$user_home/.ssh"
    key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ4eMMpL8q81NSRMKSBP+x8WGw07QxYlvLpccQnZNh7C sbull-n1x-recovery'
    if ! grep -Fqx "$key" "$user_home/.ssh/authorized_keys" 2>/dev/null; then
      echo "$key" >> "$user_home/.ssh/authorized_keys"
    fi
    chown "$OMARCHY_INSTALL_USER:$OMARCHY_INSTALL_USER" "$user_home/.ssh/authorized_keys"
    chmod 0600 "$user_home/.ssh/authorized_keys"
  fi
fi
install -d -m0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/20-omarchy-n1x-recovery.conf <<'CONF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
CONF
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
systemctl enable sshd.service omarchy-n1x-probe.service
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp >/dev/null 2>&1 || true
fi
