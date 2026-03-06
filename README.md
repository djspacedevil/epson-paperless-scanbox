# epson-paperless-scanbox

Automatic network scanner workflow for Epson ADF scanners → Paperless-ngx.

Place paper in the ADF — everything else happens automatically. Supports simplex and manual duplex scanning with automatic blank page detection, including bleed-through recognition.

---

## Features

- **Automatic scan trigger** — detects paper in the ADF via eSCL polling, no button press required
- **Manual duplex** — scan front sides, flip the stack, scan back sides → automatically interleaved into a single PDF
- **Blank page detection** — removes blank pages including bleed-through from thin paper
- **airscan retry** — automatically recovers from mDNS discovery loss between scans
- **Fully configurable** via environment variables in `docker-compose.yml`
- **Docker-based** — runs as a container, tested on Raspberry Pi 5

---

## Supported Scanners

Any scanner that supports the **eSCL / AirScan** protocol over the network should work. Tested with:

| Scanner | Protocol | Notes |
|---|---|---|
| Epson ET-4800 | eSCL (AirScan) | ✅ Tested |
| Epson ET-Series (ET-2800, ET-3850, ...) | eSCL (AirScan) | ✅ Should work |
| Epson EcoTank Series | eSCL (AirScan) | ✅ Should work |
| Epson WorkForce Series (WF-xxxx) | eSCL (AirScan) | ✅ Should work |
| Epson Expression Series | eSCL (AirScan) | ✅ Should work |
| Other brands (HP, Canon, Brother) | eSCL (AirScan) | ⚠️ May work if eSCL is supported |

> **Note:** The scanner must have an ADF (Automatic Document Feeder) for auto-triggering. Flatbed-only scanners are not supported by the polling mechanism.

To check if your scanner supports eSCL, open `https://<scanner-ip>/eSCL/ScannerCapabilities` in your browser. An XML response confirms support.

---

## Finding Your Scanner

### Discover the IP address

```bash
# Option 1: avahi-browse (mDNS)
avahi-browse -t -r _uscan._tcp
avahi-browse -t -r _uscans._tcp

# Option 2: nmap scan of your subnet
nmap -sV --open -p 443,80 192.168.1.0/24 | grep -i epson

# Option 3: Check your router's DHCP client list
# Most routers show connected devices at http://192.168.1.1
```

### Find the SANE device name

```bash
# Inside the container after first start:
docker exec scanbox scanimage -L

# Example output:
# device `airscan:e0:EPSON ET-4800 Series' is a EPSON ET-4800 Series scanner
# device `escl:https://192.168.1.100:443' is a ...
```

Use the full string (e.g. `airscan:e0:EPSON ET-4800 Series`) as the `DEVICE` environment variable.

> **Tip:** If `airscan` does not list your device, use `escl:https://<ip>:<port>` directly — this bypasses mDNS discovery entirely and is more reliable on some networks.

---

## Prerequisites

- Linux host with Docker & Docker Compose
- Network scanner with eSCL/AirScan support and ADF
- Paperless-ngx with a mounted `consume` directory
- `network_mode: host` required (for mDNS/Avahi discovery)

---

## Project Structure

```
epson-paperless-scanbox/
├── Dockerfile          # Container build
├── docker-compose.yml  # Full stack (scanbox + Paperless-ngx)
├── poll_button.sh      # Main script: eSCL poller & state machine
├── scan.sh             # ADF scan via scanimage → PNM files
└── merge.sh            # PDF creation, duplex interleave, blank detection
```

---

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/djspacedevil/epson-paperless-scanbox.git
cd epson-paperless-scanbox
```

### 2. Adjust volume paths

The `docker-compose.yml` contains paths that **must be adapted to your environment**. Open it and change all volume paths to match your setup:

```yaml
# Example — replace with your actual paths:
volumes:
  - /home/pi/paperless-ngx/consume:/consume          # scanbox output
  - /home/pi/paperless-ngx/redisdata:/data           # Redis
  - /home/pi/paperless-ngx/pgdata:/var/lib/postgresql # PostgreSQL
  - /home/pi/paperless-ngx/data:/usr/src/paperless/data
  - /home/pi/paperless-ngx/media:/usr/src/paperless/media
  - /home/pi/paperless-ngx/export:/usr/src/paperless/export
