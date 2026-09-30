# Postfix changes

The installer makes two edits to `/etc/postfix/main.cf`.

1. It appends `hash:/etc/postfix/transport_brevo` to the **existing**
   `transport_maps` line, in place. On an iRedMail (PostgreSQL backend)
   server the result is:

   ```
   transport_maps = proxy:pgsql:/etc/postfix/pgsql/transport_maps_user.cf proxy:pgsql:/etc/postfix/pgsql/transport_maps_maillist.cf proxy:pgsql:/etc/postfix/pgsql/transport_maps_domain.cf hash:/etc/postfix/transport_brevo
   ```

2. It appends one managed block to the end of the file:

```
# --- BEGIN claude-3-alternate-smtp-forwarder ---
# ...

smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_sasl_mechanism_filter = plain, login

smtp_tls_policy_maps = hash:/etc/postfix/tls_policy

# --- END claude-3-alternate-smtp-forwarder ---
```

Notes for anyone reading this later:

- **`transport_maps` is extended, not replaced.** iRedMail already defines
  `transport_maps` (SQL or LDAP lookups that route hosted domains to Dovecot
  and mailing lists to mlmmj). The installer appends our map to that line
  with `postconf -e`, so there is still exactly one definition. (A second
  definition later in the file would also work, but every Postfix process
  would then log `overriding earlier entry` warnings.) iRedMail's maps come
  first, so hosted-domain routing always wins; ours only answers for domains
  the SQL maps don't know about.
- If an iRedMail upgrade rewrites its `transport_maps` line, ours is dropped
  and Microsoft-bound mail goes direct again. **Re-run `install.sh` after an
  iRedMail upgrade.**
- We do **not** set `relayhost`. That would force *every* outbound message
  through the smarthost.
- `smtp_sasl_password_maps` is keyed by next-hop. Postfix only presents the
  Brevo SMTP key when the next-hop is `[smtp-relay.brevo.com]:587`, so direct
  deliveries never see the credentials.
- `smtp_tls_policy_maps` pins the Brevo next-hop to `encrypt`. The global
  `smtp_tls_security_level` (iRedMail sets `may`) is left alone, so direct
  deliveries still work with hosts that don't offer TLS.
- Postfix needs the Cyrus SASL plugins to authenticate as a client:
  `apt install -y libsasl2-modules`. The installer refuses to run without it.

## Files written by the installer

| Path | Mode | Tracked in git | Purpose |
| --- | --- | --- | --- |
| `/etc/postfix/transport_brevo` | 644 | yes (template) | Recipient-domain -> relay map |
| `/etc/postfix/transport_brevo.db` | 644 | no | `postmap` output |
| `/etc/postfix/sasl_passwd` | 600 | **no** | SASL credentials (your Brevo key) |
| `/etc/postfix/sasl_passwd.db` | 600 | no | `postmap` output |
| `/etc/postfix/tls_policy` | 644 | yes | TLS policy for Brevo next-hop |
| `/etc/postfix/tls_policy.db` | 644 | no | `postmap` output |
| `/etc/cron.d/smtp-forwarder-autopromote` | 644 | no (generated) | 15-min auto-promote cron |

`/etc/postfix/transport_brevo` is only copied from the repo on the first
install. After that the server's copy is authoritative (it accumulates
domains from `auto-promote.sh` / `add-o365-domain.sh`); re-running the
installer only appends repo entries whose domain it doesn't already list. To
remove a domain, edit the server's file and run
`postmap /etc/postfix/transport_brevo && postfix reload`.

## Rolling back

```sh
sudo bash scripts/install.sh --uninstall
```

This removes the managed block from `main.cf`, takes our map back out of
`transport_maps`, removes the cron file, and reloads Postfix. It does **not**
delete the transport map or sasl password file, so reinstalling is one command.

The installer also keeps a timestamped copy of `main.cf` from before its first
edit, at `/etc/postfix/main.cf.bak.<unix-timestamp>`, if you ever need it.
