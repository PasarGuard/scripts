# راهنمای Pasarguard Standalone

این راهنما برای سرورهایی است که باید قبل از نصب `pasarguard` از میرورهای ایرانی APT و Docker استفاده کنند.

## فایل‌های اصلی بسته

- `pasarguard.sh`
- `iran-sanction/pasarguard-standalone.sh`
- `iran-sanction/mirror.sh`
- `lib/`
- `docker-compose/pasarguard-*.yml`
- `pasarguard-assets/.env.example`

## مرحله ۱: دریافت بسته

### سناریو ۱: سرور به GitHub دسترسی دارد

- لینک مستقیم آخرین فایل انتشار:
  [pasarguard-standalone.tar.gz](https://github.com/PasarGuard/scripts/releases/latest/download/pasarguard-standalone.tar.gz)

```bash
curl -LO https://github.com/PasarGuard/scripts/releases/download/<tag>/pasarguard-standalone.tar.gz
tar -xzf pasarguard-standalone.tar.gz
cd pasarguard-standalone
chmod +x iran-sanction/pasarguard-standalone.sh
./iran-sanction/pasarguard-standalone.sh install-script
pasarguard install --database timescaledb
```

به‌جای `<tag>` تگ نسخه موردنظر را قرار دهید.

### سناریو ۲: سرور به GitHub دسترسی ندارد

فایل انتشار را روی یک سیستم دیگر دانلود کنید، سپس با `scp`، SFTP، پنل یا هر روش انتقال فایل دیگر آن را به سرور منتقل کنید.

- لینک دانلود فایل انتشار برای انتقال به سرور:
  [pasarguard-standalone.tar.gz](https://github.com/PasarGuard/scripts/releases/latest/download/pasarguard-standalone.tar.gz)

```bash
tar -xzf pasarguard-standalone.tar.gz
cd pasarguard-standalone
```

## مرحله ۲: اجرای نصب

بعد از استخراج بسته روی سرور:

```bash
chmod +x iran-sanction/pasarguard-standalone.sh
./iran-sanction/pasarguard-standalone.sh install-script
pasarguard install --database timescaledb
```

اگر بخواهید نوع دیتابیس را مشخص کنید، مثلا:

```bash
pasarguard install --database timescaledb
```

دستور `install-script` لانچر standalone را در مسیر `/usr/local/bin/pasarguard` نصب می‌کند و فایل‌های موردنیاز را در مسیر زیر کپی می‌کند:

```bash
/usr/local/lib/pasarguard-scripts/pasarguard-standalone
```

## نکات

- در حالت standalone، اسکریپت از Ubuntu/Debian با `apt-get` و CentOS/RHEL-compatible systems با `dnf` یا `yum` پشتیبانی می‌کند.
- در حالت standalone، `pasarguard` از فایل‌های آماده `docker-compose` استفاده می‌کند و هنگام نصب نیازی به دانلود فایل compose ندارد.
- دستور `pasarguard update` فقط کانتینر/ایمیج را به‌روزرسانی می‌کند و خود اسکریپت standalone را آپدیت نمی‌کند.
