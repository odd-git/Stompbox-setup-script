#!/bin/bash

# =============================================================================
# STOMPBOX - WiFi Hotspot Configuration with Automatic Fallback
# At boot: if it finds a known WiFi network it connects, otherwise creates hotspot
# Run with: bash setup-hotspot.sh
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

# --- Configurable variables ---
HOTSPOT_SSID="pistomp"
HOTSPOT_PASS="pistomp00"
HOTSPOT_IP="10.42.0.1/24"
HOTSPOT_CHANNEL="6"
HOTSPOT_CON_NAME="Hotspot"
FALLBACK_SCRIPT="/usr/local/bin/wifi-fallback.sh"
FALLBACK_SERVICE="/etc/systemd/system/wifi-fallback.service"
WIFI_TIMEOUT=20

# =============================================================================
header "1. PREREQUISITES CHECK"
# =============================================================================

if [ "$EUID" -eq 0 ]; then
    error "Do not run as root. Use a regular user with sudo."
fi

# Check NetworkManager
if ! command -v nmcli &>/dev/null; then
    error "NetworkManager not found. This script requires nmcli."
fi

if ! nmcli general status &>/dev/null; then
    error "NetworkManager is not active."
fi
log "NetworkManager is active."

# Check wlan0 interface
if ! nmcli device status | grep -q "wlan0"; then
    error "wlan0 interface not found."
fi
log "wlan0 interface present."

# =============================================================================
header "2. HOTSPOT CONFIGURATION"
# =============================================================================

# Remove any previous hotspot with the same name
if nmcli connection show "$HOTSPOT_CON_NAME" &>/dev/null; then
    sudo nmcli connection delete "$HOTSPOT_CON_NAME" &>/dev/null
    warn "Previous hotspot connection removed."
fi

# Create the hotspot connection
sudo nmcli connection add \
    type wifi \
    ifname wlan0 \
    con-name "$HOTSPOT_CON_NAME" \
    autoconnect no \
    ssid "$HOTSPOT_SSID"

sudo nmcli connection modify "$HOTSPOT_CON_NAME" 802-11-wireless.mode ap
sudo nmcli connection modify "$HOTSPOT_CON_NAME" 802-11-wireless.band bg
sudo nmcli connection modify "$HOTSPOT_CON_NAME" 802-11-wireless.channel "$HOTSPOT_CHANNEL"
sudo nmcli connection modify "$HOTSPOT_CON_NAME" ipv4.method shared
sudo nmcli connection modify "$HOTSPOT_CON_NAME" ipv4.addresses "$HOTSPOT_IP"
sudo nmcli connection modify "$HOTSPOT_CON_NAME" wifi-sec.key-mgmt wpa-psk
sudo nmcli connection modify "$HOTSPOT_CON_NAME" wifi-sec.psk "$HOTSPOT_PASS"
sudo nmcli connection modify "$HOTSPOT_CON_NAME" connection.autoconnect-priority 0

log "Hotspot created:"
echo "    SSID:     $HOTSPOT_SSID"
echo "    Password: $HOTSPOT_PASS"
echo "    IP:       $HOTSPOT_IP"
echo "    Channel:  $HOTSPOT_CHANNEL"

# =============================================================================
header "3. EXISTING WIFI NETWORK PRIORITY"
# =============================================================================

# Find the active WiFi connection (not the hotspot we just created)
CURRENT_WIFI=$(nmcli -t -f NAME,TYPE,DEVICE connection show --active | grep ":802-11-wireless:" | grep "wlan0" | cut -d: -f1)

if [ -n "$CURRENT_WIFI" ]; then
    sudo nmcli connection modify "$CURRENT_WIFI" connection.autoconnect-priority 10
    log "High priority assigned to: $CURRENT_WIFI (priority 10)"
    log "At boot the Pi will try this network first, then hotspot as fallback."
else
    warn "No active WiFi connection found."
    warn "If you have a home WiFi network, connect to it first and then run this script again,"
    warn "or manually set the priority with:"
    echo '    nmcli connection modify "network-name" connection.autoconnect-priority 10'
fi

# =============================================================================
header "4. CREATION OF FALLBACK SCRIPT"
# =============================================================================

