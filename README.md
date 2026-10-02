# pxe-win11-deploy — MDT-free Windows 11 26H2 deployment for a homelab

A replacement for Microsoft Deployment Toolkit built from parts you can actually run on a
homelab server: **dnsmasq (proxyDHCP + TFTP) → iPXE → wimboot → your own WinPE → PowerShell + DISM**.
No ConfigMgr, no Intune, no domain required.

## Why not MDT / WDS / SCCM

| Thing | State (verify yourself before you rely on it) |
|---|---|
| **MDT** | Retired. "Immediate retirement notice" published 2026-01-06: no updates, fixes or support; existing installs keep working but get no compatibility updates for new Windows releases. Microsoft's suggested path is Autopilot (cloud) or Configuration Manager OSD (needs ConfigMgr). |
| **WDS server role** | Deprecated beginning with the Windows Server release *after* Server 2025 (KB 5129631, 2026-09-21): role, PXE boot, management tools all deprecated. Already partially dead: `boot.wim` from Windows 11 media + "WDS mode" Windows Setup is unsupported, and WDS hands-free deployment is disabled by default after the April 2026 updates. |
| **This stack** | Everything is a documented, still-supported primitive: PXE/DHCP (`dnsmasq`), iPXE, `wimboot`, WIM (DISM), `unattend.xml`, `SetupComplete.cmd`. Nothing in it can be retired out from under you, and it works on a Raspberry Pi / NAS / old NUC. |

If you *want* a packaged modern alternative instead of hand-rolled: **OSDCloud / OSDeploy**
(`Install-Module OSDCloud`, runs entirely from WinPE, pulls Windows from Microsoft, injects drivers,
runs your scripts) is the community's de-facto MDT replacement for exactly this scenario. The
`winpe/Make-WinPE.ps1` script here has a commented-out hook to drop the OSDCloud modules into the
WinPE image so you can use either approach with the same PXE plumbing.

## Target machine: ThinkPad X1 Yoga 3rd Gen (20LD / 20LE / 20LF / 20LG)

- 8th Gen Intel Core (Kaby Lake-R) + Intel UHD 620 → Windows 11 supported CPU list, TPM 2.0, UEFI, NVMe.
- **No RJ45 port.** Networking is the only real problem in this whole project:
  - The machine has a Lenovo *Ethernet Extension Connector* (the proprietary flat dongle) and
    USB-C/Thunderbolt 3.
  - UEFI network boot works reliably off the **built-in-ish NIC only on models that have one**, and off
    dock NICs only when the dock's UNDI driver is exposed through the platform's network stack. A USB
    or Ethernet-Extension NIC is a *USB* device as far as the firmware is concerned; many ThinkPads do
    not offer it as a UEFI boot option at all (the dock only shows up once Windows is running).
  - So plan A is *test it*: F12 → boot menu → look for something like `PCI LAN`, `Ethernet`,
    `Realtek/Intel ... PXE BCD`. If it is not there, plan B is `tools/Make-USB.ps1` (WinPE on a stick,
    same payload, images still pulled from the SMB share). That is not a downgrade — it is a scripted,
    unattended deployment either way, just with a 5-second plug-in step.

### BIOS settings (F1 at the Lenovo splash, or `Enter` → F1)

```
Startup   → Boot Mode / UEFI-Legacy Boot ....... UEFI Only, CSM = No
Startup   → Network Boot ...................... enabled, moved to top of boot order (or F12 each time)
Startup   → USB ............................... enabled            (plan B / USB WinPE)
Security  → Secure Boot ....................... Disabled           (iPXE binaries are unsigned)
Security  → I/O Port Access → Ethernet LAN .... Enabled
Security  → Secure Boot Mode .................. Standard (if you keep SB on for the signed-EFI route)
```

Secure Boot: the iPXE path needs it **off**. Windows boot files are Microsoft-signed, so you can turn it
back on after imaging and the installed OS still boots. If you refuse to disable it, skip iPXE and serve a
signed boot loader (a signed `ipxe.efi`/shim, or `wdsmgfw.efi` straight from the Windows media) as DHCP
option 67 — you lose the pretty menu, not the deployment.

## Architecture

