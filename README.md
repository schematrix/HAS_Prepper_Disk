

https://github.com/user-attachments/assets/9e65c1b5-7029-4091-a4b1-62b6d28519ec


<img width="347" height="62" alt="image" src="https://github.com/user-attachments/assets/7241f6d3-93da-4f2c-9615-7d33f293cfcc" />


<p align="center"><img src="assets/demo.gif" width="400" alt="HAS_PrepperDisk exploded view"></p>

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

**5. Download content.** Edit `config/content.conf` to choose what to download, then run the script below. The defaults need about 150 GB, and downloads can take many hours. If a download is interrupted, re-run the script and it resumes.
```bash
sudo ./scripts/download-content.sh
```

**6. Maps.** Open `http://<pi-ip>/admin` (user `iiab-admin`), go to the maps section of the **Install Content** menu and choose the regions you want.

**7. Use it.** Join the Wi-Fi network you created and open **http://box.lan/home**.

### Optional: internet over a USB Wi-Fi adapter

The Pi's built-in Wi-Fi is dedicated to the hotspot. If the Pi needs internet temporarily (updates, new content) and there is no Ethernet cable, add a cheap USB Wi-Fi adapter as a second card. Adapters with the MediaTek MT7601U chip work out of the box.

1. Plug the adapter in, preferably into a black USB 2.0 port. The blue USB 3.0 ports can interfere with 2.4 GHz Wi-Fi.
2. Join the Pi's hotspot from your laptop and connect: `ssh user@10.10.10.10`
3. Connect the adapter (usually `wlan1`) to a Wi-Fi network:
   ```bash
   nmcli device wifi list ifname wlan1
   sudo nmcli device wifi connect "NETWORK_NAME" password "PASSWORD" ifname wlan1 name temp-wifi
   ```
4. When you are done, remove the connection: `sudo nmcli connection delete temp-wifi`

**Never run `sudo iiab-network` while a USB Wi-Fi adapter is plugged in.** It may move the hotspot onto the adapter. Unplug it first.

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
- **Map downloads fail with "connection reset by peer".** The map server (`contabostorage.com`) is blocked in some countries, e.g. Turkey. Install Cloudflare WARP on the Pi, connect, retry the download in the admin console, then disconnect:
  ```bash
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(. /etc/os-release; echo $VERSION_CODENAME) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list
  sudo apt update && sudo apt install -y cloudflare-warp
  warp-cli --accept-tos registration new && warp-cli --accept-tos connect
  # after downloads finish:
  warp-cli --accept-tos disconnect
  ```
- **Book collections (Water Treatment, Knots, Food for Preppers, Post-Disaster, Medicine) keep loading forever.** These collections store their book list in the browser's local database. iPhone Safari private tabs and the captive portal pop-up window block that. Open them in a normal Safari tab.
- **The hotspot never comes up and the log says "invalid WPA passphrase length".** Wi-Fi passwords must be 8–63 characters. Fix `hostapd_password` in `/etc/iiab/local_vars.yml` and `wpa_passphrase` in `/etc/hostapd/hostapd.conf`, then `sudo systemctl restart hostapd`.
- **The hotspot is visible, but devices say "incorrect password" or drop after a few seconds.** The password is probably fine; the hotspot bridge (`br0`) is down. In `sudo journalctl -u hostapd` you see "associated → disassociated" repeating every ~4 seconds. Check:
  ```bash
  ip -br addr show br0
  bridge link
  ```
  If `br0` is DOWN and `wlan0` shows `state disabled`, the bridge was not created at boot. Changing connections with `nmcli` can leave the files in `/etc/netplan/90-NM-*.yaml` empty, which removes the bridge. Fix:
  ```bash
  sudo mkdir -p /root/netplan-bak && sudo mv /etc/netplan/90-NM-*.yaml /root/netplan-bak/
  sudo nmcli connection add type bridge ifname br0 con-name iiab-br0 ipv4.method manual ipv4.addresses 10.10.10.10/24 ipv6.method disabled bridge.stp no connection.autoconnect yes
  sudo nmcli connection up iiab-br0
  sudo systemctl restart hostapd dnsmasq
  ```
  `br0` should now be UP with 10.10.10.10 and `wlan0` should show `state forwarding`.
- **SSH without a cable:** join the Pi's hotspot and use `ssh user@10.10.10.10`.
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

**5. İçerikleri indir.** Ne indirileceğini `config/content.conf` dosyasından seç, sonra aşağıdaki betiği çalıştır. Varsayılan liste yaklaşık 150 GB tutar ve indirme saatler sürebilir. İndirme yarıda kalırsa betiği tekrar çalıştırman yeterli, kaldığı yerden devam eder.
```bash
sudo ./scripts/download-content.sh
```

**6. Haritalar.** `http://<pi-ip>/admin` adresine gir (kullanıcı adı `iiab-admin`), **Install Content** menüsündeki harita bölümüne git ve istediğin bölgeleri seç.

