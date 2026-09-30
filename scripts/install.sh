#!/usr/bin/env bash
# install.sh - idempotent installer for the Brevo smarthost relay.
#
# Run on the iRedMail / Postfix mail VM as root.
#
# Usage:
#   sudo bash scripts/install.sh             # install / update
#   sudo bash scripts/install.sh --uninstall # remove

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
POSTFIX_DIR="/etc/postfix"
MAIN_CF="${POSTFIX_DIR}/main.cf"
SNIPPET="${REPO_DIR}/postfix/main.cf.snippet"
TRANSPORT_SRC="${REPO_DIR}/postfix/transport_brevo"
TRANSPORT_DST="${POSTFIX_DIR}/transport_brevo"
TLS_SRC="${REPO_DIR}/postfix/tls_policy"
TLS_DST="${POSTFIX_DIR}/tls_policy"
SASL_DST="${POSTFIX_DIR}/sasl_passwd"
SASL_EXAMPLE="${REPO_DIR}/postfix/sasl_passwd.example"
CRON_DST="/etc/cron.d/smtp-forwarder-autopromote"

BEGIN_MARKER="# --- BEGIN claude-3-alternate-smtp-forwarder ---"
END_MARKER="# --- END claude-3-alternate-smtp-forwarder ---"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[install] $*"; }

require_root() {
    [ "$(id -u)" = "0" ] || die "this script must run as root (use sudo)"
}

require_postfix() {
    command -v postconf >/dev/null || die "postconf not found - is Postfix installed?"
    command -v postmap  >/dev/null || die "postmap not found - is Postfix installed?"
}

require_sasl_modules() {
    # Without the Cyrus PLAIN/LOGIN plugins, Postfix fails with
    # "no mechanism available" when authenticating to the relay.
    if command -v dpkg >/dev/null && ! dpkg -s libsasl2-modules >/dev/null 2>&1; then
        die "libsasl2-modules is not installed: apt install -y libsasl2-modules"
    fi
}

backup_main_cf_once() {
    local first_backup_glob="${MAIN_CF}.bak.*"
    # only create a backup if there isn't already one from us
    if ! compgen -G "${first_backup_glob}" > /dev/null; then
        local ts="$(date +%s)"
        cp -a "${MAIN_CF}" "${MAIN_CF}.bak.${ts}"
        log "backed up main.cf -> ${MAIN_CF}.bak.${ts}"
    fi
}

remove_block() {
    # remove the BEGIN/END block from main.cf if present
    if grep -qF "${BEGIN_MARKER}" "${MAIN_CF}"; then
        sed -i "/^${BEGIN_MARKER}\$/,/^${END_MARKER}\$/d" "${MAIN_CF}"
        log "removed existing managed block from main.cf"
    fi
}

append_block() {
    [ -z "$(tail -c1 "${MAIN_CF}")" ] || echo "" >> "${MAIN_CF}"
    cat "${SNIPPET}" >> "${MAIN_CF}"
    log "appended managed block to main.cf"
}

add_our_transport_map() {
    # Edit the existing line in place rather than redefining transport_maps:
    # a second definition works but makes every Postfix process log
    # "overriding earlier entry". Must run after remove_block, which strips
    # the duplicate definition older versions of this script wrote. Ours goes
    # last so hosted-domain routing (iRedMail's SQL maps) always wins.
    local current
    current="$(postconf -h transport_maps)"
    case " ${current//,/ } " in
        *" hash:${TRANSPORT_DST} "*)
            log "transport_maps already includes hash:${TRANSPORT_DST}" ;;
        *)
            postconf -e "transport_maps = ${current:+${current} }hash:${TRANSPORT_DST}"
            log "transport_maps = $(postconf -h transport_maps)" ;;
    esac
}

remove_our_transport_map() {
    local current remaining
    current="$(postconf -h transport_maps)"
    case " ${current//,/ } " in
        *" hash:${TRANSPORT_DST} "*) ;;
        *) return 0 ;;
    esac
    remaining="$(printf '%s\n' "${current}" | tr ', ' '\n\n' | grep -v '^$' \
                 | grep -vxF "hash:${TRANSPORT_DST}" | paste -sd' ' -)" || true
    if [ -n "${remaining}" ]; then
        postconf -e "transport_maps = ${remaining}"
    else
        postconf -X transport_maps
    fi
    log "removed hash:${TRANSPORT_DST} from transport_maps"
}

