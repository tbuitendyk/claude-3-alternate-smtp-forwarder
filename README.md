# claude-3-alternate-smtp-forwarder

Selectively relay outbound mail from an iRedMail (Postfix) server through a free
upstream SMTP relay (Brevo) **only** for recipients hosted by Microsoft, while
continuing to deliver everything else directly from the existing IP.

## Why

The mail VM ships from an IONOS public IP that Microsoft's filters dislike.
Mail to `@outlook.com`, `@hotmail.com`, `@live.com`, `*.onmicrosoft.com`, and
many Office 365 custom domains gets rejected (S3140 / 5.7.1 / 5.7.606-649).
Other recipients still accept mail from the IONOS IP fine.

Routing only Microsoft-bound mail through a clean third-party relay keeps the
IONOS sender reputation intact for everyone else and stays well within Brevo's
free quota (300/day at signup).

## Topology

```
                                              direct delivery
                          +---- non-Microsoft ----------------------> recipient MX
   app/users -> Postfix --+
                          +---- Microsoft-hosted recipient
                                  |
                                  v
                          smtp-relay.brevo.com:587  (SASL + STARTTLS)
                                  |
                                  v
                              recipient MX
```

The decision is made by Postfix `transport_maps`, which is a hash file mapping
recipient domains to a transport. Domains in the map go to the relay; domains
not in the map fall through to the default transport (direct delivery).

## What's in this repo

```
docs/
  brevo-setup.md         Sign up, verify domains, generate SMTP key
  dns-records.md         SPF + DKIM records you need to add
  postfix-changes.md     Exact main.cf settings the install script writes
postfix/
  main.cf.snippet        The lines added to /etc/postfix/main.cf
  transport_brevo        Recipient-domain -> relay map (consumer M$ domains)
  tls_policy             Require TLS for the Brevo next-hop only
  sasl_passwd.example    Template for SASL credentials (real one is .gitignored)
scripts/
  install.sh             Idempotent installer; copies files, postmap, reload
  add-o365-domain.sh     MX-check a domain; if it's on O365, add to the map
  auto-promote.sh        Cron job: scan deferred queue, auto-add O365 domains
  healthcheck.sh         Send a test message via the Brevo relay
  mailwatch              Live one-line-per-email view of mail in and out
```

## Prerequisites

- Mail VM is Debian with iRedMail (Postfix as MTA).
- You have root or sudo on the mail VM.
- DNS for every sending domain is under your control.
- A Brevo account with every sending domain authenticated (DKIM + DMARC).
- A Brevo SMTP key (login + key from Brevo's "SMTP & API" page).
- Packages: `apt install -y dnsutils jq libsasl2-modules` (the last one is
  required for Postfix to authenticate to the relay).

## Install (on the mail VM)

```sh
# clone this repo onto the mail VM
git clone https://github.com/tbuitendyk/claude-3-alternate-smtp-forwarder.git \
    /opt/claude-3-alternate-smtp-forwarder
cd /opt/claude-3-alternate-smtp-forwarder

# create the real SASL password file from the template
cp postfix/sasl_passwd.example /etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd
$EDITOR /etc/postfix/sasl_passwd          # paste your Brevo login + SMTP key

# run the installer
sudo bash scripts/install.sh
```

The installer is idempotent: rerunning is safe, and it leaves a backup of
`main.cf` at `/etc/postfix/main.cf.bak.<timestamp>` the first time it edits.

It keeps any `transport_maps` already configured (iRedMail's SQL/LDAP maps,
which route mail for hosted domains and mailing lists) and appends ours to
that same line in place. If an iRedMail upgrade rewrites the line, ours is
dropped, so **re-run `install.sh` after an iRedMail upgrade**.

## Verify

```sh
# send a test message to a Microsoft mailbox you control
bash scripts/healthcheck.sh you@outlook.com

# tail the log and confirm the relay path is used
tail -f /var/log/mail.log | grep brevo
# expect: ... relay=smtp-relay.brevo.com[...]:587, ... status=sent
```

## Watching mail activity

```sh
sudo /opt/claude-3-alternate-smtp-forwarder/scripts/mailwatch         # last 20 emails, then live
sudo /opt/claude-3-alternate-smtp-forwarder/scripts/mailwatch -n 50   # start with 50
```

One line per message (timestamp, IN/OUT/LOCAL, sender, receiver, subject),
built from the amavis lines in `/var/log/mail.log`. Mail rejected before it
reaches the spam scanner (e.g. at RCPT time) doesn't appear. Ctrl+C to stop.

## Adding an Office 365 custom domain

Some recipient domains aren't on `*.onmicrosoft.com` but are still hosted on
Microsoft 365. Their MX record points at `*.mail.protection.outlook.com`. The
helper script detects this:

```sh
sudo bash scripts/add-o365-domain.sh customer-domain.example
```

If the MX matches O365, the domain is appended to `/etc/postfix/transport_brevo`
and Postfix is reloaded. If it doesn't, nothing is changed.

A cron job (`scripts/auto-promote.sh`, installed by `install.sh`) does the same
thing every 15 minutes against the *deferred* queue — any domain that's
deferring with a Microsoft-hosted MX gets promoted automatically.

## Reverting

`scripts/install.sh --uninstall` removes the managed block from `main.cf`,
takes our map back out of `transport_maps`, removes the cron job, then reloads
Postfix. The transport map and sasl password files are left in place so you
don't lose your domain list / credentials.

## Volume

Brevo's free tier is 300 messages/day. Only Microsoft-bound mail uses the
quota. If you outgrow it, options:

- Upgrade Brevo, or
- Switch the smarthost to SES / Mailjet / SMTP2GO by changing the next-hop
  (`[smtp-relay.brevo.com]:587`) in `postfix/transport_brevo`,
  `postfix/tls_policy`, the `RELAY` variable in `scripts/add-o365-domain.sh`
  and `scripts/auto-promote.sh`, and `/etc/postfix/sasl_passwd`, then re-run
  `install.sh`.
