# HAS_PrepperDisk

**[English](#english) · [Türkçe](#türkçe)**

---

## English

An offline knowledge archive on a Raspberry Pi 5. Wikipedia, maps, medical references and repair guides, served over the Pi's own Wi-Fi hotspot. Any phone or laptop that joins the network can open them in a browser. No internet needed.

Built on [Internet-in-a-Box](https://github.com/iiab/iiab) and [Kiwix](https://kiwix.org). This repo adds a ready-made configuration, helper scripts and a custom homepage.

### Hardware

| Part | Notes |
|---|---|
| Raspberry Pi 5 (4 GB or 8 GB) | |
| M.2 NVMe HAT + NVMe SSD (256 GB+) | Content lives here |
| microSD card (32 GB+) | Operating system |
| 5V/5A USB-C power supply | The official one is recommended |
| Active cooler | The Pi 5 and SSD get warm |
| Ethernet cable | Recommended during install |

### Installation

**1. Operating system.** Use Raspberry Pi Imager to flash **Raspberry Pi OS Lite (64-bit)** to the SD card. In Imager's settings, enable SSH and set a username and password. Boot the Pi with the SSD attached and connect it to your router with Ethernet.

**2. Update and get this repo.**
```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y git
git clone https://github.com/schematrix/HAS_Prepper_Disk.git
cd HAS_Prepper_Disk
chmod +x install.sh scripts/*.sh
```

**3. Mount the SSD at `/library`.** Find the disk name with `lsblk`; it is usually `nvme0n1`. If the disk is not ext4 it will be formatted, and the script asks before doing so.
```bash
sudo ./scripts/setup-ssd.sh /dev/nvme0n1
```

**4. Install.** The script asks for the Wi-Fi name and password, then installs Internet-in-a-Box (30–60 min). **If the Pi reboots or the install stops, run the same command again.** It continues where it left off.
```bash
sudo ./install.sh
```

**5. Download content.** Edit `config/content.conf` to choose what to download, then run the script below. The defaults need about 135 GB, and downloads can take many hours. If a download is interrupted, re-run the script and it resumes.
```bash
sudo ./scripts/download-content.sh
```

**6. Maps.** Open `http://<pi-ip>/admin` (user `iiab-admin`), go to the maps section of the **Install Content** menu and choose the regions you want.

**7. Use it.** Join the Wi-Fi network you created and open **http://box.lan/home**.

### Repo layout

```
install.sh                 main installer
scripts/setup-ssd.sh       mounts the SSD at /library
scripts/download-content.sh  downloads/updates ZIM files from Kiwix
scripts/install-homepage.sh  installs the custom homepage
config/iiab-overrides.yml  Internet-in-a-Box settings
config/content.conf        list of content to download
www/home/index.html        homepage
```

### Troubleshooting

- **`ssh user@hostname.local` stops working after install.** Internet-in-a-Box renames the Pi to `box`. Use `ssh user@box.local` or the Pi's IP address. To find the IP, run `arp -a` on your computer or check your router's device list.
- **Chromium says the profile is locked.** This also comes from the hostname change. Click "Unlock Profile", or run `rm -f ~/.config/chromium/Singleton*`.
- **The hotspot doesn't appear.** Connect over Ethernet, check `sudo iiab-diagnostics`, and make sure the install finished: `/etc/iiab/install-flags/iiab-complete` must exist.
- **Restoring the original homepage:** `sudo cp /library/www/html/home/index.html.iiab-original /library/www/html/home/index.html`

### License

The scripts and homepage in this repo are released under the [MIT License](LICENSE). Internet-in-a-Box, Kiwix and all downloaded content (Wikipedia, OpenStreetMap, etc.) keep their own licenses. This project is not affiliated with Internet-in-a-Box or Kiwix.

---

## Türkçe

Raspberry Pi 5 üzerinde çevrimdışı bilgi arşivi. Wikipedia, haritalar, tıbbi başvuru kaynakları ve tamir rehberleri Pi'nin kendi Wi-Fi ağı üzerinden sunulur. Ağa bağlanan herhangi bir telefon ya da bilgisayar bunları tarayıcıdan açabilir. İnternet gerekmez.

[Internet-in-a-Box](https://github.com/iiab/iiab) ve [Kiwix](https://kiwix.org) üzerine kurulmuştur. Bu repo hazır ayarlar, yardımcı betikler ve özel bir ana sayfa ekler.

### Donanım

| Parça | Not |
|---|---|
| Raspberry Pi 5 (4 GB veya 8 GB) | |
| M.2 NVMe HAT + NVMe SSD (256 GB+) | İçerikler burada durur |
| microSD kart (32 GB+) | İşletim sistemi |
| 5V/5A USB-C adaptör | Resmi adaptör önerilir |
| Aktif soğutucu | Pi 5 ve SSD ısınır |
| Ethernet kablosu | Kurulum sırasında önerilir |

### Kurulum

**1. İşletim sistemi.** Raspberry Pi Imager ile SD karta **Raspberry Pi OS Lite (64-bit)** yaz. Imager ayarlarında SSH'ı aç, kullanıcı adı ve şifre belirle. Pi'yi SSD takılıyken başlat ve modeme Ethernet ile bağla.

**2. Sistemi güncelle ve repoyu indir.**
```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y git
git clone https://github.com/schematrix/HAS_Prepper_Disk.git
cd HAS_Prepper_Disk
chmod +x install.sh scripts/*.sh
```

**3. SSD'yi `/library` klasörüne bağla.** Disk adını `lsblk` ile bul, genelde `nvme0n1` olur. Disk ext4 değilse formatlanır, ama betik bunu yapmadan önce onay ister.
```bash
sudo ./scripts/setup-ssd.sh /dev/nvme0n1
```

**4. Kur.** Betik önce Wi-Fi adını ve şifresini sorar, sonra Internet-in-a-Box'ı kurar (30–60 dk). **Pi yeniden başlarsa ya da kurulum yarıda kalırsa aynı komutu tekrar çalıştır.** Kaldığı yerden devam eder.
```bash
sudo ./install.sh
```

**5. İçerikleri indir.** Ne indirileceğini `config/content.conf` dosyasından seç, sonra aşağıdaki betiği çalıştır. Varsayılan liste yaklaşık 135 GB tutar ve indirme saatler sürebilir. İndirme yarıda kalırsa betiği tekrar çalıştırman yeterli, kaldığı yerden devam eder.
```bash
sudo ./scripts/download-content.sh
```

**6. Haritalar.** `http://<pi-ip>/admin` adresine gir (kullanıcı adı `iiab-admin`), **Install Content** menüsündeki harita bölümüne git ve istediğin bölgeleri seç.

**7. Kullan.** Oluşturduğun Wi-Fi ağına bağlan ve **http://box.lan/home** adresini aç.

### Repo yapısı

```
install.sh                   ana kurulum betiği
scripts/setup-ssd.sh         SSD'yi /library klasörüne bağlar
scripts/download-content.sh  Kiwix'ten ZIM dosyalarını indirir/günceller
scripts/install-homepage.sh  özel ana sayfayı kurar
config/iiab-overrides.yml    Internet-in-a-Box ayarları
config/content.conf          indirilecek içerik listesi
www/home/index.html          ana sayfa
```

### Sorun giderme

- **Kurulumdan sonra `ssh kullanici@hostname.local` çalışmıyor.** Internet-in-a-Box cihazın adını `box` yapar. `ssh kullanici@box.local` ya da Pi'nin IP adresini kullan. IP adresini bulmak için bilgisayarında `arp -a` çalıştır ya da modeminin cihaz listesine bak.
- **Chromium "profile is locked" hatası veriyor.** Bu da cihaz adının değişmesinden kaynaklanır. "Unlock Profile" butonuna tıkla ya da `rm -f ~/.config/chromium/Singleton*` komutunu çalıştır.
- **Hotspot görünmüyor.** Ethernet ile bağlan, `sudo iiab-diagnostics` komutuyla kontrol et ve kurulumun bittiğinden emin ol: `/etc/iiab/install-flags/iiab-complete` dosyası var olmalı.
- **Orijinal ana sayfaya dönmek için:** `sudo cp /library/www/html/home/index.html.iiab-original /library/www/html/home/index.html`

### Lisans

Bu repodaki betikler ve ana sayfa [MIT Lisansı](LICENSE) ile yayınlanmıştır. Internet-in-a-Box, Kiwix ve indirilen tüm içerikler (Wikipedia, OpenStreetMap vb.) kendi lisanslarına tabidir. Bu proje Internet-in-a-Box veya Kiwix ile bağlantılı değildir.