install_transport_map() {
    if [ ! -f "${TRANSPORT_DST}" ]; then
        install -m 0644 "${TRANSPORT_SRC}" "${TRANSPORT_DST}"
        log "installed ${TRANSPORT_DST}"
    else
        # Keep the server's copy (it holds auto-promoted domains); only add
        # repo entries whose domain it doesn't already list.
        local missing
        missing="$(awk 'NR==FNR { if (NF && $1 !~ /^#/) have[tolower($1)]=1; next }
                        NF && $1 !~ /^#/ && !(tolower($1) in have)' \
                        "${TRANSPORT_DST}" "${TRANSPORT_SRC}")"
        if [ -n "${missing}" ]; then
            printf '%s\n' "${missing}" >> "${TRANSPORT_DST}"
            log "added $(printf '%s\n' "${missing}" | wc -l) new repo entries to ${TRANSPORT_DST}"
        else
            log "${TRANSPORT_DST} already has every repo entry; left as is"
        fi
    fi
    postmap "${TRANSPORT_DST}"
}

install_map() {
    local src="$1" dst="$2"
    install -m 0644 "${src}" "${dst}"
    postmap "${dst}"
    log "installed and postmap'd ${dst}"
}

ensure_sasl_passwd() {
    if [ ! -f "${SASL_DST}" ]; then
        log "no ${SASL_DST} found"
        log "copy ${SASL_EXAMPLE} to ${SASL_DST}, edit it with your Brevo creds, chmod 600, then re-run."
        die "missing /etc/postfix/sasl_passwd"
    fi

    if grep -q "YOUR_BREVO_LOGIN" "${SASL_DST}"; then
        die "${SASL_DST} still has placeholder values - edit it before installing"
    fi

    chmod 600 "${SASL_DST}"
    postmap "${SASL_DST}"
    log "postmap'd ${SASL_DST}"
}

install_cron() {
    cat > "${CRON_DST}" <<EOF
# Auto-promote O365 custom recipient domains in the Postfix deferred queue.
# Generated by claude-3-alternate-smtp-forwarder/scripts/install.sh
SHELL=/bin/bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin
*/15 * * * * root ${REPO_DIR}/scripts/auto-promote.sh >> /var/log/smtp-forwarder-autopromote.log 2>&1
EOF
    chmod 644 "${CRON_DST}"
    log "installed cron at ${CRON_DST}"
}

remove_cron() {
    if [ -f "${CRON_DST}" ]; then
        rm -f "${CRON_DST}"
        log "removed cron at ${CRON_DST}"
    fi
}

reload_postfix() {
    if systemctl is-active --quiet postfix; then
        postfix reload
        log "reloaded Postfix"
    else
        log "Postfix not running; not reloading. Start it with: systemctl start postfix"
    fi
}

install_action() {
    require_root
    require_postfix
    require_sasl_modules
    ensure_sasl_passwd

    backup_main_cf_once
    remove_block
    add_our_transport_map
    append_block

    install_transport_map
    install_map "${TLS_SRC}" "${TLS_DST}"

    install_cron
    reload_postfix

    log "done. Verify with: postmap -q outlook.com hash:${TRANSPORT_DST}"
    log "expected output: relay:[smtp-relay.brevo.com]:587"
}

uninstall_action() {
    require_root
    require_postfix

    backup_main_cf_once
    remove_block
    remove_our_transport_map
    remove_cron
    reload_postfix

    log "removed managed block from main.cf and cron file."
    log "left in place (delete manually if desired):"
    log "  ${TRANSPORT_DST}{,.db}"
    log "  ${TLS_DST}{,.db}"
    log "  ${SASL_DST}{,.db}"
}

case "${1:-install}" in
    install)
        install_action ;;
    --uninstall|uninstall)
        uninstall_action ;;
    *)
        die "unknown argument: $1 (use no arg to install, or --uninstall)" ;;
esac
