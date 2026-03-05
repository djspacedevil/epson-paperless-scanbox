#!/bin/bash
# merge.sh - Erzeugt PDF aus gescannten PNM-Dateien
#
# Simplex:  /merge.sh simplex <scan_dir> "" <out.pdf>
# Duplex:   /merge.sh duplex  <scan_a_dir> <scan_b_dir> <out.pdf>
#
# Duplex-Algorithmus (manuelles Wenden):
#   Scan A: Vorderseiten [1, 3, 5, 7]
#   Scan B: Rueckseiten umgekehrt [8, 6, 4, 2] -> umkehren -> [2, 4, 6, 8]
#   Interleave -> [1, 2, 3, 4, 5, 6, 7, 8]
#
# Leerseiten-Erkennung (Methode: Anteil dunkler Pixel):
#   BLANK_DETECT=1              Aktiviert (Standard: 1)
#   BLANK_MEAN_MIN=0.985        Seite muss heller als X sein (0.0-1.0)
#   BLANK_STDDEV_MAX=0.05       Und Kontrast-Varianz kleiner als X -> leer
#                               Erkennt Durchscheinen: gleichmaessig grau hat
#                               niedrige stddev, echter Text hat hohe stddev

MODE="$1"
SCAN_A="$2"
SCAN_B="$3"
OUTFILE="$4"

BLANK_DETECT="${BLANK_DETECT:-1}"
BLANK_MEAN_MIN="${BLANK_MEAN_MIN:-0.985}"
BLANK_STDDEV_MAX="${BLANK_STDDEV_MAX:-0.05}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [MERGE] $*"; }
logE() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }

