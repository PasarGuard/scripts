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
The `pg-node-service` daemon inspects certificates upon startup:
- **CA-Signed (`0`)**: Fully trusted certificate signed by a known Certificate Authority. Enforces strict TLS verification (`verify=1`).
- **Self-Signed (`2`)**: Issuer matches Subject. Allows local communication with verification relaxed (`verify=0`).
- **Invalid / Unreadable (`1`)**: Corrupted file or invalid format. Service logs an error and halts execution.

### Certificate Renewal (`renew-cert`)
To regenerate an expired or outdated node certificate:
```bash
sudo pg-node renew-cert
```
This updates the certificate in `/var/lib/pg-node/certs/` and restarts the node container and companion service.

### Expiration Monitoring
The companion service daemon continuously monitors the expiration date of `/var/lib/pg-node/certs/ssl_cert.pem`:
- Emits warnings in `journalctl -u pg-node-service` when certificates are within 30 days of expiry.
- Prevents silent outage from expired node certificates.
