#!/usr/bin/env bash
# install.sh — install or update frigate-archive.
#
#   sudo ./install.sh [--prefix /usr/local] [--www-dir DIR] [--enable] [--no-systemd]
#   sudo ./install.sh --uninstall [--prefix /usr/local] [--www-dir DIR]
#
# Re-running updates in place. Files are copied (not symlinked): `install` writes each file
# fresh, so a sync that's mid-run keeps executing the old copy instead of reading a
# half-updated script. Your config and the archive itself are never touched.

set -euo pipefail

PREFIX=/usr/local
WWW_DIR=
ENABLE=0
SYSTEMD=1
UNINSTALL=0
CONF_DIR=/etc/frigate-archive
UNIT_DIR=/etc/systemd/system

while [[ $# -gt 0 ]]; do
    case $1 in
        --prefix)     PREFIX=$2; shift 2 ;;
        --www-dir)    WWW_DIR=$2; shift 2 ;;
        --enable)     ENABLE=1; shift ;;
        --no-systemd) SYSTEMD=0; shift ;;
        --uninstall)  UNINSTALL=1; shift ;;
        -h|--help)    sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

BIN_DIR=$PREFIX/bin
DOC_DIR=$PREFIX/share/doc/frigate-archive
WWW_DIR=${WWW_DIR:-$PREFIX/share/frigate-archive/www}
HERE=$(cd "$(dirname "$0")" && pwd)
UNITS=(frigate-archive.service frigate-archive.timer frigate-timelapse.service frigate-timelapse.timer
       frigate-archive-export.service)

if [[ $UNINSTALL == 1 ]]; then
    if [[ $SYSTEMD == 1 ]]; then
        systemctl disable --now frigate-archive.timer frigate-timelapse.timer frigate-archive-export.service 2>/dev/null || true
        for u in "${UNITS[@]}"; do rm -f "$UNIT_DIR/$u"; done
        rm -rf "$UNIT_DIR/frigate-timelapse.timer.d/frigate-archive-tz.conf"
        rmdir "$UNIT_DIR/frigate-timelapse.timer.d" 2>/dev/null || true
        systemctl daemon-reload
    fi
    rm -f "$BIN_DIR/frigate-archive" "$BIN_DIR/frigate-archive-tool" "$BIN_DIR/frigate-clip"
    rm -rf "$WWW_DIR" "$DOC_DIR"
    echo "uninstalled. Kept: $CONF_DIR/ and the archive itself."
    exit 0
fi

for dep in python3 ffmpeg ffprobe rsync flock; do
    command -v "$dep" >/dev/null || echo "warning: $dep not found — install it before running" >&2
done

# programs (replace any old symlinks rather than writing through them)
for f in frigate-archive frigate-archive-tool; do
    [[ -L $BIN_DIR/$f ]] && rm -f "$BIN_DIR/$f"
    install -D -m 755 "$HERE/bin/$f" "$BIN_DIR/$f"
done
ln -sfn frigate-archive-tool "$BIN_DIR/frigate-clip"

install -D -m 644 "$HERE/www/index.html" "$WWW_DIR/index.html"
install -D -m 644 "$HERE/README.md" "$DOC_DIR/README.md"
install -D -m 644 "$HERE/frigate-archive.conf.example" "$DOC_DIR/frigate-archive.conf.example"
install -D -m 644 "$HERE/contrib/nginx-archive.conf" "$DOC_DIR/nginx-archive.conf"
install -D -m 644 "$HERE/contrib/crontab" "$DOC_DIR/crontab.example"

# config: never overwrite an existing one
CONF=$CONF_DIR/frigate-archive.conf
if [[ ! -f $CONF ]]; then
    install -D -m 600 "$HERE/frigate-archive.conf.example" "$CONF"
    echo "created $CONF — edit it before enabling"
else
    missing=$(comm -23 <(grep -oE '^[A-Z_]+' "$HERE/frigate-archive.conf.example" | sort -u) \
                       <(sed -nE 's/^[[:space:]]*([A-Z_][A-Z0-9_]*)=.*/\1/p' "$CONF" | sort -u) | paste -sd' ')
    [[ -z $missing ]] || echo "note: not set in $CONF (defaults apply): $missing"
fi

if [[ $SYSTEMD == 1 ]]; then
    for u in "${UNITS[@]}"; do
        sed -e "s|@BINDIR@|$BIN_DIR|g" -e "s|@DOCDIR@|$DOC_DIR|g" "$HERE/systemd/$u" > "$UNIT_DIR/.$u.tmp"
        mv "$UNIT_DIR/.$u.tmp" "$UNIT_DIR/$u"
        chmod 644 "$UNIT_DIR/$u"
    done
    # schedule the nightly timelapse in the configured timezone, if it isn't the system's
    tz=$(FRIGATE_ARCHIVE_CONF=$CONF bash -c 'source <(grep -E "^TZ=" "$FRIGATE_ARCHIVE_CONF"); echo "${TZ:-}"' 2>/dev/null || true)
    dropin=$UNIT_DIR/frigate-timelapse.timer.d/frigate-archive-tz.conf
    if [[ -n $tz ]]; then
        mkdir -p "$(dirname "$dropin")"
        printf '# written by frigate-archive install.sh from TZ in %s\n[Timer]\nOnCalendar=\nOnCalendar=*-*-* 01:30 %s\n' \
            "$CONF" "$tz" > "$dropin"
    else
        rm -f "$dropin"
    fi
    systemctl daemon-reload
    if [[ $ENABLE == 1 ]]; then
        systemctl enable --now frigate-archive.timer frigate-timelapse.timer frigate-archive-export.service
    fi
    # pick up the new code if the export API is already running (a running export is re-queued)
    systemctl try-restart frigate-archive-export.service
fi

cat <<EOF
installed to $PREFIX (page: $WWW_DIR)
next:
  1. edit $CONF
  2. mount the archive and: touch <ARCHIVE>/.frigate-archive
  3. frigate-archive-tool check
  4. systemctl enable --now frigate-archive.timer frigate-timelapse.timer   (or re-run with --enable)
  5. optional review page: see $DOC_DIR/nginx-archive.conf
  6. optional exports from the page: systemctl enable --now frigate-archive-export.service
EOF
