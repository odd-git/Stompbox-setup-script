#!/bin/bash

# =============================================================================
# STOMPBOX - Complete setup script for Raspberry Pi OS 64bit
# Prerequisite: build already compiled in ~/Stompbox/build/stompbox-jack/
# Run with: bash setup-stompbox.sh
# =============================================================================

set -e

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
header() { echo -e "\n${BLUE}========================================${NC}"; echo -e "${BLUE} $1${NC}"; echo -e "${BLUE}========================================${NC}"; }

# --- Variables ---
CURRENT_USER="$USER"
USER_HOME="/home/$CURRENT_USER"
BUILD_DIR="$USER_HOME/Stompbox/build/stompbox-jack"
SCRIPT_PATH="$USER_HOME/start-stompbox.sh"
SERVICE_PATH="/etc/systemd/system/stompbox.service"

# =============================================================================
header "1. PREREQUISITES CHECK"
# =============================================================================

if [ "$EUID" -eq 0 ]; then
    error "Do not run as root. Use a regular user with sudo."
fi

log "User: $CURRENT_USER"
log "Home: $USER_HOME"

if [ ! -f "$BUILD_DIR/stompbox-jack" ]; then
    error "Executable not found at $BUILD_DIR/stompbox-jack\nMake sure the build is present before running this script."
fi
log "Build found: $BUILD_DIR/stompbox-jack"

# =============================================================================
header "2. CONSOLE AUTO-LOGIN CONFIGURATION"
# =============================================================================

if command -v raspi-config &>/dev/null; then
    sudo raspi-config nonint do_boot_behaviour B2
    log "Console auto-login enabled (B2)."
else
    # Manual fallback: override getty on tty1
    AUTOLOGIN_DIR="/etc/systemd/system/getty@tty1.service.d"
    sudo mkdir -p "$AUTOLOGIN_DIR"
    sudo bash -c "cat > $AUTOLOGIN_DIR/autologin.conf" << ALEOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $CURRENT_USER --noclear %I \$TERM
ALEOF
    log "Auto-login configured manually via getty override."
fi

# =============================================================================
header "3. INSTALLATION OF JACK AND MIDI DEPENDENCIES"
# =============================================================================

log "Updating package list..."
sudo apt-get update -qq

log "Installing JACK and a2jmidid..."
if apt-cache show jackd2 &>/dev/null; then
    sudo apt-get install -y jackd2 a2jmidid
elif apt-cache show jack2 &>/dev/null; then
    sudo apt-get install -y jack2 a2jmidid
else
    error "No JACK package found (jackd2 / jack2). Check your repositories."
fi
log "Packages installed."

# =============================================================================
header "4. REAL-TIME PERMISSIONS CONFIGURATION"
# =============================================================================

if groups $CURRENT_USER | grep -q '\baudio\b'; then
    log "User $CURRENT_USER already in audio group."
else
    sudo usermod -a -G audio $CURRENT_USER
    log "User $CURRENT_USER added to audio group."
    warn "The group will be active at next login."
fi

LIMITS_FILE="/etc/security/limits.d/audio.conf"
sudo bash -c "cat > $LIMITS_FILE" << 'EOF'
@audio   -  rtprio     95
@audio   -  memlock    unlimited
@audio   -  nice       -19
EOF
log "Real-time limits configured: $LIMITS_FILE"

# =============================================================================
header "5. DISABLING PIPEWIRE"
# =============================================================================

for svc in pipewire pipewire-pulse wireplumber; do
    if systemctl --user is-active "$svc" &>/dev/null; then
        systemctl --user stop "$svc" 2>/dev/null || true
        systemctl --user disable "$svc" 2>/dev/null || true
        systemctl --user mask "$svc" 2>/dev/null || true
        log "$svc disabled and masked."
    else
        log "$svc not active, skip."
    fi
done

# =============================================================================
header "6. AUDIO CARD DETECTION"
# =============================================================================

echo ""
echo "Available audio cards:"
echo "-------------------------"
cat /proc/asound/cards
echo "-------------------------"

USB_CARD=$(cat /proc/asound/cards | grep -i "USB" | awk '{print $1}' | head -1)

if [ -z "$USB_CARD" ]; then
    warn "No USB card detected at the moment."
    warn "The startup script will search for it dynamically at each boot."
else
    log "USB card detected: card $USB_CARD"
    echo ""
    echo "Details:"
    cat /proc/asound/cards | grep -A1 "USB" || true
fi

# =============================================================================
header "7. CREATION OF STOMPBOX FOLDERS"
# =============================================================================

for folder in Presets NAM Cabinets Reverb Music; do
    mkdir -p "$BUILD_DIR/$folder"
    log "Folder: $BUILD_DIR/$folder"
done

