# راهنمای PgNode Standalone

این راهنما برای سرورهایی است که باید قبل از نصب `pg-node` از میرورهای ایرانی APT و Docker استفاده کنند.

## فایل‌های اصلی بسته

- `pg-node.sh`
- `iran-sanction/pg-node-standalone.sh`
- `iran-sanction/mirror.sh`
- `lib/`
- `docker-compose/node.yml`
- `pg-node-assets/.env.example`

## مرحله ۱: دریافت بسته

### سناریو ۱: سرور به GitHub دسترسی دارد

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

فایل انتشار را روی یک سیستم دیگر دانلود کنید، سپس با `scp`، SFTP، پنل یا هر روش انتقال فایل دیگر آن را به سرور منتقل کنید.

```bash
tar -xzf pg-node-standalone.tar.gz
cd pg-node-standalone
```

## مرحله ۲: اجرای نصب

بعد از استخراج بسته روی سرور:

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

- در حالت standalone، اسکریپت برای Ubuntu/Debian با `apt-get` در نظر گرفته شده است.
- در حالت standalone، مدیریت سرویس systemd برای `pg-node` غیرفعال است.
- دستور `pg-node update` فقط کانتینر/ایمیج را به‌روزرسانی می‌کند و خود اسکریپت standalone را آپدیت نمی‌کند.
