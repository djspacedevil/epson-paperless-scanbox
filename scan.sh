#!/bin/bash
# scan.sh - Scannt ADF in ein Zielverzeichnis (kein PDF, nur PNM-Dateien)
# Aufruf: /scan.sh <zielverzeichnis>
# Bei "Invalid argument" (airscan Discovery verloren) wird automatisch
# bis zu SCAN_RETRIES mal mit SCAN_RETRY_DELAY Sekunden Pause neu versucht.

TARGET_DIR="${1:-/tmp/scan_out}"
DEVICE="${DEVICE:-airscan:e0:EPSON ET-4800 Series}"
SOURCE="${SOURCE:-ADF}"
MODE="${MODE:-Color}"
RES="${RES:-300}"
MAX_PAGES="${MAX_PAGES:-50}"
SCAN_RETRIES="${SCAN_RETRIES:-3}"
SCAN_RETRY_DELAY="${SCAN_RETRY_DELAY:-8}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SCAN]  $*"; }
logE() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }

mkdir -p "$TARGET_DIR"
log "Starte Scan -> ${TARGET_DIR}"
log "  Geraet: ${DEVICE} | ${SOURCE} | ${MODE} @ ${RES}dpi"

attempt=0
while (( attempt < SCAN_RETRIES )); do
    attempt=$(( attempt + 1 ))
    [[ $attempt -gt 1 ]] && log "Retry ${attempt}/${SCAN_RETRIES} nach ${SCAN_RETRY_DELAY}s ..."

    # Bereits gescannte Seiten aus vorherigen Versuchen entfernen
    rm -f "${TARGET_DIR}"/page_*.pnm

    SCAN_OUTPUT=$(scanimage \
        -d "${DEVICE}" \
        --source "${SOURCE}" \
        --resolution "${RES}" \
        --mode "${MODE}" \
        --batch="${TARGET_DIR}/page_%04d.pnm" \
        --batch-count="${MAX_PAGES}" \
        2>&1)
    SCAN_EXIT=$?
    echo "$SCAN_OUTPUT"

    # Exit 7 = ADF nach letzter Seite leer -> Erfolg
    if [[ $SCAN_EXIT -eq 0 || $SCAN_EXIT -eq 7 ]]; then
        break
    fi

    # "Invalid argument" = airscan Discovery weg -> warten und nochmal
    if echo "$SCAN_OUTPUT" | grep -q "Invalid argument"; then
        logE "airscan Discovery verloren (Invalid argument) - warte ${SCAN_RETRY_DELAY}s ..."
        # Kurze scanimage -L um Discovery neu anzustossen
        scanimage -L > /dev/null 2>&1
        sleep "$SCAN_RETRY_DELAY"
        continue
    fi

    # Anderer Fehler -> sofort abbrechen
    logE "scanimage Fehler (Exit-Code: ${SCAN_EXIT}) - kein Retry."
    exit 1
done

if [[ $SCAN_EXIT -ne 0 && $SCAN_EXIT -ne 7 ]]; then
    logE "Scan nach ${SCAN_RETRIES} Versuchen fehlgeschlagen."
    exit 1
fi

pages=$(ls "${TARGET_DIR}"/page_*.pnm 2>/dev/null | wc -l)
if [[ $pages -eq 0 ]]; then
    logE "Keine Seiten gescannt (ADF leer?)."
    exit 1
fi

log "${pages} Seite(n) gescannt in ${TARGET_DIR}."