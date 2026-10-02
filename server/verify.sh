#!/usr/bin/env bash
# verify.sh - prove the server half of the stack is actually serving, before you blame the laptop.
# Safe to run repeatedly. Non-zero exit = something is broken.
set -uo pipefail

SERVER_IP="${SERVER_IP:-10.0.0.10}"
TFTP="${TFTP:-/srv/tftp}"
HTTP="${HTTP:-/srv/http}"
DEPLOY="${DEPLOY:-/srv/deploy}"
SHARE_USER="${SHARE_USER:-deploy}"
FAILED=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
head() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }

head "services"
for svc in dnsmasq tftpd-hpa nginx smbd; do
  systemctl is-active --quiet "$svc" && ok "$svc active" || bad "$svc not active"
done

head "dnsmasq config"
if dnsmasq --test -C /etc/dnsmasq.d/pxe.conf >/dev/null 2>&1; then
  ok "pxe.conf parses"
else
  dnsmasq --test -C /etc/dnsmasq.d/pxe.conf || bad "pxe.conf"
fi

head "tftp ($TFTP)"
for f in undionly.kpxe ipxe.efi; do
  if [[ -f "$TFTP/$f" ]]; then ok "$f present"; else bad "$f missing"; fi
done
if command -v tftp >/dev/null; then
  tmp="$(mktemp)"
  if tftp "$SERVER_IP" -c get undionly.kpxe "$tmp" >/dev/null 2>&1; then
    ok "TFTP fetch of undionly.kpxe from $SERVER_IP works"; rm -f "$tmp"
  else
    bad "TFTP fetch from $SERVER_IP failed (firewall? tftpd not bound to 69?)"
  fi
fi

head "http ($HTTP)"
for u in boot.ipxe boot/wimboot winpe/Boot/BCD winpe/Boot/boot.sdi winpe/sources/boot.wim; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://$SERVER_IP/$u" || echo 000)"
  [[ "$code" == "200" ]] && ok "$u ($code)" || bad "$u -> HTTP $code"
done

head "samba (\\\\$SERVER_IP\\deploy)"
if smbclient -L "$SERVER_IP" -U "$SHARE_USER" -N >/dev/null 2>&1; then
  ok "share list reachable (anonymous probe)"
else
  ok "share list needs credentials (expected; probe with -U $SHARE_USER%<password>)"
fi

head "media on the share"
shopt -s nullglob
wims=("$DEPLOY"/images/*/install.wim "$DEPLOY"/images/*/*.wim)
if (( ${#wims[@]} )); then
  for w in "${wims[@]}"; do ok "$(du -h "$w" | cut -f1)  $w"; done
else
  bad "no install.wim under $DEPLOY/images (see images/Get-Win11Media.ps1)"
fi
[[ -f "$DEPLOY/config/osd.json" ]] && ok "config/osd.json present" || bad "config/osd.json missing"
[[ -d "$DEPLOY/drivers" && -n "$(ls -A "$DEPLOY/drivers" 2>/dev/null)" ]] \
  && ok "drivers/ populated" || bad "drivers/ empty (Lenovo SCCM package not extracted yet)"
[[ -f "$DEPLOY/postinstall/Post-Install.ps1" ]] \
  && ok "postinstall payload present" || bad "postinstall/Post-Install.ps1 missing"

head "watchers (live view while booting the laptop)"
cat <<EOF
  # watch the PXE conversation:
  journalctl -u dnsmasq -f | grep -E 'DHCP|PXE|proxy'
  # watch what the client downloads:
  tail -f /var/log/nginx/pxe-access.log
  # watch the deployment log the client writes back:
  tail -f $DEPLOY/logs/*.log
EOF

exit "$FAILED"