TMPDIR=$(mktemp -d /tmp/merge_XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# -----------------------------------------------------------------------
# Prueft ob eine PNM-Datei leer ist (zu wenig dunkle Pixel)
# Gibt 0 zurueck wenn leer, 1 wenn Inhalt vorhanden
# -----------------------------------------------------------------------
is_blank() {
    local file="$1"
    [[ "$BLANK_DETECT" != "1" ]] && return 1

    # Zwei-Metrik-Erkennung gegen Durchscheinen:
    # Methode: mean (Helligkeit) + stddev (Kontrast-Varianz)
    #
    # Durchschein-Seite: gleichmaessig grau  -> hohe mean, NIEDRIGE stddev
    # Echte Seite:       schwarzer Text      -> hohe mean, HOHE stddev
    # Komplett weiss:    alles weiss         -> mean=1.0,  stddev=0
    #
    # Eine Seite gilt als leer wenn:
    #   mean >= BLANK_MEAN_MIN (Standard: 0.985) -> sehr hell
    #   UND
    #   stddev <= BLANK_STDDEV_MAX (Standard: 0.05) -> wenig Kontrast
    local stats
    stats=$(convert "$file" -colorspace Gray -blur 0x2 \
        -format "%[fx:mean] %[fx:standard_deviation]" info: 2>/dev/null)

    if [[ -z "$stats" ]]; then
        return 1  # Im Zweifel: nicht leer
    fi

    local mean stddev
    mean=$(echo "$stats" | awk '{print $1}')
    stddev=$(echo "$stats" | awk '{print $2}')

    # Integer-Arithmetik (10000x skaliert)
    local mean_int stddev_int mean_min_int stddev_max_int
    mean_int=$(echo "$mean"   | awk '{printf "%d", $1 * 10000}')
    stddev_int=$(echo "$stddev" | awk '{printf "%d", $1 * 10000}')
    mean_min_int=$(echo "$BLANK_MEAN_MIN"    | awk '{printf "%d", $1 * 10000}')
    stddev_max_int=$(echo "$BLANK_STDDEV_MAX" | awk '{printf "%d", $1 * 10000}')

    local mean_pct stddev_pct
    mean_pct=$(echo "$mean"   | awk '{printf "%.3f%%", $1 * 100}')
    stddev_pct=$(echo "$stddev" | awk '{printf "%.4f", $1}')

    if (( mean_int >= mean_min_int && stddev_int <= stddev_max_int )); then
        log "    -> Leerseite (mean=${mean_pct}, stddev=${stddev_pct} <= ${BLANK_STDDEV_MAX})"
        return 0  # Leer
    fi
    log "    -> Inhalt (mean=${mean_pct}, stddev=${stddev_pct})"
    return 1  # Hat Inhalt
}

# -----------------------------------------------------------------------
# Filtert leere Seiten aus einem Array
# -----------------------------------------------------------------------
filter_blanks() {
    local -n _input=$1
    local -n _output=$2
    local label="$3"

    _output=()
    local removed=0
    local idx=1

    for page in "${_input[@]}"; do
        if is_blank "$page"; then
            log "  Leerseite entfernt: ${label} Seite ${idx} ($(basename "$page"))"
            removed=$(( removed + 1 ))
        else
            _output+=("$page")
        fi
        idx=$(( idx + 1 ))
    done

    if (( removed > 0 )); then
        log "  ${label}: ${removed} Leerseite(n) entfernt -> ${#_output[@]} Seite(n) verbleiben."
    else
        log "  ${label}: Keine Leerseiten gefunden."
    fi
}

# -----------------------------------------------------------------------
# Simplex
# -----------------------------------------------------------------------
if [[ "$MODE" == "simplex" ]]; then
    pages_raw=( $(ls "$SCAN_A"/page_*.pnm 2>/dev/null | sort) )
    log "Simplex: ${#pages_raw[@]} Seite(n) gescannt."

    if [[ "$BLANK_DETECT" == "1" ]]; then
        filter_blanks pages_raw pages_final "Simplex"
    else
        pages_final=( "${pages_raw[@]}" )
    fi

    if [[ ${#pages_final[@]} -eq 0 ]]; then
        logE "Alle Seiten leer - kein PDF erstellt."
        exit 1
    fi

    log "Simplex: ${#pages_final[@]} Seite(n) -> ${OUTFILE}"
    img2pdf "${pages_final[@]}" -o "$OUTFILE"

# -----------------------------------------------------------------------
# Duplex
# -----------------------------------------------------------------------
elif [[ "$MODE" == "duplex" ]]; then
    pages_a_raw=( $(ls "$SCAN_A"/page_*.pnm 2>/dev/null | sort) )
    pages_b_raw=( $(ls "$SCAN_B"/page_*.pnm 2>/dev/null | sort) )

    count_a=${#pages_a_raw[@]}
    count_b=${#pages_b_raw[@]}
    log "Duplex: Scan-A=${count_a} Seite(n), Scan-B=${count_b} Seite(n)"

    # Scan B umkehren
    pages_b_rev=()
    for (( i=${#pages_b_raw[@]}-1; i>=0; i-- )); do
        pages_b_rev+=("${pages_b_raw[$i]}")
    done

    # Interleave
    merged_raw=()
    max=$(( count_a > count_b ? count_a : count_b ))
    for (( i=0; i<max; i++ )); do
        [[ $i -lt $count_a ]] && merged_raw+=("${pages_a_raw[$i]}")
        [[ $i -lt $count_b ]] && merged_raw+=("${pages_b_rev[$i]}")
    done

    log "Interleaved: ${#merged_raw[@]} Seiten gesamt."
    [[ $count_a -ne $count_b ]] && log "HINWEIS: Unterschiedliche Seitenzahl (A=${count_a}, B=${count_b})."

    if [[ "$BLANK_DETECT" == "1" ]]; then
        filter_blanks merged_raw pages_final "Duplex"
    else
        pages_final=( "${merged_raw[@]}" )
    fi

    if [[ ${#pages_final[@]} -eq 0 ]]; then
        logE "Alle Seiten leer - kein PDF erstellt."
        exit 1
    fi

    log "Duplex: ${#pages_final[@]} Seite(n) -> ${OUTFILE}"
    img2pdf "${pages_final[@]}" -o "$OUTFILE"

else
    logE "Unbekannter Modus: $MODE"
    exit 1
fi

if [[ $? -ne 0 ]]; then
    logE "img2pdf fehlgeschlagen."
    exit 1
fi

chmod 666 "$OUTFILE"
SIZE=$(du -h "$OUTFILE" | cut -f1)
log "Fertig: ${OUTFILE} (${SIZE})"