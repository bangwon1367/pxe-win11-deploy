# pxe-win11-deploy
A replacement for Microsoft Deployment Toolkit built from parts you can actually run on a homelab server: **dnsmasq (proxyDHCP + TFTP) → iPXE → wimboot → your own WinPE → PowerShell + DISM**. No ConfigMgr, no Intune, no domain required.