**7. Kullan.** Oluşturduğun Wi-Fi ağına bağlan ve **http://box.lan/home** adresini aç.

### İsteğe bağlı: USB Wi-Fi adaptörüyle internet

Pi'nin dahili Wi-Fi kartı sadece hotspot için kullanılıyor. Pi'nin geçici olarak internete çıkması gerekirse (güncelleme, yeni içerik) ve Ethernet kablosu yoksa ikinci kart olarak ucuz bir USB Wi-Fi adaptörü tak. MediaTek MT7601U yongalı adaptörler kurulumsuz çalışıyor.

1. Adaptörü mümkünse siyah USB 2.0 portlarından birine tak. Mavi USB 3.0 portları 2,4 GHz Wi-Fi'da parazit yapabiliyor.
2. Bilgisayarını Pi'nin hotspot'una bağla ve SSH ile gir: `ssh kullanici@10.10.10.10`
3. Adaptörü (genelde `wlan1`) bir Wi-Fi ağına bağla:
   ```bash
   nmcli device wifi list ifname wlan1
   sudo nmcli device wifi connect "AG_ADI" password "SIFRE" ifname wlan1 name gecici-wifi
   ```
4. İşin bitince bağlantıyı sil: `sudo nmcli connection delete gecici-wifi`

**USB Wi-Fi adaptörü takılıyken asla `sudo iiab-network` çalıştırma.** Hotspot'u adaptöre taşıyabilir. Önce adaptörü çıkar.

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
- **Harita indirmesi "connection reset by peer" hatası veriyor.** Harita sunucusu (`contabostorage.com`) Türkiye gibi bazı ülkelerde engelli. Pi'ye Cloudflare WARP kur, bağlan, indirmeyi yönetim panelinden tekrar başlat ve bitince bağlantıyı kapat:
  ```bash
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(. /etc/os-release; echo $VERSION_CODENAME) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list
  sudo apt update && sudo apt install -y cloudflare-warp
  warp-cli --accept-tos registration new && warp-cli --accept-tos connect
  # indirmeler bitince:
  warp-cli --accept-tos disconnect
  ```
- **Kitap koleksiyonları (Su Arıtma, Düğümler, Gıda, Afet Sonrası, Tıp) sürekli "yükleniyor" diyor.** Bu koleksiyonlar kitap listesini tarayıcının yerel veritabanında tutuyor. iPhone Safari'nin gizli sekmesi ve captive portal penceresi buna izin vermiyor. Normal bir Safari sekmesinde aç.
- **Hotspot hiç açılmıyor ve kayıtta "invalid WPA passphrase length" yazıyor.** Wi-Fi şifreleri 8–63 karakter olmalı. `/etc/iiab/local_vars.yml` içindeki `hostapd_password` ve `/etc/hostapd/hostapd.conf` içindeki `wpa_passphrase` satırını düzelt, sonra `sudo systemctl restart hostapd` çalıştır.
- **Hotspot görünüyor ama cihazlar "hatalı şifre" diyor ya da birkaç saniyede kopuyor.** Şifre büyük ihtimalle doğru, sorun hotspot köprüsünün (`br0`) kapalı olması. `sudo journalctl -u hostapd` çıktısında her ~4 saniyede tekrarlanan "associated → disassociated" satırları görürsün. Kontrol et:
  ```bash
  ip -br addr show br0
  bridge link
  ```
  `br0` DOWN ve `wlan0` için `state disabled` görünüyorsa köprü açılışta kurulmamış demektir. `nmcli` ile bağlantı eklemek ya da değiştirmek `/etc/netplan/90-NM-*.yaml` dosyalarını boşaltabiliyor, bu da köprüyü siliyor. Çözüm:
  ```bash
  sudo mkdir -p /root/netplan-bak && sudo mv /etc/netplan/90-NM-*.yaml /root/netplan-bak/
  sudo nmcli connection add type bridge ifname br0 con-name iiab-br0 ipv4.method manual ipv4.addresses 10.10.10.10/24 ipv6.method disabled bridge.stp no connection.autoconnect yes
  sudo nmcli connection up iiab-br0
  sudo systemctl restart hostapd dnsmasq
  ```
  Artık `br0` 10.10.10.10 adresiyle UP, `wlan0` da `state forwarding` görünmeli.
- **Kablosuz SSH:** Pi'nin hotspot'una bağlan ve `ssh kullanici@10.10.10.10` kullan.
- **Orijinal ana sayfaya dönmek için:** `sudo cp /library/www/html/home/index.html.iiab-original /library/www/html/home/index.html`

### Lisans

Bu repodaki betikler ve ana sayfa [MIT Lisansı](LICENSE) ile yayınlanmıştır. Internet-in-a-Box, Kiwix ve indirilen tüm içerikler (Wikipedia, OpenStreetMap vb.) kendi lisanslarına tabidir. Bu proje Internet-in-a-Box veya Kiwix ile bağlantılı değildir.
