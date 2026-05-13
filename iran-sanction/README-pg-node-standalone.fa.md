# راهنمای PgNode Standalone

این بسته برای سرورهایی است که باید قبل از نصب نود، از میرورهای ایرانی برای APT و Docker استفاده کنند.

فایل‌های موجود در بسته انتشار:

- `pg-node.sh`
- `iran-sanction/pg-node-standalone.sh`
- `iran-sanction/mirror.sh`
- `lib/`
- `docker-compose/node.yml`
- `pg-node-assets/.env.example`

## مرحله ۱: دریافت بسته

### سناریو ۱: سرور به GitHub دسترسی دارد

فایل انتشار را مستقیم روی سرور دانلود کنید، سپس آن را استخراج و اجرا کنید:

```bash
curl -LO https://github.com/PasarGuard/scripts/releases/download/<tag>/pg-node-standalone.tar.gz
tar -xzf pg-node-standalone.tar.gz
cd pg-node-standalone
chmod +x iran-sanction/pg-node-standalone.sh
./iran-sanction/pg-node-standalone.sh install-script
pg-node install
```

به‌جای `<tag>` تگ نسخه موردنظر را قرار دهید.

### سناریو ۲: سرور به GitHub دسترسی ندارد

فایل انتشار را روی یک سیستم دیگر دانلود کنید، سپس با `scp`، SFTP، پنل یا هر روش انتقال فایل دیگر آن را به سرور منتقل کنید. بعد از انتقال:

```bash
tar -xzf pg-node-standalone.tar.gz
cd pg-node-standalone
```

## مرحله ۲: اجرای نصب

بعد از اینکه بسته روی سرور استخراج شد:

```bash
chmod +x iran-sanction/pg-node-standalone.sh
./iran-sanction/pg-node-standalone.sh install-script
pg-node install
```

دستور `install-script` لانچر standalone را در مسیر `/usr/local/bin/pg-node` نصب می‌کند و فایل‌های موردنیاز را در مسیر زیر کپی می‌کند:

```bash
/usr/local/lib/pasarguard-scripts/pg-node-standalone
```

## نکات

- در حالت standalone، مدیریت سرویس systemd برای نود غیرفعال است.
- دستور `pg-node update` فقط ایمیج/کانتینر نود را به‌روزرسانی می‌کند و خود اسکریپت را آپدیت نمی‌کند.
- این اسکریپت برای سرورهای Ubuntu/Debian با `apt-get` در نظر گرفته شده است.
