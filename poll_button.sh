#!/bin/bash
# poll_button.sh - eSCL-Poller mit Duplex-Unterstuetzung

SCANNER_IP="${SCANNER_IP:-192.168.1.190}"
SCANNER_PORT="${SCANNER_PORT:-443}"
ESCL_URL="https://${SCANNER_IP}:${SCANNER_PORT}/eSCL/ScannerStatus"

POLL_INTERVAL="${POLL_INTERVAL:-2}"
TRIGGER_DELAY="${TRIGGER_DELAY:-10}"    # Sekunden AdfLoaded ohne Geraete-Job -> Scan
DUPLEX_WINDOW="${DUPLEX_WINDOW:-30}"    # Sekunden nach 1. Scan auf Rueckseiten warten
DUPLEX_STABLE="${DUPLEX_STABLE:-3}"     # Sekunden AdfLoaded stabil -> Rueckseiten-Scan
COOLDOWN="${COOLDOWN:-15}"
CONSUME_DIR="${CONSUME_DIR:-/consume}"
WORK_DIR="${WORK_DIR:-/tmp/scanwork}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [POLL]  $*"; }
logE() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }

wait_for_scanner() {
    log "Warte auf Scanner ${SCANNER_IP}:${SCANNER_PORT} ..."
    local attempts=0
    until curl -sk --max-time 3 "$ESCL_URL" > /dev/null 2>&1; do
        attempts=$((attempts + 1))
        (( attempts % 10 == 0 )) && log "Scanner nicht erreichbar (Versuch ${attempts}) ..."
        sleep 5
    done
    log "Scanner erreichbar. Warte 10s auf airscan mDNS-Discovery ..."
    sleep 10
    log "Poller aktiv."
}

fetch_status() {
    STATUS_XML=$(curl -sk --max-time 3 "$ESCL_URL" 2>/dev/null) || STATUS_XML=""
}
get_adf_state()     { echo "$STATUS_XML" | grep -oP '(?<=AdfState>)[^<]+' | head -1 || echo UNKNOWN; }
get_scanner_state() { echo "$STATUS_XML" | grep -oP '(?<=<pwg:State>)[^<]+' | head -1 || echo UNKNOWN; }

do_scan() {
    local target_dir="$1"
    mkdir -p "$target_dir"
    /scan.sh "$target_dir"
    local rc=$?
    # airscan Discovery nach Scan neu anstossen (verhindert "Invalid argument")
    scanimage -L > /dev/null 2>&1
    return $rc
}

finalize_simplex() {
    log "Simplex-Modus: erzeuge PDF ..."
    /merge.sh simplex "$1" "" "$CONSUME_DIR/scan_${2}.pdf"
}

finalize_duplex() {
    log "Duplex-Modus: interleave Scan A + B -> PDF ..."
    /merge.sh duplex "$1" "$2" "$CONSUME_DIR/scan_duplex_${3}.pdf"
}

# ── Init ─────────────────────────────────────────────────────────────────────
wait_for_scanner
mkdir -p "$WORK_DIR"

STATE="IDLE"
last_adf_state="ScannerAdfEmpty"
last_scan_time=0
adf_loaded_since=0
countdown_last_logged=0
scan_a_dir=""
scan_a_timestamp=""
duplex_window_start=0
duplex_loaded_since=0

log "=== Polling gestartet ==="
log "  eSCL-URL     : ${ESCL_URL}"
log "  Device       : ${DEVICE:-airscan:e0:EPSON ET-4800 Series}"
log "  Trigger-Delay: ${TRIGGER_DELAY}s"
log "  Duplex-Window: ${DUPLEX_WINDOW}s"
log "  Duplex-Stable: ${DUPLEX_STABLE}s"
log "  Cooldown     : ${COOLDOWN}s"
log "  Consume-Dir  : ${CONSUME_DIR}"

