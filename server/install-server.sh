#!/usr/bin/env bash
# install-server.sh - turn a Debian/Ubuntu homelab box into the deployment server.
#
# Serves four things on one host:
#   UDP 67/68/4011  dnsmasq proxyDHCP (PXE boot info only - your router keeps handing out leases)
#   UDP 69          tftpd-hpa (iPXE boot loaders)
#   TCP 80          nginx   (boot.ipxe menu, wimboot, WinPE BCD/boot.sdi/boot.wim)
#   TCP 445         samba   (install.wim, drivers, unattend, scripts, logs)
#
# Run:  sudo ./install-server.sh
set -euo pipefail

# ---------------------------------------------------------------- edit these
SERVER_IP="${SERVER_IP:-10.0.0.10}"      # this server's static LAN IP
IFACE="${IFACE:-eth0}"                   # the interface on the PXE segment
SUBNET="${SUBNET:-10.0.0.0/24}"
SHARE_USER="${SHARE_USER:-deploy}"       # SMB account non-root users use (and WinPE uses)
# ---------------------------------------------------------------------------

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=/srv
DEPLOY="$ROOT/deploy"      # SMB share
HTTP="$ROOT/http"          # nginx root
TFTP="$ROOT/tftp"          # tftpd root

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }

say "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  dnsmasq tftpd-hpa samba nginx-light \
  git make gcc binutils liblzma-dev mtools ipxe ipxe-qemu \
  smbclient curl jq tftp-hpa

say "directory tree"
install -d -m 0755 "$TFTP" "$HTTP" "$HTTP/boot" "$HTTP/winpe" "$DEPLOY"
install -d -m 2775 "$DEPLOY"/{images,drivers,scripts,config,postinstall,logs,state,cisco}
chown -R "$SHARE_USER":sambashare "$DEPLOY" 2>/dev/null || true
# web root layout expected by boot.ipxe:
#   $HTTP/boot/wimboot
#   $HTTP/winpe/Boot/BCD, $HTTP/winpe/Boot/boot.sdi, $HTTP/winpe/sources/boot.wim
install -d -m 0755 "$HTTP/winpe/Boot" "$HTTP/winpe/sources"

say "dnsmasq (proxyDHCP + TFTP)"
sed -e "s|@SERVER_IP@|$SERVER_IP|g" -e "s|@IFACE@|$IFACE|g" -e "s|@TFTP@|$TFTP|g" \
    "$SRC/etc/dnsmasq.conf" > /etc/dnsmasq.d/pxe.conf
# dnsmasq ships enabled on some distros with a default config that would fight systemd-resolved
# for :53; our pxe.conf sets port=0, so just (re)start it so the PXE config is the one loaded.
systemctl enable dnsmasq
systemctl restart dnsmasq
dnsmasq --test -C /etc/dnsmasq.d/pxe.conf

say "tftpd-hpa"
cat > /etc/default/tftpd-hpa <<EOF
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="$TFTP"
TFTP_ADDRESS=":69"
TFTP_OPTIONS="--secure --create"
EOF
systemctl enable --now tftpd-hpa

say "nginx"
sed -e "s|@HTTP@|$HTTP|g" -e "s|@SERVER_IP@|$SERVER_IP|g" \
    "$SRC/etc/nginx-deploy.conf" > /etc/nginx/sites-available/pxe-deploy
ln -sf /etc/nginx/sites-available/pxe-deploy /etc/nginx/sites-enabled/pxe-deploy
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx && systemctl restart nginx

say "samba"
# append once; the snippet is idempotent-guarded by a marker comment
if ! grep -q 'pxe-win11-deploy' /etc/samba/smb.conf 2>/dev/null; then
  sed -e "s|@DEPLOY@|$DEPLOY|g" -e "s|@SHARE_USER@|$SHARE_USER|g" \
      "$SRC/etc/smb.conf.snippet" >> /etc/samba/smb.conf
fi
if ! id "$SHARE_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SHARE_USER"
fi
usermod -aG sambashare "$SHARE_USER" || true
testparm -s >/dev/null
systemctl enable --now smbd nmbd

say "firewall"
if command -v ufw >/dev/null && ufw status | grep -q active; then
  ufw allow from "$SUBNET" to any port 67,68,69,4011 proto udp
  ufw allow from "$SUBNET" to any port 80,445 proto tcp
fi

say "done"
cat <<EOF
Next steps:
  1. sudo smbpasswd -a $SHARE_USER      # set a password (WinPE stores it in its secrets.json)
  2. sudo $SRC/build-ipxe.sh            # build ipxe.efi / undionly.kpxe, fetch wimboot
  3. Windows 11 media -> $DEPLOY/images/26H2/  (see images/Get-Win11Media.ps1)
  4. WinPE boot.wim   -> $HTTP/winpe/sources/boot.wim (see winpe/Make-WinPE.ps1)
  5. $SRC/verify.sh

  Boot info served to clients:  ${SERVER_IP} (TFTP UDP/69, HTTP TCP/80, SMB TCP/445)
  Share:   \\\\${SERVER_IP}\\deploy     ($DEPLOY, read-only for '$SHARE_USER')
  Share:   \\\\${SERVER_IP}\\deploy-out ($DEPLOY\\logs, $DEPLOY\\state - writable, for deploy logs)
EOF
