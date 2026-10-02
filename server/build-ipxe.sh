#!/usr/bin/env bash
# build-ipxe.sh - compile iPXE (BIOS + UEFI), embed the chainload script, fetch wimboot,
# and publish everything into the TFTP and HTTP roots.
#
# Run after install-server.sh, as any user who can write /srv (sudo ./build-ipxe.sh).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_IP="${SERVER_IP:-10.0.0.10}"
TFTP="${TFTP:-/srv/tftp}"
HTTP="${HTTP:-/srv/http}"
WORK="${WORK:-/var/tmp/ipxe-build}"

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

say "source"
if [[ ! -d "$WORK/src/.git" ]]; then
  sudo mkdir -p "$WORK" && sudo chown "$(id -u):$(id -g)" "$WORK"
  git clone --depth 1 https://github.com/ipxe/ipxe.git "$WORK/src"
else
  git -C "$WORK/src" pull --ff-only
fi
cd "$WORK/src"

say "embed script (stage-2 bootstrap, so the firmware DHCP reply is tiny)"
cat > "$WORK/embed.ipxe" <<'EOF'
#!ipxe
dhcp || goto dhcpfailed
chain http://@SERVER_IP@/boot.ipxe || goto chainfailed

:dhcpfailed
prompt --key s --timeout 15000 DHCP failed. Press 's' for the iPXE shell, or reboot in 15s && shell || reboot

:chainfailed
prompt --key s --timeout 15000 Could not fetch http://@SERVER_IP@/boot.ipxe. 's' = shell && shell || reboot
EOF
sed -i "s|@SERVER_IP@|$SERVER_IP|g" "$WORK/embed.ipxe"

say "compile: undionly.kpxe (legacy BIOS)"
make -C src -j"$(nproc)" bin/undionly.kpxe EMBED="$WORK/embed.ipxe"

say "compile: ipxe.efi (64-bit UEFI)"
make -C src -j"$(nproc)" bin-x86_64-efi/ipxe.efi EMBED="$WORK/embed.ipxe" \
     CONFIG=qemu 2>/dev/null || make -C src -j"$(nproc)" bin-x86_64-efi/snponly.efi EMBED="$WORK/embed.ipxe"

say "publish boot loaders to $TFTP"
sudo install -m 0644 src/bin/undionly.kpxe "$TFTP/undionly.kpxe"
if [[ -f src/bin-x86_64-efi/ipxe.efi ]]; then
  sudo install -m 0644 src/bin-x86_64-efi/ipxe.efi "$TFTP/ipxe.efi"
else
  # snponly.efi reuses the NIC's own UEFI driver - smaller, but no extra NIC support.
  sudo install -m 0644 src/bin-x86_64-efi/snponly.efi "$TFTP/ipxe.efi"
fi

say "wimboot (boots boot.wim from HTTP ramdisk)"
WIMBOOT_VER="$(curl -fsSL https://api.github.com/repos/ipxe/wimboot/releases/latest | jq -r .tag_name)"
curl -fsSL -o "$WORK/wimboot" \
  "https://github.com/ipxe/wimboot/releases/latest/download/wimboot"
sudo install -d -m 0755 "$HTTP/boot"
sudo install -m 0644 "$WORK/wimboot" "$HTTP/boot/wimboot"
echo "  wimboot $WIMBOOT_VER $(sha256sum "$WORK/wimboot" | cut -d' ' -f1)"

say "menu"
sed -e "s|@SERVER_IP@|$SERVER_IP|g" "$SRC/boot.ipxe" | sudo tee "$HTTP/boot.ipxe" >/dev/null

say "done"
ls -l "$TFTP" "$HTTP/boot"
cat <<EOF

Now drop a WinPE into $HTTP/winpe/ (winpe/Make-WinPE.ps1 does this for you):
  $HTTP/winpe/Boot/BCD
  $HTTP/winpe/Boot/boot.sdi
  $HTTP/winpe/sources/boot.wim

Secure Boot: these iPXE binaries are UNSIGNED. Either disable Secure Boot on the client or
replace $TFTP/ipxe.efi with a signed build (shim + signed ipxe.efi).
EOF