```
   X1 Yoga (UEFI)                homelab server (Debian/Ubuntu)                 client disk
 ┌───────────────┐   DHCP      ┌──────────────────────────────────────┐
 │ firmware PXE  │────────────►│ dnsmasq  proxyDHCP: "go ask TFTP"    │
 │               │   TFTP      │ tftpd    ipxe.efi / undionly.kpxe    │
 │  iPXE         │◄────────────┴──────────────────────────────────────┘
 │   │ chainload http://server/boot.ipxe
 │   │            nginx :80   boot.ipxe + wimboot + Boot/BCD +
 │   ▼                        boot.sdi + sources/boot.wim (your WinPE)
 │ WinPE (boot.wim)
 │   │  startnet.cmd → Deploy.ps1
 │   │            SMB \\server\deploy   install.wim(26H2) + drivers + unattend + scripts
 │   ▼
 │ DISM: partition GPT → apply image → add drivers → unattend → bcdboot
 │        └─ first boot: SetupComplete.cmd → Post-Install.ps1 (apps, drivers, rename, cleanup)
 └────────────────────────────► reboot into Windows 11 26H2
```

Everything that changes per-deployment lives in `config/osd.json` **on the share**, so you can re-image
with different settings without ever rebuilding the WinPE image.

## Layout

```
pxe-win11-deploy/
├── README.md
├── config/
│   ├── osd.json                   # single source of truth (server, image, drivers, apps, names)
│   └── unattend.xml               # OOBE/locale/local-admin answer file
├── server/
│   ├── install-server.sh          # apt install + directory tree + configs + services
│   ├── build-ipxe.sh              # compile iPXE (BIOS+UEFI), fetch wimboot, publish to TFTP/HTTP
│   ├── verify.sh                  # smoke-test TFTP/HTTP/SMB/DHCP options
│   ├── boot.ipxe                  # the iPXE menu
│   └── etc/{dnsmasq.conf,smb.conf.snippet,nginx-deploy.conf}
├── winpe/
│   ├── Make-WinPE.ps1             # ADK: build/patch boot.wim, inject payload + NIC/storage drivers
│   └── payload/
│       ├── startnet.cmd           # WinPE entry point
│       ├── Deploy.ps1             # the actual deployment engine
│       └── diskpart-gpt.txt       # fallback partitioning if Storage cmdlets are unavailable
├── images/
│   └── Get-Win11Media.ps1         # fetch/mount ISO, verify build, export install.wim to the share
├── postinstall/
│   ├── SetupComplete.cmd          # first-boot hook (runs as SYSTEM, end of setup)
│   └── Post-Install.ps1           # apps, drivers, rename, telemetry, cleanup, marker file
└── tools/
    └── Make-USB.ps1               # plan B: bootable WinPE stick using the same payload
```

## Quickstart

```bash
# 1. server (Debian/Ubuntu homelab box, wired to the same L2 segment as the laptop)
sudo ./server/install-server.sh          # edit SERVER_IP / IFACE first
sudo ./server/build-ipxe.sh
sudo smbpasswd -a deploy

# 2. Windows 11 26H2 media (run on any Windows box with the ADK installed)
pwsh ./images/Get-Win11Media.ps1 -Destination '\\10.0.0.10\deploy\images\26H2'

# 3. WinPE (needs Windows ADK + WinPE add-on; Deployment and Imaging Tools prompt)
pwsh ./winpe/Make-WinPE.ps1 -PublishTo '\\10.0.0.10\deploy' -HttpRoot 'Z:\srv\http'   # adapt to your copy method

# 4. sanity check
./server/verify.sh

# 5. boot the X1 Yoga: F12 → network → pick "Deploy Windows 11 26H2 (automated)"
```

## Windows 11 26H2 notes

- 26H2 = build **26300**, GA 2026-09-29, same servicing branch as 24H2/25H2 → **Home/Pro supported for
  24 months, Enterprise/Education 36 months**. It ships as an *enablement package* on top of 24H2/25H2
  for upgrades, but 26H2 installation media exists, so a clean image apply is the straightforward path.
