#!/usr/bin/env python3
"""Afet toplanma alanları: OpenStreetMap'ten indirir, kutu sahibinin eklediklerini yönetir.

Kullanım / usage:
  sudo ./scripts/toplanma.py guncelle                      OpenStreetMap'ten indir (internet gerekir) / download from OpenStreetMap
  sudo ./scripts/toplanma.py ekle "Ad" ENLEM BOYLAM        kendi alanını ekle / add a point, e.g. ekle "Okul bahçesi" 37.5753 36.9228
  sudo ./scripts/toplanma.py sil NUMARA                    eklediğini sil / delete an added point (number from liste)
  ./scripts/toplanma.py liste                              eklenenleri listele / list added points

OpenStreetMap'teki noktalar eksiktir; resmi alanını e-Devlet'te "Afet ve Acil Durum Toplanma Alanı
Sorgulama" ile öğrenip buradan ekleyebilirsin. Veri ODbL lisanslıdır, © OpenStreetMap katkıcıları.
OpenStreetMap coverage is incomplete; add official points by hand. Data is ODbL, © OpenStreetMap contributors.
"""
import datetime
import json
import math
import os
import sys
import urllib.parse
import urllib.request

HOME = "/library/www/html/home"
OSM = os.path.join(HOME, "toplanma.json")
YEREL = os.path.join(HOME, "toplanma-yerel.json")
SERVERS = ("https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter")
# Overpass kimliksiz istekleri reddediyor / Overpass rejects requests without a User-Agent
AGENT = "HAS_PrepperDisk (https://github.com/schematrix/HAS_Prepper_Disk)"
QUERY = """[out:json][timeout:300];
area["ISO3166-1"="TR"][admin_level=2]->.tr;
nwr["emergency"="assembly_point"](area.tr);
out center tags;
node[place~"^(city|town|village|suburb|neighbourhood|quarter)$"][name](area.tr);
out;"""
MAHALLE = ("suburb", "neighbourhood", "quarter", "village")
SEHIR = ("town", "city")


def die(msg):
    sys.exit(f"HATA / ERROR: {msg}")


def need_root():
    if os.geteuid() != 0:
        die("sudo ile çalıştır / run with sudo")


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def read_yerel():
    try:
        with open(YEREL, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


def km(a, b):
    # Birkaç km içinde düz yeryüzü yaklaşımı yeterli / a flat-earth approximation is fine within a few km
    dy = (a[0] - b[0]) * 111.2
    dx = (a[1] - b[1]) * 111.2 * math.cos(math.radians(a[0]))
    return math.hypot(dx, dy)


def nearest(index, p, limit):
    """limit km içindeki en yakın yer adı / nearest place name within limit km."""
    best, best_d = "", limit
    # 0,1 derece boylam Türkiye'de ~8 km / 0.1 degree of longitude is ~8 km in Turkey
    r = math.ceil(limit / 8)
    gy, gx = int(p[0] * 10), int(p[1] * 10)
    for y in range(gy - r, gy + r + 1):
        for x in range(gx - r, gx + r + 1):
            for q, name in index.get((y, x), ()):
                d = km(p, q)
                if d < best_d:
                    best, best_d = name, d
    return best


def grid(places):
    index = {}
    for p, name in places:
        index.setdefault((int(p[0] * 10), int(p[1] * 10)), []).append((p, name))
    return index


def guncelle():
    need_root()
    body = urllib.parse.urlencode({"data": QUERY}).encode()
    data = None
    for url in SERVERS:
        print(f"İndiriliyor / downloading: {url}")
        try:
            req = urllib.request.Request(url, body, headers={"User-Agent": AGENT})
            with urllib.request.urlopen(req, timeout=360) as r:
                data = json.load(r)
            break
        except (OSError, ValueError) as e:
            print(f"  olmadı / failed: {e}")
    if data is None:
        die("OpenStreetMap'e ulaşılamadı, eski liste duruyor / could not reach OpenStreetMap, old list kept")

    mahalle, sehir, alanlar = [], [], []
    for e in data["elements"]:
        tags = e.get("tags", {})
        if tags.get("emergency") == "assembly_point":
            c = e.get("center", e)
            alanlar.append(((c["lat"], c["lon"]), tags.get("name", "")))
        elif tags.get("place") in MAHALLE:
            mahalle.append(((e["lat"], e["lon"]), tags["name"]))
        elif tags.get("place") in SEHIR:
            sehir.append(((e["lat"], e["lon"]), tags["name"]))
    if not alanlar:
        die("hiç toplanma alanı gelmedi, eski liste duruyor / no points received, old list kept")

    m_index, s_index = grid(mahalle), grid(sehir)
    noktalar = [{"ad": name, "lat": round(p[0], 5), "lon": round(p[1], 5),
                 "mahalle": nearest(m_index, p, 3), "yer": nearest(s_index, p, 30)} for p, name in alanlar]
    noktalar.sort(key=lambda n: (n["yer"], n["mahalle"], n["ad"]))
    write_json(OSM, {"guncel": datetime.date.today().isoformat(), "noktalar": noktalar})
    print(f"{len(noktalar)} toplanma alanı yazıldı / points written: {OSM}")


def ekle(ad, enlem, boylam):
    need_root()
    try:
        lat, lon = float(enlem.replace(",", ".")), float(boylam.replace(",", "."))
    except ValueError:
        die("enlem ve boylam sayı olmalı, ör. 37.5753 36.9228 / latitude and longitude must be numbers")
    # Türkiye ve çevresi. Doğuda enlem ile boylam aynı aralıkta, yer değiştirmeleri yakalanamaz; çıktıda gösterilir.
    # Turkey and around. In the east swapped values look valid too, so the output spells them out.
    if not (34 <= lat <= 43 and 24 <= lon <= 46):
        die("koordinat Türkiye dışında; önce enlem (36-42), sonra boylam (26-45) / coordinates outside Turkey")
    ad = " ".join(ad.split())[:80]
    if not ad:
        die("ad gerekli / name required")
    yerel = read_yerel()
    yerel.append({"ad": ad, "lat": round(lat, 5), "lon": round(lon, 5)})
    write_json(YEREL, yerel)
    print(f"Eklendi / added: {len(yerel)}. {ad}  enlem/lat {lat:.5f} (kuzey/N), boylam/lon {lon:.5f} (doğu/E)")
    print("Yanlışsa / if wrong:  sudo ./scripts/toplanma.py sil " + str(len(yerel)))


def sil(no):
    need_root()
    yerel = read_yerel()
    if not no.isdigit() or not 1 <= int(no) <= len(yerel):
        die(f"{no} numaralı nokta yok, bkz. liste / no such point, see liste")
    n = yerel.pop(int(no) - 1)
    write_json(YEREL, yerel)
    print(f"Silindi / deleted: {n['ad']}")


def liste():
    yerel = read_yerel()
    if not yerel:
        print("Eklenmiş nokta yok / no added points")
    for i, n in enumerate(yerel, 1):
        print(f"{i}. {n['ad']}  ({n['lat']}, {n['lon']})")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["guncelle"] and len(args) == 1:
        guncelle()
    elif args[:1] == ["ekle"] and len(args) == 4:
        ekle(*args[1:])
    elif args[:1] == ["sil"] and len(args) == 2:
        sil(args[1])
    elif args[:1] == ["liste"] and len(args) == 1:
        liste()
    else:
        print(__doc__.split("\n\n")[1])
        sys.exit(2)
