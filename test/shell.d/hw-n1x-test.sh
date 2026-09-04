#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# base-test.sh offers pass/fail; wrap them into command-level assertions.
assert_succeeds() {
  local description="${@: -1}"
  if "${@:1:$#-1}" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}
assert_fails() {
  local description="${@: -1}"
  if "${@:1:$#-1}" >/dev/null 2>&1; then fail "$description"; else pass "$description"; fi
}

# omarchy-hw-n1x reads sysfs paths that tests can redirect, and refuses any
# machine that is not aarch64. Only the sysfs half is exercised here; the
# uname gate is checked by running the real script on this (x86_64) host.
write_sysfs() {
  rm -rf "$tmp_dir/acpi" "$tmp_dir/pci"
  mkdir -p "$tmp_dir/acpi" "$tmp_dir/pci"
  local acpi_id
  for acpi_id in $1; do
    mkdir -p "$tmp_dir/acpi/$acpi_id"
  done
  local index=0 spec
  for spec in $2; do
    local slot
    slot=$(printf '0000:%02x:00.0' "$index")
    mkdir -p "$tmp_dir/pci/$slot"
    printf '%s\n' "${spec%%:*}" >"$tmp_dir/pci/$slot/vendor"
    printf '%s\n' "${spec##*:}" >"$tmp_dir/pci/$slot/device"
    index=$((index + 1))
  done
}

hw_n1x() {
  # Pretend to be aarch64 by shadowing uname on PATH.
  local shim="$tmp_dir/bin"
  mkdir -p "$shim"
  printf '#!/bin/bash\necho aarch64\n' >"$shim/uname"
  chmod +x "$shim/uname"
  PATH="$shim:$PATH" OMARCHY_ACPI_DEVICES_PATH="$tmp_dir/acpi" OMARCHY_PCI_DEVICES_PATH="$tmp_dir/pci" "$ROOT/bin/omarchy-hw-n1x"
}

if [[ $(uname -m) != aarch64 ]]; then
  assert_fails "$ROOT/bin/omarchy-hw-n1x" "non-aarch64 host is never N1x"
fi

write_sysfs "NVDA0200:00 NVDA0200:03 ARML0002:00" ""
assert_succeeds hw_n1x "MediaTek I2C controllers (NVDA0200) identify N1x"

write_sysfs "PNP0C0D:00" "0x10de:0x2e06"
assert_succeeds hw_n1x "GB20B GPU 10de:2e06 identifies N1x"

write_sysfs "PNP0C0D:00 NVDA0301:00" "0x10de:0x2e12"
assert_fails hw_n1x "a Spark (2e12, Tegra I2C ids) is not N1x"

write_sysfs "" "0x8086:0x1234"
assert_fails hw_n1x "an unrelated machine is not N1x"

# hardware/n1x.sh contract: guarded by the detector, console pinned, quiet
# defeated through the alphabetically-first drop-in, rescue entry carries its
# own cmdline, NVIDIA kept unloaded, and wired before nvidia.sh.
n1x="$ROOT/install/hardware/n1x.sh"
assert_succeeds bash -n "$n1x" "n1x.sh parses"
assert_succeeds grep -Fq 'omarchy-hw-n1x || return 0' "$n1x" "n1x.sh is gated on the detector"
assert_succeeds grep -Fq '/etc/limine-entry-tool.d/00-omarchy-n1x-console.conf' "$n1x" "console drop-in sorts first"
assert_succeeds grep -Fq 'console=tty0 acpi=nospcr loglevel=7' "$n1x" "console fragment pins the panel and defeats quiet"
assert_succeeds grep -Fq 'KERNEL_CMDLINE[linux-n1x-rescue]=' "$n1x" "rescue entry has its own cmdline key"
assert_succeeds grep -Fq 'BOOT_ORDER="linux-n1x-rescue, linux-n1x, *fallback, *, Snapshots"' "$n1x" "rescue entry boots first"
assert_succeeds grep -Fq 'install nvidia_drm /bin/false' "$n1x" "NVIDIA stack blocked against explicit loads"
assert_succeeds grep -Fq -- '--add-uki linux-n1x-rescue' "$n1x" "rescue UKI is registered"
assert_fails grep -Fq 'systemd-networkd.service' "$n1x" "n1x.sh does not fight network.sh over networkd"
all="$ROOT/install/hardware/all.sh"
n1x_line=$(grep -n 'hardware/n1x.sh' "$all" | cut -d: -f1)
nvidia_line=$(grep -n 'hardware/nvidia.sh' "$all" | cut -d: -f1)
[[ -n $n1x_line && -n $nvidia_line && $n1x_line -lt $nvidia_line ]] || fail "n1x.sh must run before nvidia.sh"
assert_succeeds grep -Fq 'if omarchy-hw-n1x; then' "$ROOT/install/hardware/nvidia.sh" "nvidia.sh defers to the N1x policy"
assert_succeeds grep -Fq 'if [[ $(uname -m) == aarch64 ]]; then' "$ROOT/etc/mkinitcpio.conf.d/omarchy_hooks.conf" "initramfs hooks branch on aarch64"
assert_succeeds grep -Fq 'MODULES+=(i2c_mt65xx i2c_tegra i2c_hid i2c_hid_acpi hid_generic hid_multitouch usbhid)' "$ROOT/etc/mkinitcpio.conf.d/omarchy_hooks.conf" "early I2C-HID input modules on aarch64"

