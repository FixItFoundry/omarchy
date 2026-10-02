# Memory fix for the 128 GB ASUS ProArt P14 H7407BA (NVIDIA N1x).
#
# The firmware reserves 62.5 GiB as EfiReservedMemoryType: the integrated GPU's
# dedicated memory under Windows. Linux's NVIDIA driver runs the GPU from system
# memory and never touches it, so the laptop boots with half its RAM, and the
# BIOS has no setting to shrink it. linux-omarchy-n1x's efi_reclaim_reserved=
# hands the idle part to the kernel. It leaves reserved the 48 MiB below it, the
# 32 KiB the firmware writes while training DRAM at 0x1080000000 (with the rest
# of its 128 MiB block), and the top 512 MiB, where the GPU's firmware runs.
#
# The ranges were measured on this reservation, so only add them when the
# firmware still reserves exactly that block. The kernel also ignores a range
# that is no longer all reserved memory, so a BIOS update that moves the
# reservation turns this off rather than handing out memory the GPU uses.

if omarchy-hw-match "H7407BA" && grep -qx '1fd000000-119fffffff : reserved' /proc/iomem; then
  mkdir -p /etc/limine-entry-tool.d
  cat > /etc/limine-entry-tool.d/omarchy-n1x-gpu-memory.conf <<'EOF'
# ASUS ProArt P14: use the idle part of the firmware's Windows GPU memory as RAM;
# see install/hardware/asus/fix-asus-proart-p14-gpu-memory.sh.
KERNEL_CMDLINE[default]+=" efi_reclaim_reserved=58G@8G,3968M@67712M"
EOF
fi