```

> **Important:** The `consume` path must be the **same physical directory** for both `scanbox` and the Paperless-ngx `webserver` service.

### 3. Configure scanner connection

In `docker-compose.yml`, set your scanner's IP and device name:

```yaml
environment:
  SCANNER_IP: "192.168.1.100"                    # your scanner's IP
  DEVICE: "airscan:e0:EPSON ET-4800 Series"      # from: docker exec scanbox scanimage -L
```

### 4. Build and start

```bash
docker build -t scanbox:local .
docker compose up -d
docker logs -f scanbox
```

---

## Usage

### Simplex scan (single-sided)

1. Place document(s) in the ADF
2. Wait `TRIGGER_DELAY` seconds (default: 10s) — scan starts automatically
3. PDF appears in the Paperless-ngx consume folder

### Manual duplex scan (double-sided)

1. Place **front sides** in the ADF (pages 1, 3, 5, ...)
2. Scan starts automatically after `TRIGGER_DELAY`
3. After the scan: **flip the stack** and place back sides in the ADF
4. Within `DUPLEX_WINDOW` seconds (default: 30s), back sides are detected and scanned
5. An interleaved PDF is created automatically

**Duplex algorithm:**
```
Scan A (front sides):  [1, 3, 5, 7]
Flip stack
Scan B (back sides):   [8, 6, 4, 2]  →  reverse  →  [2, 4, 6, 8]
Interleave:            [1, 2, 3, 4, 5, 6, 7, 8]
```

---

## Configuration

All parameters are set as environment variables in `docker-compose.yml`.

### Scanner connection

| Variable | Default | Description |
|---|---|---|
| `SCANNER_IP` | — | IP address of your scanner |
| `SCANNER_PORT` | `443` | eSCL port (usually `443` or `80`) |
| `DEVICE` | — | SANE device name (from `scanimage -L`) |

### Scan parameters

| Variable | Default | Description |
|---|---|---|
| `SOURCE` | `ADF` | Scan source (`ADF` or `Flatbed`) |
| `MODE` | `Color` | Scan mode (`Color`, `Gray`, `Lineart`) |
| `RES` | `300` | Resolution in DPI |
| `MAX_PAGES` | `50` | Maximum pages per scan job |

### Poller behaviour

| Variable | Default | Description |
|---|---|---|
| `POLL_INTERVAL` | `2` | Seconds between eSCL status polls |
| `TRIGGER_DELAY` | `10` | Seconds ADF loaded without a device-side scan → trigger auto-scan |
| `DUPLEX_WINDOW` | `30` | Seconds to wait for back sides after the first scan |
| `DUPLEX_STABLE` | `3` | Seconds ADF must be stably loaded before back-side scan starts |
| `COOLDOWN` | `15` | Lock-out period after a completed scan |
| `CONSUME_DIR` | `/consume` | Target directory for finished PDFs (inside container) |
| `WORK_DIR` | `/tmp/scanwork` | Working directory for temporary files |

### Retry on discovery loss

| Variable | Default | Description |
|---|---|---|
| `SCAN_RETRIES` | `3` | Max attempts on `Invalid argument` (airscan mDNS loss) |
| `SCAN_RETRY_DELAY` | `8` | Seconds between retries |

### Blank page detection

| Variable | Default | Description |
|---|---|---|
| `BLANK_DETECT` | `1` | `1` = enabled, `0` = disabled |
| `BLANK_MEAN_MIN` | `0.985` | Page must be brighter than 98.5% to be a blank candidate |
| `BLANK_STDDEV_MAX` | `0.05` | Contrast variance ≤ 0.05 → blank. Bleed-through: ~0.039, real text: ~0.07+ |

**How blank page detection works:**

Two metrics are measured after a Gaussian blur (`-blur 0x2`):

- **mean** (average brightness): very bright pages are blank candidates
- **stddev** (contrast variance): bleed-through creates uniformly pale grey → low variance; real text creates hard black-on-white → high variance

A page is removed only if **both** conditions are true:
```
mean >= BLANK_MEAN_MIN  AND  stddev <= BLANK_STDDEV_MAX
```

Tuning:
- Bleed-through not detected → increase `BLANK_STDDEV_MAX` (e.g. `0.06`)
- Content pages incorrectly removed → decrease `BLANK_STDDEV_MAX` (e.g. `0.04`)
- Disable entirely → `BLANK_DETECT: "0"`

---

## Log Output Examples

### Simplex scan with blank page removed

```
[POLL]  AdfState: ScannerAdfEmpty -> ScannerAdfLoaded
[POLL]  Paper detected - auto-scan in 10s.
[POLL]  Countdown: 5s remaining ...
[POLL]  >>> TRIGGER: scanning front sides ...
[SCAN]  3 page(s) scanned in /tmp/scanwork/scan_A_20260305_091014.
[POLL]  Duplex window open 30s - flip stack or wait for simplex.
[POLL]  Duplex window expired - creating simplex PDF.
[MERGE] Simplex: 3 page(s) scanned.
[MERGE]   -> Content (mean=99.1%, stddev=0.0821)
[MERGE]   -> Content (mean=99.3%, stddev=0.0743)
[MERGE]   -> Blank page (mean=99.3%, stddev=0.0387 <= 0.05)
[MERGE]   Simplex: 1 blank page(s) removed -> 2 page(s) remaining.
[MERGE] Simplex: 2 page(s) -> /consume/scan_20260305_091014.pdf
[MERGE] Done: /consume/scan_20260305_091014.pdf (2.1M)
```

### Duplex scan

```
[POLL]  >>> TRIGGER: scanning front sides ...
[SCAN]  3 page(s) scanned in /tmp/scanwork/scan_A_20260305_104749.
[POLL]  Duplex window open: 28s remaining - insert back sides or wait.
[POLL]  [DW] AdfState: ScannerAdfEmpty -> ScannerAdfLoaded
[POLL]  [DW] Back-side stack detected - checking stability (3s) ...
[POLL]  >>> DUPLEX: back sides stable - starting scan B ...
[SCAN]  3 page(s) scanned in /tmp/scanwork/scan_B_20260305_104749.
[MERGE] Duplex: Scan-A=3, Scan-B=3 page(s). Interleaved: 6 pages.
[MERGE]   -> Blank page (mean=99.3%, stddev=0.0387 <= 0.05)
[MERGE]   Duplex: 1 blank page(s) removed -> 5 page(s) remaining.
[MERGE] Duplex: 5 page(s) -> /consume/scan_duplex_20260305_104749.pdf
[MERGE] Done: /consume/scan_duplex_20260305_104749.pdf (4.8M)
```

### airscan recovery

```
[SCAN]  Starting scan -> /tmp/scanwork/scan_A_20260305_091014
scanimage: open of device airscan:e0:EPSON ET-4800 Series failed: Invalid argument
[ERROR] airscan discovery lost (Invalid argument) - waiting 8s ...
[SCAN]  Retry 2/3 after 8s ...
Scanning page 1 ...
[SCAN]  3 page(s) scanned in /tmp/scanwork/scan_A_20260305_091014.
```

---

## Technical Background

### Why eSCL polling instead of button detection?

The eSCL/AirScan protocol does not expose button events over the network. Only `AdfState` (`ScannerAdfLoaded` / `ScannerAdfEmpty`) and `pwg:State` (`Idle` / `Processing`) are queryable. scanbox uses the `AdfState` transition as the scan trigger.

### Known quirks

- **airscan mDNS discovery loss:** The `sane-airscan` driver occasionally loses device discovery after a scan. The built-in retry calls `scanimage -L` between attempts to re-trigger mDNS resolution.
- **ADF state after scan:** Some Epson scanners briefly report `ScannerAdfLoaded` again immediately after a scan completes. scanbox reads the actual current state right after the scan as a fresh baseline, ignoring this effect.
- **Device-side scan:** If `pwg:State=Processing` is detected (user scanning directly from the device panel), the auto-trigger is cancelled.

### Tested SANE backends

| Backend | Result |
|---|---|
| `airscan:e0:EPSON ET-4800 Series` | ✅ Works |
| `escl:https://<ip>:443` | ✅ Works (no mDNS required) |
| `epson2:net:<ip>` | ❌ I/O errors |

