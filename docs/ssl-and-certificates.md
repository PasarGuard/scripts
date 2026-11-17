# PasarGuard SSL/TLS & Certificate Guide

Guide to securing the PasarGuard Panel and communication between the Panel and remote Nodes using SSL/TLS certificates.

---

## Table of Contents
- [Panel SSL Modes](#panel-ssl-modes)
  - [1. Let's Encrypt Domain (ACME HTTP-01)](#1-lets-encrypt-domain-acme-http-01)
  - [2. Let's Encrypt IP Certificate](#2-lets-encrypt-ip-certificate)
  - [3. Custom SSL Certificate & Key](#3-custom-ssl-certificate--key)
  - [4. No SSL (Reverse Proxy Fronting)](#4-no-ssl-reverse-proxy-fronting)
- [Node TLS Certificates](#node-tls-certificates)
  - [Self-Signed Certificate Generation](#self-signed-certificate-generation)
  - [Subject Alternative Names (SAN)](#subject-alternative-names-san)
  - [Certificate Verification Levels](#certificate-verification-levels)
  - [Certificate Renewal (`renew-cert`)](#certificate-renewal-renew-cert)
  - [Expiration Monitoring](#expiration-monitoring)

---

## Panel SSL Modes

During `pasarguard install`, you are prompted to configure HTTPS for the web dashboard. You can choose from four modes:

### 1. Let's Encrypt Domain (ACME HTTP-01)
Automatically issues a free, trusted Let's Encrypt certificate using `acme.sh`.

**Prerequisites**:
- A valid domain name with an `A` record pointing to your server IP.
- Port `80` must be accessible from the internet for the ACME HTTP-01 challenge.

**Non-Interactive Flags**:
```bash
sudo pasarguard install --ssl-domain panel.example.com --ssl-http-port 80
```

`acme.sh` installs certificates into:
- `/var/lib/pasarguard/certs/`
- Configures automatic cron renewal.
- Sets environment variables in `/opt/pasarguard/.env`:
  ```env
  UVICORN_SSL_CERTFILE="/var/lib/pasarguard/certs/fullchain.pem"
  UVICORN_SSL_KEYFILE="/var/lib/pasarguard/certs/key.pem"
  UVICORN_SSL_CA_TYPE="letsencrypt"
  ```

---

### 2. Let's Encrypt IP Certificate
If you do not own a domain name, PasarGuard supports issuing short-lived Let's Encrypt certificates directly for the public IP address.
- Valid for public IPv4 addresses.
- Auto-renewed via ACME.

---

### 3. Custom SSL Certificate & Key
If you already possess a certificate from a commercial Certificate Authority (or Cloudflare Origin CA):

1. Copy your certificate chain and private key onto the host:
   ```bash
   cp my-cert.crt /var/lib/pasarguard/certs/custom_cert.pem
   cp my-key.key /var/lib/pasarguard/certs/custom_key.pem
   chmod 600 /var/lib/pasarguard/certs/custom_key.pem
   ```
2. Set the paths in `/opt/pasarguard/.env`:
   ```env
   UVICORN_SSL_CERTFILE="/var/lib/pasarguard/certs/custom_cert.pem"
   UVICORN_SSL_KEYFILE="/var/lib/pasarguard/certs/custom_key.pem"
   UVICORN_SSL_CA_TYPE="custom"
   ```
3. Restart the panel:
   ```bash
   sudo pasarguard restart
   ```

---

### 4. No SSL (Reverse Proxy Fronting)
To run PasarGuard behind an external reverse proxy (like Nginx, Caddy, Cloudflare Tunnel, or Traefik):
```bash
sudo pasarguard install --no-ssl
```
- Disables internal TLS termination in Uvicorn.
- The panel listens on HTTP, allowing your front-end reverse proxy to terminate SSL.

---

## Node TLS Certificates

Worker nodes (`pg-node`) communicate with the central panel over encrypted gRPC or REST channels.

New installs default to Let's Encrypt IP certificates; unattended installs require
`--ssl-ip YOUR_PUBLIC_IPV4` (optionally `--ssl-ipv6`). Use `--ssl-domain DOMAIN`,
paired `--cert-path`/`--key-path`, or `--self-signed` for another source.
`--no-ssl` requires a private backend behind an external TLS web server; configure
the panel with the web server's TLS endpoints for both node and maintenance requests.
See [the node TLS deployment guide](https://github.com/PasarGuard/node/blob/main/docs/node-tls.md)
for routing, renewal, verification, and rollback details.

### Self-Signed Certificate Generation
Nodes can generate their own self-signed certificates with a single flag:
```bash
sudo pg-node install --self-signed
```

This creates an EC or RSA private key and a self-signed X.509 certificate under:
```
/var/lib/pg-node/certs/ssl_cert.pem
/var/lib/pg-node/certs/ssl_key.pem
```
File permissions on private keys are automatically hardened to `0600`.

### Subject Alternative Names (SAN)
To prevent hostname mismatch errors when connecting to the node, PasarGuard adds both IP and DNS SAN entries:
```bash
sudo pg-node install --self-signed --san-entries "198.51.100.2,node1.example.com"
```

PasarGuard automatically normalizes entries to OpenSSL format (`IP:198.51.100.2, DNS:node1.example.com`).

### Certificate Verification Levels
The `pg-node-service` daemon inspects certificates upon startup using OpenSSL syntax and subject-versus-issuer comparison:
- **CA-Signed / Differing Subject and Issuer (`0`)**: Issuer does not match Subject. Uses server TLS without requesting client certificates (`verify=0`); API-key authentication remains required.
- **Self-Signed (`2`)**: Issuer matches Subject. Uses server TLS without requesting client certificates (`verify=0`); API-key authentication remains required.
- **Invalid / Unreadable (`1`)**: Missing file or invalid certificate syntax. The service logs an error and halts startup (fails closed) by default. Insecure operation requires an explicit opt-in (`ALLOW_INSECURE_TLS=true`) before relaxed verification (`verify=0`) is permitted.

### Certificate Renewal (`renew-cert`)
To renew or validate a node certificate according to its saved source:
```bash
sudo pg-node renew-cert
```
ACME sources renew through acme.sh. Self-signed sources regenerate only when you
explicitly run `renew-cert`, preserving the 3,650-day lifetime and installed SANs.
The command prints the new fingerprint: update the saved panel pin. Established
connections continue, but new pinned connections fail until the pin matches.
Custom and legacy sources validate the operator-maintained files. External TLS
certificates and graceful frontend reloads remain managed on the web server.

Certificate deployment preserves configured file paths and container mappings,
sends SIGHUP to the Compose `node` process and the systemd maintenance main
process, and verifies their fingerprints through fresh TLS handshakes. Only an
installed maintenance service is checked. Success requires all deployed endpoints
to match. Reload failures retain previous file backups (`.previous`) and retry the
reload without issuance. There is no automatic restart fallback.

**Rollout prerequisite:** first upgrade both node and node-serviced to versions
supporting certificate reload on SIGHUP. That initial software upgrade requires a
restart. Enabling hooks against older versions can terminate them on SIGHUP.
After the upgrade, enable or migrate an existing managed ACME installation:

```bash
sudo pg-node certificate-renewal-enable
sudo pg-node certificate-status
sudo pg-node certificate-status --json
```

New managed ACME installations register one per-instance cron entry. It ticks
every five minutes and checks normal renewal eligibility hourly. Certificate
storage is isolated under `$DATA_DIR/certs/acme`, outside the shared ACME cron
scan. Migration copies this certificate's existing ACME directory before disabling
its old shared renewal entry; unrelated certificates and cron jobs stay intact.
The fallback renewal time is two thirds of the issued lifetime. The scheduler
updates only the isolated domain configuration with this fallback, clearing the
old fixed-day setting so supported acme.sh CA renewal guidance can take precedence. Transient failures retry with exponential backoff and jitter
from five minutes up to one hour, honoring longer reported Retry-After delays.
Configuration rejections suspend issuance until `.env` or source metadata changes,
or an operator runs `renew-cert` to retry explicitly. Self-signed, custom, and
external certificates are never regenerated by scheduled jobs.

Atomic local state lives in `$DATA_DIR/certs/renewal-status.json`; private ACME
diagnostics are in `acme-last-attempt.log`, alongside `renewal.log`. These remain
available without panel connectivity. Status distinguishes the last verified
active fingerprint from the files currently on disk, reports current file date
validity separately, and never treats a past successful reload as proof that an
expired file is still valid. Use `show-cert` for identity, fingerprint and legacy
PEM output. For custom replacements, place the complete matching pair at the
configured paths before invoking `renew-cert`.

### Expiration Monitoring
During startup, `pg-node-service` inspects the certificate validity window for CA-signed certificates (where Subject and Issuer differ):
- Calculates and logs the remaining days until expiration (or logs a warning if the certificate has already expired) to `journalctl -u pg-node-service`.
- Self-signed and invalid certificates return before this expiration check.
- Note: This check executes only during daemon startup rather than in a continuous background monitoring loop.