sudo bash -c "cat > $FALLBACK_SCRIPT" << FBEOF
#!/bin/bash

# =============================================================================
# WiFi Fallback — If no known network is available, activate the hotspot
# =============================================================================

TIMEOUT=$WIFI_TIMEOUT
HOTSPOT="$HOTSPOT_CON_NAME"

echo "WiFi fallback: waiting for connection (max \${TIMEOUT}s)..."

for i in \$(seq 1 \$TIMEOUT); do
    if nmcli -t -f TYPE,STATE device | grep -q "wifi:connected"; then
        CONNECTED_TO=\$(nmcli -t -f NAME,DEVICE connection show --active | grep "wlan0" | cut -d: -f1)
        echo "WiFi connected to: \$CONNECTED_TO — hotspot not needed."
        exit 0
    fi
    sleep 1
done

echo "No WiFi network after \${TIMEOUT}s. Activating hotspot..."
nmcli connection up "\$HOTSPOT"

if [ \$? -eq 0 ]; then
    echo "Hotspot active: SSID=$HOTSPOT_SSID, IP=$HOTSPOT_IP"
else
    echo "ERROR: unable to activate hotspot."
    exit 1
fi
FBEOF

sudo chmod +x "$FALLBACK_SCRIPT"
log "Fallback script created: $FALLBACK_SCRIPT"

# =============================================================================
header "5. CREATION OF SYSTEMD SERVICE"
# =============================================================================

sudo bash -c "cat > $FALLBACK_SERVICE" << SVCEOF
[Unit]
Description=WiFi fallback to hotspot
After=NetworkManager-wait-online.service
Wants=NetworkManager-wait-online.service

[Service]
Type=oneshot
ExecStart=$FALLBACK_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable wifi-fallback.service
log "wifi-fallback service enabled at startup."

# =============================================================================
header "6. HOTSPOT TEST"
# =============================================================================

echo ""
read -p "Do you want to test the hotspot now? (you will lose current WiFi connection) [y/N] " TEST_NOW
if [[ "$TEST_NOW" =~ ^[Yy]$ ]]; then
    echo ""
    warn "Activating hotspot..."
    warn "SSH connection will be interrupted!"
    warn "To connect: look for network '$HOTSPOT_SSID', password '$HOTSPOT_PASS'"
    warn "Then SSH to: ${HOTSPOT_IP%/*}"
    echo ""
    read -p "Confirm? [y/N] " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        sudo nmcli connection up "$HOTSPOT_CON_NAME"
        sleep 2
        log "Hotspot active."
        echo ""
        echo "To return to WiFi:"
        echo "    sudo nmcli connection up \"$CURRENT_WIFI\""
    fi
else
    log "Test skipped."
fi

# =============================================================================
header "HOTSPOT SETUP COMPLETED"
# =============================================================================

echo ""
echo -e "${GREEN}Configuration completed!${NC}"
echo ""
echo -e "${YELLOW}Summary:${NC}"
echo "  Hotspot SSID:     $HOTSPOT_SSID"
echo "  Password:         $HOTSPOT_PASS"
echo "  Pi IP:            ${HOTSPOT_IP%/*}"
echo "  Stompbox UI:      http://${HOTSPOT_IP%/*}:<port>"
echo ""
echo -e "${YELLOW}Boot behavior:${NC}"
if [ -n "$CURRENT_WIFI" ]; then
    echo "  1. Try to connect to: $CURRENT_WIFI"
else
    echo "  1. Try to connect to known WiFi networks"
fi
echo "  2. If no network after ${WIFI_TIMEOUT}s → activate hotspot"
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo "  Activate hotspot manually:    nmcli connection up Hotspot"
echo "  Return to WiFi:               nmcli connection up \"network-name\""
echo "  Connection status:            nmcli device status"
echo "  Fallback logs:                journalctl -u wifi-fallback"
echo ""
echo -e "${YELLOW}To change SSID or password:${NC}"
echo "  nmcli connection modify Hotspot 802-11-wireless.ssid \"NewName\""
echo "  nmcli connection modify Hotspot wifi-sec.psk \"NewPassword\""
echo ""
