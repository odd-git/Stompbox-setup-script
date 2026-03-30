# Stompbox-setup-script

# Stompbox Setup Scripts - Raspberry Pi OS Automation

Professional setup and configuration automation for [Stompbox](https://github.com/mikeoliphant/Stompbox) on Raspberry Pi 4/5.
Tested on: Pi 4

## What's Included

Three production-ready Bash scripts for complete Stompbox automation:

| Script | Purpose | Runtime |
|--------|---------|---------|
| `setup-stompbox.sh` | Install JACK, dependencies, real-time config, systemd service | ~5 minutes |
| `setup-hotspot.sh` | WiFi with automatic hotspot fallback at boot | ~2 minutes |
| `start-stompbox.sh` | Runtime startup script (launched by systemd) | Auto |

## Quick Start

```bash
# 1. Clone the Stompbox repository
git clone https://github.com/mikeoliphant/Stompbox.git
cd Stompbox

# 2. Run the main setup
bash scripts/setup/setup-stompbox.sh

# 3. (Optional) Configure WiFi with hotspot fallback
bash scripts/setup/setup-hotspot.sh

# 4. Reboot to apply all changes
sudo reboot

# Stompbox will start automatically on boot
```

## System Requirements

### Hardware

- **Raspberry Pi 4** (4GB+ RAM) or **Raspberry Pi 5** (8GB recommended)
- **USB Audio Interface** (low-latency recommended, tested with various interfaces)
- **MIDI Controller** (optional, auto-connected if present)
- **Power Supply** - 5V/3A minimum for Pi 4, 5V/5A for Pi 5

### Software

- **Raspberry Pi OS** 64-bit (Bookworm recommended)
- Fresh installation or previous setup cleanup
- Network connectivity (for package installation)
- SSH access enabled (or physical access for testing)

## What Gets Installed

### Audio Infrastructure

- **JACK 2** - Professional audio server with real-time priority
- **a2jmidid** - ALSA to JACK MIDI bridge (auto-connects controllers)
- Real-time kernel parameters for stable audio at low latency

### System Configuration

- **Real-time user permissions** - Audio group with RT capabilities
- **Console auto-login** - Automatic boot to desktop
- **Systemd service** - Auto-start Stompbox on boot with restart on crash
- **PipeWire/PulseAudio disabled** - Prevents audio conflicts

### Optional WiFi

- **NetworkManager** hotspot creation
- **Automatic fallback** - WiFi when available, hotspot as fallback
- **Default hotspot** - SSID: `pistomp`, Password: `pistomp00`

## Installation Details

### Step 1: Main Installation

```bash
bash setup-stompbox.sh
```

**What this does:**

1. ✅ Verifies prerequisites (not running as root, build exists)
2. ✅ Configures console auto-login
3. ✅ Installs JACK2 and a2jmidid packages
4. ✅ Sets real-time priority limits for audio group
5. ✅ Disables PipeWire/PulseAudio conflicts
6. ✅ Detects USB audio card
7. ✅ Creates Stompbox folders (Presets, NAM, Cabinets, etc.)
8. ✅ Configures systemd service for auto-start
9. ✅ Offers immediate startup test

**Output:** Color-coded feedback with clear section headers

### Step 2: WiFi Configuration (Optional)

```bash
bash setup-hotspot.sh
```

**What this does:**

1. ✅ Validates NetworkManager is installed and active
2. ✅ Creates hotspot connection (WiFi Access Point mode)
3. ✅ Assigns high priority to existing WiFi networks
4. ✅ Creates fallback service to activate hotspot if WiFi unavailable
5. ✅ Enables systemd service to run at boot

**Boot behavior:**

- Pi attempts WiFi connection (20 second wait)
- If successful: connects to known network
- If timeout: automatically activates hotspot
- Manual override available any time

### Step 3: Post-Installation

```bash
sudo reboot
```

Stompbox will auto-start on boot. Verify:

```bash
sudo systemctl status stompbox
journalctl -u stompbox -f  # Real-time logs
jack_lsp                   # Check JACK ports
```

## Configuration

### Adjust Audio Latency

Edit the JACK parameters in `start-stompbox.sh` or the systemd service:

```bash
# Current (balanced):
jackd -R -P 80 -d alsa -d hw:$CARD -r 48000 -p 256 -n 2
# ~10.7ms latency at 48kHz, stable

# Lower latency (higher CPU):
-p 128 -n 2    # ~5.3ms, requires 50%+ CPU
-p 64 -n 2     # ~2.7ms, may be unstable

# Higher stability (higher latency):
-p 512 -n 2    # ~21.3ms, very stable
```

### Change WiFi Hotspot Details

```bash
# Change SSID
nmcli connection modify Hotspot 802-11-wireless.ssid "NewName"

# Change password
nmcli connection modify Hotspot wifi-sec.psk "NewPassword"

# Change channel (1-11 for 2.4GHz)
nmcli connection modify Hotspot 802-11-wireless.channel 11
```

### Manual WiFi Control

```bash
# Activate hotspot
nmcli connection up Hotspot

# Return to WiFi
nmcli connection up "YourWiFiName"

# View all connections
nmcli connection show

# View connection status
nmcli device status
```

### MIDI Configuration

Automatic on boot, but manually connect additional controllers:

```bash
# List all MIDI ports
jack_lsp | grep midi

# Manually connect a device
jack_connect "a2j:device capture" "stompbox:midi_in"
```

## Troubleshooting

### JACK Won't Start

```bash
# Check system audio cards
cat /proc/asound/cards

# Verify USB card is present
lsusb | grep -i audio

# Manual JACK test (without scripts):
jackd -R -P 80 -d alsa -d hw:0 -r 48000 -p 256 -n 2
```

### MIDI Not Working

```bash
# Check a2jmidid is running
pgrep a2jmidid

# Restart MIDI bridge manually
killall a2jmidid 2>/dev/null || true
a2jmidid -e &
sleep 2
jack_lsp | grep a2j
```

### WiFi Hotspot Not Activating

```bash
# Check wifi-fallback service
systemctl status wifi-fallback

# View fallback logs
journalctl -u wifi-fallback -n 50

# Check NetworkManager
nmcli device status

# Manual hotspot test
nmcli connection up Hotspot
```

### High CPU Usage / Audio Glitches

```bash
# Check JACK status and CPU
jack_cpu_load
jack_server_control

# View real-time limits
cat /proc/`pidof stompbox-jack`/limits | grep RTPRIO

# Increase latency for stability
# (Edit jackd parameters, see Configuration section above)
```

### Permissions Issues

```bash
# Verify audio group membership
groups $USER

# If not in audio group, add user (requires reboot):
sudo usermod -a -G audio $USER

# Check real-time limits
cat /etc/security/limits.d/audio.conf
```

## Managing Stompbox Service

```bash
# Start/stop/restart
sudo systemctl start stompbox
sudo systemctl stop stompbox
sudo systemctl restart stompbox

# Check status
sudo systemctl status stompbox

# View logs
journalctl -u stompbox          # All logs
journalctl -u stompbox -f       # Real-time (like tail -f)
journalctl -u stompbox -n 100   # Last 100 lines

# Auto-start management
sudo systemctl enable stompbox   # Enable at boot
sudo systemctl disable stompbox  # Disable auto-start

# Test without systemd (direct script)
bash /home/[username]/start-stompbox.sh
```

## Verified Hardware

| Device | Tested | Notes |
|--------|--------|-------|
| Raspberry Pi 5 | ✅ | Excellent performance |
| Raspberry Pi 4 (8GB) | ✅ | Good, may need higher latency |
| Raspberry Pi 4 (4GB) | ⚠️ | Works but marginal headroom |
| USB Audio Interfaces | ✅ | Most major brands |

## Known Limitations

- **Arm32 (32-bit OS)**: Scripts target 64-bit. 32-bit requires adjustment
- **Non-USB audio**: Currently requires USB card (HDMI audio needs custom config)
- **WiFi range**: Hotspot has limited range (~10m in obstacles)
- **Simultaneous audio**: JACK exclusive mode, can't mix with other audio servers

## Related Projects

- **[Stompbox](https://github.com/mikeoliphant/Stompbox)** - Main Stompbox project
- **[JACK Audio](https://jackaudio.org/)** - Professional audio server
- **[Neural Amp Modeler](https://www.neural.sh/neural-amp-modeler)** - Amp modeling engine