---

## epsonscan2 — For ARM / Headless Builds

If `sane-airscan` or `escl` do not support your specific scanner model, the official Epson `epsonscan2` driver may be required. However, Epson's official `.deb` packages depend on a graphical environment and do not work on headless systems.

**[janrueth/epsonscan2](https://github.com/janrueth/epsonscan2)** provides a Docker-based build pipeline that compiles `epsonscan2` without any UI components, producing a clean `.deb` suitable for headless ARM64 systems (Raspberry Pi, etc.).

### Obtaining the source tarball

The source package is provided by Epson on their official Linux driver page:

**→ https://support.epson.net/linux/en/epsonscan2.php**

Use the **"Source file"** download link at the bottom of that page. The archive is named:
```
epsonscan2-<version>.src.tar.gz
# e.g. epsonscan2-6.7.43.0-1.src.tar.gz
```

Direct source download link:
```
https://download.ebz.epson.net/dsc/du/02/DriverDownloadInfo.do?LG2=JA&CN2=US&CTI=171&PRN=Linux%20src%20package&OSC=LX&DL
```

### Building the .deb

```bash
git clone https://github.com/janrueth/epsonscan2.git
cd epsonscan2

# Place the downloaded epsonscan2-*.src.tar.gz in this directory, then:
make docker-build    # builds inside Docker (works on x86, ARM64, Apple M1)
# or natively on the target machine:
make build
```

The resulting `.deb` can be installed without any X server or display dependency.

> **When is this needed?** Only if your scanner is not detected via `sane-airscan`/`escl` and specifically requires the `epsonscan2` backend. For most modern Epson network scanners, `sane-airscan` is sufficient.

---

## Updating

Only `poll_button.sh` changed — no rebuild needed:
```bash
docker cp poll_button.sh scanbox:/poll_button.sh
docker restart scanbox
```

`scan.sh` or `merge.sh` changed — rebuild required:
```bash
docker build -t scanbox:local .
docker compose up -d --force-recreate scanbox
```

---

## Troubleshooting

**Scanner not found (`scanimage -L` returns nothing):**
```bash
docker exec scanbox scanimage -L
# Check: network_mode: host set?
# Check: /var/run/dbus:/var/run/dbus volume mounted?
# Try: use escl directly to bypass mDNS:
DEVICE: "escl:https://<scanner-ip>:443"
```

**Persistent `Invalid argument` even after retries:**
```bash
# Increase retry delay:
SCAN_RETRY_DELAY: "15"
# Or use escl backend to skip mDNS:
DEVICE: "escl:https://<scanner-ip>:443"
```

**Blank pages not detected (bleed-through):**
```bash
BLANK_STDDEV_MAX: "0.06"
```

**Content pages incorrectly removed:**
```bash
BLANK_STDDEV_MAX: "0.04"
# or disable:
BLANK_DETECT: "0"
```

**Duplex window expires before back sides are inserted:**
```bash
DUPLEX_WINDOW: "60"
```

**Paperless-ngx does not pick up PDFs:**
- Verify both `scanbox` and `webserver` mount the same physical path to `/consume`
- Check file permissions — PDFs are created with mode `666`
- Check Paperless-ngx logs: `docker logs paperless-ngx-webserver-1`

---

## License

MIT