- `config/osd.json` has `EnablementMsu`: if you only have 25H2/24H2 media, apply that image and let
  `Post-Install.ps1` install the 26H2 enablement package (`dism /online /add-package`) — it is a
  single-restart, small package. Leave it empty when deploying from 26H2 media.
- Always verify the base build after applying: `Deploy.ps1` logs `dism /Get-WimInfo` output and the
  post-install script writes the resulting `CurrentBuild` to the completion marker on the share.

## Honest limitations

- WinPE and iPXE binaries are **unsigned** → Secure Boot off during deployment.
- The share password for unattended imaging ends up baked into the WinPE image (`secrets.json`,
  git-ignored). Use a dedicated low-privilege SMB account that can only read the deploy share.
- PXE is unauthenticated by design. Keep the PXE scope on an isolated VLAN or a lab segment.
- `unattend.xml` OOBE behaviour on 24H2+ builds is a moving target (Microsoft keeps tightening
  online-account requirements). The answer file here creates a local admin in the `oobeSystem` pass;
  if a build ever ignores it, the fallback is `start ms-cxh:localonly` at the OOBE prompt, or press
  Shift+F10 → `net user`. `SetupComplete.cmd` runs as SYSTEM after OOBE and always executes, so
  Post-Install still finishes, but a blocking OOBE can stop you at the logon screen.
- Lenovo's SCCM driver package for this model (ds503742, ~5.7 GB) targets Windows 10/11 21H2-era INFs.
  It works for clean installs; still run Lenovo Commercial Vantage / Windows Update afterwards for
  firmware and the newer audio/GPU/Thunderbolt pieces.
- Nothing here activates Windows. Homelab: use your own Pro/Enterprise key or a KMS/ADBA route you are
  licensed for.

## What was actually verified (and what was not)

Verified on the machine where this repo was written:

```
powershell -File tools/Test-DeployLogic.ps1     all 6 assertions pass
    'Windows 11 Pro'  -> index 6   (not Home=1, not 'Pro N'=7, not 'Pro Education'=8)
    'Windows 11 Pro N' -> index 7 ; case-insensitive match ; unknown edition throws
    media build detection reads 26300 from real `dism /Get-WimInfo` output
powershell -File <ps1 parser>                   all 6 .ps1 files parse (Windows PowerShell 5.1)
bash -n server/*.sh                             all 3 scripts parse
python <xml+json check>                         config/unattend.xml is well-formed and lists
                                                passes [specialize, oobeSystem] + local account 'deploy'
                                                config/osd.json + secrets.example.json are valid JSON
ASCII purity check                              no non-ASCII byte left in any .ps1/.cmd/.json/.xml
                                                (Windows PowerShell 5.1 reads BOM-less files as CP1252,
                                                 where U+2014 decodes to a stray smart quote and breaks
                                                 string parsing - keep code files pure ASCII)
```

NOT verified here (needs a Debian server + the ADK + the actual laptop): anything that decides what
happens on the wire. Specifically: `dnsmasq --test` on your distro's build, `testparm` on the Samba
snippet, `copype`/`MakeWinPEMedia`, DISM apply against your real install.wim, and whether your
firmware offers a bootable network device at all (see the X1 Yoga note at the top). Run
`server/verify.sh` first - it checks every serving path in one shot.

## Deliberate design choices worth knowing

- **Edition is resolved by name, not index number.** Applying "Windows 11 Home" to a lab machine
  because someone assumed index 1 is the classic self-inflicted MDT-era wound. `EditionName` is
  matched exactly (case-insensitively) against `dism /Get-WimInfo`, and an unknown name throws.
- **Config lives on the share, not in the image.** Re-imaging with a different hostname prefix,
  driver set or app list is a text edit on the server, not a 5-minute WinPE rebuild.
- **Two first-boot hooks.** `SetupComplete.cmd` (SYSTEM, cannot be blocked by OOBE policy) does the
  system-level work; `FirstLogonCommands` (admin user) does the winget app phase, because winget is
  unreliable in a SYSTEM context. Every phase is marker-guarded, so running twice is harmless.
- **Reserved storage and other risky tweaks are applied from Windows, not from `unattend.xml`.**
  An unrecognised setting in a configuration pass fails the *entire* pass; `dism /Online
  /Set-ReservedStorageState` cannot.

