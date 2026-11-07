#!/usr/bin/env python3
"""Afet toplanma alanları: AFAD listesini ve OpenStreetMap'i kutuya yazar, kutu sahibinin eklediklerini yönetir.

Kullanım / usage:
  sudo ./scripts/toplanma.py guncelle                      kutuya yaz, mahalle adları için internet gerekir / write to the box (needs internet)
  sudo ./scripts/toplanma.py konum ENLEM BOYLAM            kutunun durduğu yer, sayfa en yakın alanları hazır gösterir / box location
  sudo ./scripts/toplanma.py ekle "Ad" ENLEM BOYLAM        kendi alanını ekle / add a point, e.g. ekle "Okul bahçesi" 37.5753 36.9228
  sudo ./scripts/toplanma.py sil NUMARA                    eklediğini sil / delete an added point (number from liste)
  ./scripts/toplanma.py liste                              eklenenleri listele / list added points
  ./scripts/toplanma.py afad DOSYA.json                    bakımcı: data/toplanma-afad.json'u yenile / maintainers: refresh the AFAD list

AFAD listesi, AFAD'ın "Açık Veri" olarak yayımladığı "Acil Durum Toplanma Alanları" katmanının
depodaki tarihli kopyasıdır. OpenStreetMap verisi ODbL, © OpenStreetMap katkıcıları.
The AFAD list is a dated copy of AFAD's open-data assembly points layer. OpenStreetMap data is ODbL.
"""
import datetime
import json
import math
import os
import sys
import urllib.parse
import urllib.request

HOME = "/library/www/html/home"
LISTE = os.path.join(HOME, "toplanma.json")
YEREL = os.path.join(HOME, "toplanma-yerel.json")
KONUM = os.path.join(HOME, "toplanma-konum.json")
AFAD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "toplanma-afad.json")
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


def read_afad():
    with open(AFAD, encoding="utf-8") as f:
        return json.load(f)


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
            if data.get("elements"):
                break
            print(f"  boş döndü / empty answer: {data.get('remark', '')}")
            data = None
        except (OSError, ValueError) as e:
            print(f"  olmadı / failed: {e}")
    if data is None:
        if os.path.exists(LISTE):
            die("OpenStreetMap'e ulaşılamadı, eski liste duruyor / could not reach OpenStreetMap, old list kept")
        print("OpenStreetMap'e ulaşılamadı; AFAD listesi mahalle adları olmadan yazılıyor, sonra tekrar çalıştır.\n"
              "Could not reach OpenStreetMap; writing the AFAD list without neighbourhood names, run again later.")
        data = {"elements": []}

    afad = read_afad()
    alanlar = [((lat, lon), {"ad": ad, "il": il}) for _, ad, il, lat, lon in afad["alanlar"]]
    a_index = grid((p, "AFAD") for p, _ in alanlar)
    mahalle, sehir = [], []
    for e in data["elements"]:
        tags = e.get("tags", {})
        if tags.get("emergency") == "assembly_point":
            c = e.get("center", e)
            p = (c["lat"], c["lon"])
            # AFAD'da aynı yerde kayıt varsa OSM'deki kopyası gereksiz / skip OSM points AFAD already has within 50 m
            if not nearest(a_index, p, 0.05):
                alanlar.append((p, {"ad": tags.get("name", ""), "osm": True}))
        elif tags.get("place") in MAHALLE:
            mahalle.append(((e["lat"], e["lon"]), tags["name"]))
        elif tags.get("place") in SEHIR:
            sehir.append(((e["lat"], e["lon"]), tags["name"]))

    m_index, s_index = grid(mahalle), grid(sehir)
    noktalar = [{**n, "lat": round(p[0], 5), "lon": round(p[1], 5),
                 "mahalle": nearest(m_index, p, 3), "yer": nearest(s_index, p, 30)} for p, n in alanlar]
    noktalar.sort(key=lambda n: ("osm" in n, n.get("il") or "", n["yer"], n["mahalle"], n["ad"]))
    guncel = datetime.date.today().isoformat() if data["elements"] else ""
    write_json(LISTE, {"guncel": guncel, "afad": afad["guncel"], "noktalar": noktalar})
    osm = sum(1 for n in noktalar if n.get("osm"))
    print(f"{len(noktalar)} toplanma alanı yazıldı ({len(noktalar) - osm} AFAD, {osm} OpenStreetMap) / points written: {LISTE}")


def koordinat(enlem, boylam):
    try:
        lat, lon = float(enlem.replace(",", ".")), float(boylam.replace(",", "."))
    except ValueError:
        die("enlem ve boylam sayı olmalı, ör. 37.5753 36.9228 / latitude and longitude must be numbers")
    # Türkiye ve çevresi. Doğuda enlem ile boylam aynı aralıkta, yer değiştirmeleri yakalanamaz; çıktıda gösterilir.
    # Turkey and around. In the east swapped values look valid too, so the output spells them out.
    if not (34 <= lat <= 43 and 24 <= lon <= 46):
        die("koordinat Türkiye dışında; önce enlem (36-42), sonra boylam (26-45) / coordinates outside Turkey")
    return lat, lon


def konum(enlem, boylam):
    need_root()
    lat, lon = koordinat(enlem, boylam)
    write_json(KONUM, {"lat": round(lat, 5), "lon": round(lon, 5), "tarih": datetime.date.today().isoformat()})
    print(f"Kutunun konumu / box location: enlem/lat {lat:.5f} (kuzey/N), boylam/lon {lon:.5f} (doğu/E)")


def ekle(ad, enlem, boylam):
    need_root()
    lat, lon = koordinat(enlem, boylam)
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


def afad(path):
    with open(path, encoding="utf-8") as f:
        kayitlar = json.load(f)
    # Açıklama alınmaz: bazılarında personel adı, telefonu ve parsel sahibi yazıyor.
    # Descriptions are left out: some hold staff names, phone numbers and parcel owners.
    alanlar = sorted([k["id"], " ".join(k["ad"].split()), k["il_adi"], round(k["lat"], 5), round(k["lon"], 5)]
                     for k in kayitlar if k.get("lat") is not None and k["ad"].strip().lower() != "test")
    try:
        eski = {a[0]: a for a in read_afad()["alanlar"]}
    except OSError:
        eski = {}
    yeni = {a[0]: a for a in alanlar}
    print(f"{len(alanlar)} alan / points: {len(yeni.keys() - eski.keys())} eklenen / added, "
          f"{len(eski.keys() - yeni.keys())} silinen / removed, "
          f"{sum(1 for i in yeni.keys() & eski.keys() if yeni[i] != eski[i])} değişen / changed")
    # Satır başına bir alan: güncellemelerde git farkı okunur kalsın / one point per line keeps git diffs readable
    satirlar = ",\n".join(json.dumps(a, ensure_ascii=False) for a in alanlar)
    with open(AFAD, "w", encoding="utf-8", newline="\n") as f:
        f.write(f'{{"guncel":"{datetime.date.today().isoformat()}","alanlar":[\n{satirlar}\n]}}\n')
    print(f"Yazıldı / written: {os.path.normpath(AFAD)}")


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
    elif args[:1] == ["konum"] and len(args) == 3:
        konum(*args[1:])
    elif args[:1] == ["ekle"] and len(args) == 4:
        ekle(*args[1:])
    elif args[:1] == ["sil"] and len(args) == 2:
        sil(args[1])
    elif args[:1] == ["liste"] and len(args) == 1:
        liste()
    elif args[:1] == ["afad"] and len(args) == 2:
        afad(args[1])
    else:
        print(__doc__.split("\n\n")[1])
        sys.exit(2)