while true; do
    now=$(date +%s)
    fetch_status
    adf_state=$(get_adf_state)
    scanner_state=$(get_scanner_state)

    # =========================================================================
    # STATE: DUPLEX_WINDOW
    # Warten auf stabiles AdfLoaded (2. Stapel) oder Timeout -> Simplex
    # Logik: Wir merken uns die ADF-Baseline direkt nach dem 1. Scan.
    #        Nur ein Wechsel Empty->Loaded (oder Loaded->Loaded nach Empty)
    #        der DUPLEX_STABLE Sekunden haelt, loest den 2. Scan aus.
    # =========================================================================
    if [[ "$STATE" == "DUPLEX_WINDOW" ]]; then
        window_elapsed=$(( now - duplex_window_start ))
        window_remaining=$(( DUPLEX_WINDOW - window_elapsed ))

        # Zustandswechsel tracken
        if [[ "$adf_state" != "$last_adf_state" ]]; then
            log "  [DW] AdfState: ${last_adf_state} -> ${adf_state}"
            last_adf_state="$adf_state"

            if [[ "$adf_state" == "ScannerAdfLoaded" ]]; then
                # Neues Papier eingelegt - Timer starten
                duplex_loaded_since=$now
                log "  [DW] Rueckseiten-Stapel erkannt - pruefe Stabilitaet (${DUPLEX_STABLE}s) ..."
            else
                # ADF geleert - Timer zuruecksetzen
                duplex_loaded_since=0
            fi
        fi

        # Stabilitaetspruefung: ADF muss DUPLEX_STABLE Sekunden durchgehend befuellt sein
        if [[ "$adf_state" == "ScannerAdfLoaded" && $duplex_loaded_since -gt 0 ]]; then
            stable_for=$(( now - duplex_loaded_since ))
            if (( stable_for >= DUPLEX_STABLE )); then
                log ">>> DUPLEX: Rueckseiten stabil (${stable_for}s) - starte Scan B ..."
                STATE="SCANNING"
                scan_b_dir="${WORK_DIR}/scan_B_${scan_a_timestamp}"
                if do_scan "$scan_b_dir"; then
                    finalize_duplex "$scan_a_dir" "$scan_b_dir" "$scan_a_timestamp"
                    rm -rf "$scan_a_dir" "$scan_b_dir"
                else
                    logE "Rueckseiten-Scan fehlgeschlagen - Simplex-Fallback."
                    finalize_simplex "$scan_a_dir" "$scan_a_timestamp"
                    rm -rf "$scan_a_dir"
                fi
                last_scan_time=$(date +%s)
                last_adf_state="ScannerAdfEmpty"
                STATE="IDLE"
                adf_loaded_since=0
                duplex_loaded_since=0
                countdown_last_logged=0
                sleep "$POLL_INTERVAL"
                continue
            else
                # Noch nicht stabil genug - kurz loggen
                if (( now - countdown_last_logged >= 2 )); then
                    log "  [DW] ADF stabil seit ${stable_for}s / ${DUPLEX_STABLE}s ..."
                    countdown_last_logged=$now
                fi
            fi
        fi

        # Timeout -> Simplex
        if (( window_remaining <= 0 )); then
            log "Duplex-Fenster abgelaufen - Simplex-PDF wird erstellt."
            finalize_simplex "$scan_a_dir" "$scan_a_timestamp"
            rm -rf "$scan_a_dir"
            last_scan_time=$(date +%s)
            last_adf_state="$adf_state"
            STATE="IDLE"
            adf_loaded_since=0
            duplex_loaded_since=0
        else
            if (( now - countdown_last_logged >= 5 )); then
                log "Duplex-Fenster offen: noch ${window_remaining}s - Rueckseiten einlegen oder warten."
                countdown_last_logged=$now
            fi
        fi

        sleep "$POLL_INTERVAL"
        continue
    fi

    # =========================================================================
    # STATE: IDLE
    # =========================================================================
    if [[ "$adf_state" != "$last_adf_state" ]]; then
        log "AdfState: ${last_adf_state} -> ${adf_state}"
        last_adf_state="$adf_state"
        if [[ "$adf_state" == "ScannerAdfLoaded" ]]; then
            adf_loaded_since=$now
            countdown_last_logged=0
            log "Papier erkannt - Auto-Scan in ${TRIGGER_DELAY}s."
        else
            [[ $adf_loaded_since -gt 0 ]] && log "ADF geleert vor Timer-Ablauf."
            adf_loaded_since=0
            countdown_last_logged=0
        fi
    fi

    if [[ "$adf_state" == "ScannerAdfLoaded" && $adf_loaded_since -gt 0 ]]; then

        if (( now - last_scan_time < COOLDOWN )); then
            sleep "$POLL_INTERVAL"
            continue
        fi

        if [[ "$scanner_state" == "Processing" ]]; then
            log "Geraete-seitiger Scan - Auto-Scan abgebrochen."
            adf_loaded_since=0
            sleep "$POLL_INTERVAL"
            continue
        fi

        elapsed=$(( now - adf_loaded_since ))
        remaining=$(( TRIGGER_DELAY - elapsed ))

        if (( remaining > 0 )); then
            if (( now - countdown_last_logged >= 5 )); then
                log "Countdown: noch ${remaining}s bis Auto-Scan ..."
                countdown_last_logged=$now
            fi
        else
            log ">>> TRIGGER: scanne Vorderseiten ..."
            scan_a_timestamp=$(date +%Y%m%d_%H%M%S)
            scan_a_dir="${WORK_DIR}/scan_A_${scan_a_timestamp}"
            adf_loaded_since=0
            countdown_last_logged=0
            STATE="SCANNING"

            if do_scan "$scan_a_dir"; then
                pages_a=$(ls "$scan_a_dir"/*.pnm 2>/dev/null | wc -l)

                # Aktuellen ADF-State NACH dem Scan als Baseline lesen
                # Damit erkennen wir nur echte neue Einlegungen im Duplex-Window
                fetch_status
                adf_baseline=$(get_adf_state)
                last_adf_state="$adf_baseline"
                duplex_loaded_since=0

                duplex_window_start=$(date +%s)
                countdown_last_logged=0
                log "Vorderseiten: ${pages_a} Seite(n) gescannt."
                log "ADF-Baseline nach Scan: ${adf_baseline}"
                log ">>> Duplex-Fenster ${DUPLEX_WINDOW}s offen - Stapel umdrehen und einlegen."
                log "    (Oder ${DUPLEX_WINDOW}s warten fuer Simplex-PDF)"
                STATE="DUPLEX_WINDOW"
            else
                logE "Scan fehlgeschlagen."
                rm -rf "$scan_a_dir"
                STATE="IDLE"
            fi
        fi
    fi

    sleep "$POLL_INTERVAL"
done