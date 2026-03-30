#!/bin/bash

# =============================================================================
# Stompbox - Startup Script
# Starts JACK -> a2jmidid -> Stompbox, with automatic MIDI connection
# =============================================================================

JACK_PID=""
A2J_PID=""
STOMPBOX_PID=""

# --- Robust cleanup: SIGTERM, wait, SIGKILL if necessary ---
cleanup() {
    echo "Cleanup: stopping processes..."
    for PID in $STOMPBOX_PID $A2J_PID $JACK_PID; do
        if [ -n "$PID" ] && kill -0 $PID 2>/dev/null; then
            kill -TERM $PID 2>/dev/null
        fi
    done
    # Wait max 3 seconds for clean shutdown
    for i in $(seq 1 3); do
        STILL_RUNNING=false
        for PID in $STOMPBOX_PID $A2J_PID $JACK_PID; do
            [ -n "$PID" ] && kill -0 $PID 2>/dev/null && STILL_RUNNING=true
        done
        [ "$STILL_RUNNING" = false ] && break
        sleep 1
    done
    # Force shutdown if still active
    for PID in $STOMPBOX_PID $A2J_PID $JACK_PID; do
        if [ -n "$PID" ] && kill -0 $PID 2>/dev/null; then
            kill -KILL $PID 2>/dev/null
        fi
    done
    wait 2>/dev/null || true
    echo "Cleanup completed."
}
trap cleanup EXIT INT TERM

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

CARD=$(grep -i "USB" /proc/asound/cards | awk '{print $1}' | head -1)
CARD_NAME=$(grep -i "USB" /proc/asound/cards | sed 's/.*\[//;s/\].*//' | head -1)
echo "USB card found: card $CARD ($CARD_NAME)"

# --- 2. Start JACK ---
export JACK_NO_AUDIO_RESERVATION=1

# Latency: -p 256 -n 2 = ~10.7ms at 48kHz (stable)
# For lower latency try: -p 128 -n 2 = ~5.3ms (requires more CPU)
jackd -R -P 80 -d alsa -d hw:$CARD -r 48000 -p 256 -n 2 &
JACK_PID=$!

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
echo "JACK started and ready (PID: $JACK_PID)."

# --- 3. Bridge ALSA MIDI -> JACK ---
a2jmidid -e &
A2J_PID=$!

# Wait for a2jmidid to expose MIDI ports (max 5 seconds)
echo "Waiting for MIDI ports..."
MIDI_READY=false
for i in $(seq 1 5); do
    if jack_lsp | grep -q "a2j:.*capture.*MIDI" 2>/dev/null; then
        MIDI_READY=true
        break
    fi
    sleep 1
done

if [ "$MIDI_READY" = true ]; then
    echo "a2jmidid started, MIDI ports available (PID: $A2J_PID)."
    jack_lsp | grep "a2j:" || true
else
    echo "WARNING: MIDI ports not detected. MIDI may not work."
    echo "Stompbox will start anyway."
fi

# --- 4. Start Stompbox ---
cd /home/pistomp/Stompbox/build/stompbox-jack
./stompbox-jack &
STOMPBOX_PID=$!

# --- 5. Automatic MIDI connection ---
# Waits for stompbox to register the midi_in port, then connects controllers
echo "Waiting for Stompbox MIDI port..."
STOMP_MIDI=false
for i in $(seq 1 10); do
    if jack_lsp | grep -q "stompbox:midi_in" 2>/dev/null; then
        STOMP_MIDI=true
        break
    fi
    sleep 1
done

if [ "$STOMP_MIDI" = true ]; then
    # Connect all a2j MIDI capture ports (excluding Midi Through) to stompbox
    jack_lsp | grep "a2j:" | grep "capture" | grep -v "Midi Through" | while read PORT; do
        jack_connect "$PORT" "stompbox:midi_in" 2>/dev/null && \
            echo "MIDI connected: $PORT -> stompbox:midi_in" || \
            echo "MIDI: $PORT already connected or error (not critical)"
    done
else
    echo "WARNING: stompbox:midi_in not found. MIDI connection not possible."
fi

# Wait for stompbox to exit
wait $STOMPBOX_PID
