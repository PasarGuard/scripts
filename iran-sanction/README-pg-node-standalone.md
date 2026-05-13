# PgNode Standalone

This bundle is for servers that should use Iranian APT and Docker mirrors before installing the node.

Files included in the release bundle:

- `pg-node.sh`
- `iran-sanction/pg-node-standalone.sh`
- `iran-sanction/mirror.sh`
- `lib/`
- `docker-compose/node.yml`
- `pg-node-assets/.env.example`

## Step 1: Get The Bundle

### Scenario 1: Server Can Reach GitHub

Download the release archive directly on the server, then extract and run it:

```bash
curl -LO https://github.com/PasarGuard/scripts/releases/download/<tag>/pg-node-standalone.tar.gz
tar -xzf pg-node-standalone.tar.gz
cd pg-node-standalone
chmod +x iran-sanction/pg-node-standalone.sh
./iran-sanction/pg-node-standalone.sh install-script
pg-node install
```

Replace `<tag>` with the release tag you want.

### Scenario 2: Server Cannot Reach GitHub

Download the release archive on another machine, upload it to the server manually with `scp`, SFTP, your panel, or any other file transfer method, then extract and run it:

```bash
tar -xzf pg-node-standalone.tar.gz
cd pg-node-standalone
```

## Step 2: Run The Installer

After the bundle is extracted on the server:

```bash
chmod +x iran-sanction/pg-node-standalone.sh
./iran-sanction/pg-node-standalone.sh install-script
pg-node install
```

`install-script` installs the standalone launcher to `/usr/local/bin/pg-node` and copies its support files to:

```bash
/usr/local/lib/pasarguard-scripts/pg-node-standalone
```

## Notes

- This standalone mode disables node systemd service management.
- `pg-node update` updates the node container/image only. It does not self-update the script.
- The script expects an Ubuntu/Debian server with `apt-get`.
