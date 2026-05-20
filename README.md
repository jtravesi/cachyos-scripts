# cachyos-scripts

A collection of shell scripts for managing and maintaining CachyOS systems — and in many cases, any Arch-based or systemd Linux distro.

The goal is not to replace existing tools, but to complement them with scripts that have real operational criteria: security auditing with pentester perspective, intelligent maintenance that avoids breaking things, and CachyOS-specific tooling that doesn't exist elsewhere.

---

## Quick start

```bash
git clone https://github.com/YOUR_USERNAME/cachyos-scripts.git
cd cachyos-scripts
chmod +x doctor.sh
./doctor.sh
```

`doctor.sh` runs a full read-only healthcheck of your system and tells you what needs attention. It won't modify anything.

---

## Structure

```
cachyos-scripts/
├── doctor.sh              # Full system healthcheck — start here
│
├── maintenance/           # System upkeep
│   ├── full-upgrade.sh
│   ├── clean-system.sh
│   └── check-failed-services.sh
│
├── security/              # Auditing and hardening
│   ├── audit-suid.sh
│   ├── audit-open-ports.sh
│   └── hardening-check.sh
│
├── performance/           # CPU, scheduler and I/O tuning
│   ├── set-cpu-governor.sh
│   ├── scx-scheduler-switch.sh
│   └── io-latency-check.sh
│
├── kernel/                # Kernel management
│   ├── list-kernels.sh
│   └── switch-kernel.sh
│
├── disk/                  # Disk and filesystem tools
│   ├── disk-usage.sh
│   ├── smart-check.sh
│   └── mount-manager.sh
│
├── network/               # Network diagnostics and management
│   ├── net-summary.sh
│   ├── open-connections.sh
│   ├── wifi-manager.sh
│   ├── bandwidth-check.sh
│   └── vpn-check.sh
│
├── snapshots/             # Btrfs snapshot management
│   ├── list-snapshots.sh
│   ├── create-snapshot.sh
│   └── restore-snapshot.sh
│
├── packages/              # Package auditing and management
│   ├── export-pkglist.sh
│   └── diff-pkglist.sh
│
├── logs/                  # Log analysis and cleanup
│   ├── boot-errors.sh
│   ├── log-analyzer.sh
│   └── clean-logs.sh
│
└── utils/                 # General utilities
    ├── system-info.sh
    └── backup-configs.sh
```

---

## Compatibility

Each script includes a header with:

| Field | Meaning |
|---|---|
| `Dependencies` | Required binaries or packages |
| `Compatibility` | `Any Linux`, `Any systemd Linux`, `Arch-based`, or `CachyOS` |

Scripts marked **CachyOS** use features specific to that distro (scx schedulers, cachyos-kernel-manager, etc).  
Scripts marked **Any Linux** rely only on standard POSIX/systemd tools and work on most distros.

> **Note:** Scripts in `snapshots/` require a **Btrfs** filesystem. They are not compatible with ext4, XFS or other filesystems. For ext4 users, consider [Timeshift](https://github.com/linuxmint/timeshift) as an alternative.

---

## Categories

### 🔧 Maintenance

Intelligent system upkeep beyond basic `pacman` usage.

| Script | Description | Compatibility |
|---|---|---|
| `full-upgrade.sh` | Full system upgrade with optional Btrfs snapshot before upgrading | CachyOS, Arch |
| `clean-system.sh` | Remove orphans, trim pacman cache, rotate logs with configurable limits | Arch-based |
| `check-failed-services.sh` | List failed systemd services with suggested actions | Any systemd Linux |

---

### 🔒 Security

Auditing scripts written with an operational security mindset — not just checklists.

| Script | Description | Compatibility |
|---|---|---|
| `audit-suid.sh` | Find SUID/SGID binaries outside known standard paths | Any Linux |
| `audit-open-ports.sh` | List listening ports with owning process and user | Any Linux |
| `hardening-check.sh` | Hardening checklist: SSH config, PAM, umask, sysctl params, critical file permissions | Any Linux |

---

### ⚡ Performance

CPU governor management and CachyOS-specific scheduler tooling.

| Script | Description | Compatibility |
|---|---|---|
| `set-cpu-governor.sh` | Switch CPU governor with hardware auto-detection | Any Linux |
| `scx-scheduler-switch.sh` | Manage and switch between scx_* schedulers (BORE, LAVD, etc.) | CachyOS |
| `io-latency-check.sh` | Quick I/O latency benchmark per device | Any Linux |

---

### 🐧 Kernel

| Script | Description | Compatibility |
|---|---|---|
| `list-kernels.sh` | List installed kernels, highlight active and next-boot kernel | CachyOS, Arch |
| `switch-kernel.sh` | Set default kernel in systemd-boot or GRUB | CachyOS, Arch |

---

### 💾 Disk

| Script | Description | Compatibility |
|---|---|---|
| `disk-usage.sh` | Disk usage summary by partition and top-N directories | Any Linux |
| `smart-check.sh` | SMART status for all disks with bad sector alerts | Any Linux |
| `mount-manager.sh` | List, mount and unmount devices with filesystem detection | Any Linux |

---

### 🌐 Network

| Script | Description | Compatibility |
|---|---|---|
| `net-summary.sh` | Active interfaces, IPs, gateway and DNS summary | Any Linux |
| `open-connections.sh` | Active network connections with owning process and user | Any Linux |
| `wifi-manager.sh` | WiFi network management from CLI via nmcli | Any Linux (NetworkManager) |
| `bandwidth-check.sh` | Bandwidth and latency test to configurable targets | Any Linux |
| `vpn-check.sh` | Detect active VPN interfaces, daemons and DNS leak risk | Any Linux |

---

### 📸 Snapshots *(Btrfs only)*

| Script | Description | Compatibility |
|---|---|---|
| `list-snapshots.sh` | List available Btrfs snapshots by subvolume | Linux + Btrfs |
| `create-snapshot.sh` | Create a named, timestamped snapshot of root or home | Linux + Btrfs |
| `restore-snapshot.sh` | Restore a previous snapshot with backup of current state | Linux + Btrfs |

---

### 📦 Packages

| Script | Description | Compatibility |
|---|---|---|
| `export-pkglist.sh` | Export installed packages (official + AUR) with versions | CachyOS, Arch |
| `diff-pkglist.sh` | Compare package lists between two systems or snapshots | CachyOS, Arch |

---

### 📋 Logs

| Script | Description | Compatibility |
|---|---|---|
| `boot-errors.sh` | Errors and warnings from current and previous boot | Any systemd Linux |
| `log-analyzer.sh` | Detect anomalous patterns in journald, summarized by service | Any systemd Linux |
| `clean-logs.sh` | Intelligent log cleanup with size and age limits | Any systemd Linux |

---

### 🛠 Utils

| Script | Description | Compatibility |
|---|---|---|
| `system-info.sh` | Full system summary: hardware, OS, resources, uptime | Any Linux |
| `backup-configs.sh` | Backup /etc and critical configs to a timestamped tar with checksum | Any Linux |

---
