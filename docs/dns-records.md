# DNS records

When you add a domain in Brevo (**Senders, Domains and dedicated IPs ->
Domains -> Add a domain**) it lists two groups of records: *Authentication*
and *Branding*. Brevo may not mark the domain as verified until both groups
resolve; see the branding section before adding that group.

Replace `example.com` with each real sending domain. Brevo derives the DKIM
target from the domain with dots turned into dashes
(`example.com` -> `example-com`), but always copy the values Brevo shows you.

## Add: authentication records

| Type | Host | Value |
| --- | --- | --- |
| TXT | `@` | `brevo-code:<value from Brevo>` |
| CNAME | `brevo1._domainkey` | `b1.example-com.dkim.brevo.com` |
| CNAME | `brevo2._domainkey` | `b2.example-com.dkim.brevo.com` |

BIND zone-file form (note the trailing dots on CNAME targets):

```
@                   IN TXT    "brevo-code:<value from Brevo>"
brevo1._domainkey   IN CNAME  b1.example-com.dkim.brevo.com.
brevo2._domainkey   IN CNAME  b2.example-com.dkim.brevo.com.
```

- The `brevo-code` TXT coexists with any other TXT records at the apex,
  including SPF. Only `v=spf1` records are limited to one per name.
- The DKIM CNAMEs let Brevo sign relayed mail as your domain. They coexist
  with iRedMail's own DKIM record (a different selector, usually `dkim`), so a
  relayed message can carry both signatures.

## DMARC: keep yours if you have one

A domain may have only **one** `_dmarc` TXT record. Check first:

```
nslookup -type=TXT _dmarc.example.com
```

- **None exists:** add the one Brevo suggests:
  `_dmarc  IN TXT  "v=DMARC1; p=none; rua=mailto:rua@dmarc.brevo.com"`
- **One exists:** keep it. Brevo only checks that *a* DMARC record exists.

If your policy is strict (`p=reject` or `p=quarantine`, especially with
`aspf=s`), treat Brevo's DKIM signature as the only thing that makes relayed
mail pass DMARC. Brevo normally uses its own bounce (Return-Path) domain, so
SPF usually won't align with your From: domain. The two DKIM CNAMEs are then
mandatory, not optional; without them Microsoft will reject the relayed mail.

## SPF: merge, don't add

Brevo doesn't require an SPF change, but adding its include is harmless and
covers any receiver that checks SPF against your domain. Edit your **existing**
SPF record and keep its qualifier:

```
before:  v=spf1 mx ip4:203.0.113.10 -all
after:   v=spf1 mx ip4:203.0.113.10 include:spf.brevo.com -all
```

Never add a second `v=spf1` record; two SPF records is a permanent error and
breaks SPF for all your mail. If the domain has no SPF record yet,
`v=spf1 mx include:spf.brevo.com ~all` is a reasonable start (`mx`
authorizes whatever IP your MX host resolves to).

## Branding records: only if `mail.<domain>` is free

Brevo also lists three CNAMEs (`mail`, `r.mail`, `img.mail`) for branded
tracking links. They don't affect relaying itself, but without them Brevo may
leave the domain unverified. In that case it rejects mail from any From address
you haven't added and verified individually under **Senders** ("the sender you
used ... is not valid").

First check whether the `mail` name is already in use:

```
nslookup mail.example.com 8.8.8.8
```

- **It doesn't exist:** add all three CNAMEs. The whole domain becomes
  verified and any address on it can send.
- **It exists (e.g. it's your mail server):** don't add them. A CNAME can't
  coexist with the A record there, and replacing it breaks inbound mail for
  every domain whose MX points at that host. Instead, add and verify each From
  address your users send as under **Senders**.

## Verify

After publishing (and bumping the zone serial on self-hosted DNS):

```
nslookup -type=TXT   example.com 8.8.8.8
nslookup -type=CNAME brevo1._domainkey.example.com 8.8.8.8
nslookup -type=CNAME brevo2._domainkey.example.com 8.8.8.8
nslookup -type=TXT   _dmarc.example.com 8.8.8.8
```

Once those resolve, click **Authenticate this domain** in Brevo. To check the
full result end to end, send a relayed message to https://www.mail-tester.com/
and confirm DKIM (`d=example.com`, selector `brevo1`) and DMARC both pass.