# =============================================================================
header "8. CREATION OF STARTUP SCRIPT"
# =============================================================================

cat > "$SCRIPT_PATH" << 'STARTSCRIPT'
#!/bin/bash

# --- Automatic cleanup on exit ---
JACK_PID=""
A2J_PID=""

cleanup() {
    echo "Cleanup: stopping processes..."
    [ -n "$A2J_PID" ] && kill $A2J_PID 2>/dev/null || true
    [ -n "$JACK_PID" ] && kill $JACK_PID 2>/dev/null || true
    wait 2>/dev/null || true
    echo "Cleanup completed."
}
trap cleanup EXIT

# --- 1. Wait for USB audio card (max 30 seconds) ---
echo "Waiting for USB audio card..."
USB_FOUND=false
for i in $(seq 1 30); do
    if grep -qi "USB" /proc/asound/cards; then
        USB_FOUND=true
        break
    fi
    sleep 1
done

if [ "$USB_FOUND" = false ]; then
    echo "ERROR: No USB audio card found after 30 seconds!"
    exit 1
fi

CARD=$(cat /proc/asound/cards | grep -i "USB" | awk '{print $1}' | head -1)
echo "USB card found: card $CARD"

# --- 2. Start JACK ---
export JACK_NO_AUDIO_RESERVATION=1

jackd -R -P 80 -d alsa -d hw:$CARD -r 48000 -p 256 -n 2 &
JACK_PID=$!

# Active wait for JACK to be ready (max 10 seconds)
echo "Waiting for JACK startup..."
JACK_READY=false
for i in $(seq 1 10); do
    if jack_lsp &>/dev/null; then
        JACK_READY=true
        break
    fi
    sleep 1
done

if [ "$JACK_READY" = false ]; then
    echo "ERROR: JACK did not start correctly!"
    exit 1
fi
echo "JACK started and ready."

# --- 3. Bridge ALSA MIDI -> JACK ---
a2jmidid -e &
A2J_PID=$!
sleep 1
echo "a2jmidid started."

# --- 4. Start Stompbox ---
STARTSCRIPT

# Inject the dynamic build path (not quoted from 'STARTSCRIPT')
cat >> "$SCRIPT_PATH" << STARTSCRIPT_DYNAMIC
cd $BUILD_DIR
./stompbox-jack
STARTSCRIPT_DYNAMIC

chmod +x "$SCRIPT_PATH"
log "Startup script created: $SCRIPT_PATH"

# =============================================================================
header "9. CREATION AND ENABLING OF SYSTEMD SERVICE"
# =============================================================================

sudo bash -c "cat > $SERVICE_PATH" << SERVICEEOF
[Unit]
Description=Stompbox Guitar Pedalboard
After=sound.target
After=local-fs.target

[Service]
Type=simple
User=$CURRENT_USER
Environment=JACK_NO_AUDIO_RESERVATION=1
LimitRTPRIO=95
LimitMEMLOCK=infinity
LimitNICE=-19
ExecStart=$SCRIPT_PATH
Restart=on-failure
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
SERVICEEOF

sudo chmod 664 "$SERVICE_PATH"
chmod 744 "$SCRIPT_PATH"

sudo systemctl daemon-reload
sudo systemctl enable stompbox.service
log "Stompbox service enabled at startup."

# Test immediate startup
echo ""
read -p "Do you want to test the service startup now? [y/N] " TEST_NOW
if [[ "$TEST_NOW" =~ ^[Yy]$ ]]; then
    sudo systemctl start stompbox.service
    sleep 5
    sudo systemctl status stompbox.service --no-pager
fi

# =============================================================================
header "SETUP COMPLETED"
# =============================================================================

echo ""
echo -e "${GREEN}Setup completed successfully!${NC}"
echo ""
echo -e "${YELLOW}Paths:${NC}"
echo "  Executable:     $BUILD_DIR/stompbox-jack"
echo "  Startup script: $SCRIPT_PATH"
echo "  Service:        $SERVICE_PATH"
echo ""
echo -e "${YELLOW}Content folders:${NC}"
echo "  NAM models:     $BUILD_DIR/NAM/"
echo "  Cabinet IR:     $BUILD_DIR/Cabinets/"
echo "  Reverb IR:      $BUILD_DIR/Reverb/"
echo "  Presets:        $BUILD_DIR/Presets/"
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo "  Manual startup:    sudo systemctl start stompbox"
echo "  Stop:              sudo systemctl stop stompbox"
echo "  Status:            sudo systemctl status stompbox"
echo "  Real-time logs:    journalctl -u stompbox -f"
echo "  Test script:       bash $SCRIPT_PATH"
echo ""
warn "Reboot the Raspberry Pi to apply all changes:"
echo "  sudo reboot"
echo ""
