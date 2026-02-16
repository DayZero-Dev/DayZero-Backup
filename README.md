# DayZero Backup Manager

```
    ____             _____                   
   / __ \____ ___  _/__  /  ___  _________   
  / / / / __ `/ / / / / /  / _ \/ ___/ __ \  
 / /_/ / /_/ / /_/ / / /__/  __/ /  / /_/ /  
/_____/\__,_/\__, / /____/\___/_/   \____/   
           /____/                            
```

> Interactive TUI for managing Restic backups to S3-compatible storage.

---

## Features

- Interactive menu-driven interface
- S3-compatible storage (iDrive E2, AWS S3, Wasabi, Backblaze, Cloudflare R2, MinIO, etc.)
- Multiple retention policies (simple, time-based, count-based)
- Optional LVM snapshot support
- Optional Discord notifications
- Automated cron scheduling

## Requirements

- Linux with root access
- Restic (auto-installed if missing)

---

## Installation

```bash
wget https://raw.githubusercontent.com/DayZero-Dev/DayZero-Backup/main/dayzero-backup-manager.sh
chmod +x dayzero-backup-manager.sh
sudo ./dayzero-backup-manager.sh
```

---

## Usage

Run the script with sudo and follow the interactive prompts:

```bash
sudo ./dayzero-backup-manager.sh
```

---

### Creating a Backup Job

The script will prompt you for:

1. **Basic info** - Job name, folder path, backup tag
2. **File paths** - Where to store env file and logs
3. **LVM snapshot** - Optional, for live database backups
4. **Discord** - Optional webhook URL for notifications
5. **S3 credentials** - Access key, secret key, repository URL, encryption password
6. **Retention policy** - How long to keep backups
   - Simple: Keep last N backups
   - Time: Keep backups within time period (7d, 4w, 6m, 1y)
   - Count: Keep specific daily/weekly/monthly/yearly backups
   - Unlimited: Never delete
7. **Cron schedule** - When to run backups (standard cron syntax)

### Configuration Files

```
/etc/dayzero-backup/
├── configs/    # Job configs (.conf)
├── env/        # S3 credentials (.env)
└── scripts/    # Backup scripts (.sh)
```

---

## Retention Examples

**Simple (last 10):**  
Keeps the 10 most recent backups, deletes older ones.

**Time-based (6 months):**  
Keeps all backups from the last 6 months.

**Count-based:**  
- Daily: last 7 days
- Weekly: last 4 weeks  
- Monthly: last 6 months
- Yearly: last 1 year

---

## Troubleshooting

**S3 connection fails:**  
Check your endpoint URL format: `s3:https://endpoint.com/bucket`

**Cron not running:**  
```bash
sudo crontab -l  # View cron jobs
sudo /etc/dayzero-backup/scripts/jobname.sh  # Test manually
```

**LVM snapshot fails:**  
Check available space with `vgs` and ensure mount point exists.

---

## License

GNU AGPL v3 - Any modifications or derivative works must be open source, even when used as a network service.

---

<div align="center">

**Built with [Restic](https://restic.net/)** - Fast, secure, efficient backup program

[GitHub](https://github.com/DayZero-Dev/DayZero-Backup) • [Report Issue](https://github.com/DayZero-Dev/DayZero-Backup/issues)

</div>
