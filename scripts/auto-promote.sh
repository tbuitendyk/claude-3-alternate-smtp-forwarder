#!/usr/bin/env bash
# auto-promote.sh - find recipient domains hosted on Microsoft 365 that are
# still delivered direct, append them to the Brevo transport map, and retry
# the queue so their waiting mail goes out via Brevo.
#
# Candidate domains come from the deferred queue and from mail.log deliveries
# to *.mail.protection.outlook.com that bounced or were deferred (Microsoft's
# IP-block replies are turned into deferrals by microsoft_block_reply_filter).
# Each candidate is confirmed by an MX lookup before it is added.
#
# Designed to run from cron (every 15 minutes is the default in install.sh).
# Idempotent: skips domains already in the transport map.

set -euo pipefail

TRANSPORT_DST="/etc/postfix/transport_brevo"
MAIL_LOG="${MAIL_LOG:-/var/log/mail.log}"
RELAY="relay:[smtp-relay.brevo.com]:587"
O365_MX_PATTERN='\.mail\.protection\.outlook\.com\.?$'

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date -Iseconds)] [auto-promote] $*"; }

[ "$(id -u)" = "0" ] || die "must run as root"
command -v dig         >/dev/null || die "dig not found - apt install dnsutils"
command -v postqueue   >/dev/null || die "postqueue not found"
command -v postmap     >/dev/null || die "postmap not found"
[ -f "${TRANSPORT_DST}" ] || die "${TRANSPORT_DST} not found - run install.sh first"

queued_recipient_domains() {
    if command -v jq >/dev/null; then
        postqueue -j 2>/dev/null \
            | jq -r '(.recipients // [])[].address' 2>/dev/null \
            | awk -F@ 'NF==2 {print $2}'
    else
        # `postqueue -p` lists recipients indented under each message.
        postqueue -p 2>/dev/null \
            | awk '/^[[:space:]]+[^[:space:]]+@[^[:space:]]+[[:space:]]*$/ {
                       gsub(/^[[:space:]]+|[[:space:]]+$/, "");
                       n = split($0, parts, "@");
                       if (n == 2) print parts[2]
                   }'
    fi
}

m365_failed_domains() {
    [ -r "${MAIL_LOG}" ] || return 0
    grep -aE 'status=(bounced|deferred)' "${MAIL_LOG}" \
        | grep -aE 'relay=[^ ,]*\.mail\.protection\.outlook\.com\[' \
        | sed -nE 's/.* to=<[^@>]*@([^>]+)>.*/\1/p' || true
}

candidate_domains() {
    { queued_recipient_domains; m365_failed_domains; } \
        | tr '[:upper:]' '[:lower:]' \
        | grep -E '^[a-z0-9-]+(\.[a-z0-9-]+)+$' \
        | sort -u || true
}

added=0

while read -r domain; do
    [ -n "${domain}" ] || continue

    # Skip if already in the transport map (exact or subdomain wildcard).
    if grep -qiE "^[[:space:]]*\.?${domain//./\\.}[[:space:]]" "${TRANSPORT_DST}"; then
        continue
    fi

    mx="$(dig +short +time=3 +tries=1 MX "${domain}" 2>/dev/null \
            | sort -n | awk '{print tolower($2)}' | head -1 || true)"

    if [ -z "${mx}" ]; then
        continue
    fi

    if echo "${mx}" | grep -qE "${O365_MX_PATTERN}"; then
        ts="$(date -Iseconds)"
        printf '%-25s %s   # auto %s\n' "${domain}" "${RELAY}" "${ts}" >> "${TRANSPORT_DST}"
        log "promoted ${domain} (MX=${mx})"
        added=$((added + 1))
    fi
done < <(candidate_domains)

if [ "${added}" -gt 0 ]; then
    postmap "${TRANSPORT_DST}"
    if systemctl is-active --quiet postfix; then
        postfix reload
        # Retry deferred mail now that the routing has changed.
        postqueue -f
    fi
    log "promoted ${added} domain(s); flushed deferred queue"
    log "mail that already bounced to these domains is not retried - resend it"
fi
