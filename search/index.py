"""Semantik arama indeksi: int8 vektörler + makale metadata'sı.

Dizin yapısı (varsayılan /library/index):
  <zim>.vecs.npy   int8 [n_windows, dim] — L2-normalize vektörlerin int8 kopyası
  <zim>.meta.json  {"zim", "dim", "docs", "windows", "seconds", "windows_per_s", "built"}
  index.db         SQLite: makale yolları ve pencere→makale aralıkları
"""
import json
import sqlite3
import time
from pathlib import Path

import numpy as np

from .embedder import chunk_words, quantize

EMBED_CHUNK = 1024


def connect(index_dir):
    """Dizin veritabanını açar (yoksa oluşturur)."""
    path = Path(index_dir)
    path.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path / "index.db")
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    con.executescript(
        """
        CREATE TABLE IF NOT EXISTS docs (
            id     INTEGER PRIMARY KEY,
            zim    TEXT NOT NULL,
            path   TEXT NOT NULL,
            n_win  INTEGER NOT NULL,
            first  INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS docs_zim ON docs(zim);
        CREATE TABLE IF NOT EXISTS zims (
            zim    TEXT PRIMARY KEY,
            seq    INTEGER NOT NULL
        );
        """
    )
    return con


def build(zim_path, index_dir, embedder, progress=None):
    """Bir ZIM dosyasını indeksler. Aynı ZIM'in eski kayıtlarını değiştirir.

    Aralıklar ve kimlikler veritabanından okunur, böylece bir çalıştırmada art
    arda indekslenen ZIM'ler de doğru yere yazılır.
    """
    from .zimtext import iter_articles

    zim = Path(zim_path)
    out = Path(index_dir)
    con = connect(out)  # şemayı oluşturur / creates the schema
    # Tüm ZIM'lerin vektörleri aramada tek dizide birleştiği için pencere numaraları
    # sırayla devam eder. Yeniden indekslenen ZIM sıranın sonuna taşınır: eski yerini
    # boşaltmak kalanları kaydırır ve aralıklar iç içe geçer. Bu yüzden ofset, kalan
    # ZIM'lerin toplamı; arama da vektörleri `zims` sırasıyla birleştirir.
    con.execute("DELETE FROM docs WHERE zim = ?", (zim.name,))
    con.execute("DELETE FROM zims WHERE zim = ?", (zim.name,))
    offset, doc_id, seq = con.execute(
        "SELECT COALESCE((SELECT SUM(d.n_win) FROM docs d JOIN zims z ON z.zim = d.zim), 0),"
        " COALESCE((SELECT MAX(id) FROM docs), 0) + 1,"
        " COALESCE((SELECT MAX(seq) FROM zims), 0) + 1"
    ).fetchone()

    # Aynı ZIM yeniden indekslenirken yarım kalan .npy yeni veriye eklenmesin.
    vecs_path = out / f"{zim.name}.vecs.npy"
    vecs_path.unlink(missing_ok=True)
    (out / f"{zim.name}.meta.json").unlink(missing_ok=True)
    started = time.time()

    rows, pending, window, docs = [], [], 0, 0
    with open(vecs_path, "wb") as fh:
        _write_header(fh, embedder.dim, 0)
        for path, text in iter_articles(zim):
            pieces = chunk_words(text)
            rows.append((doc_id, zim.name, path, len(pieces), offset + window + len(pending)))
            pending.extend(pieces)
            doc_id += 1
            docs += 1
            # Parçaları sınırlı sayıda biriktir: Pi'nin RAM'inde 1 GB'lık orba bile sığar.
            if len(pending) >= EMBED_CHUNK:
                fh.write(quantize(embedder.encode(pending, role="doc")).tobytes())
                window += len(pending)
                pending = []
            if progress and docs % 2000 == 0:
                progress(docs, window + len(pending))
        if pending:
            fh.write(quantize(embedder.encode(pending, role="doc")).tobytes())
            window += len(pending)
        # np.load, dosya boyutunu başlıktaki şekille karşılaştırır. Başlık uzunluğu
        # pencere sayısına göre değişebileceği için şekil, veriye dokunmadan
        # dosyanın sonundaki sabit genişlikli alana yazılır.
        _write_shape(fh, window)

    con.executemany("INSERT INTO docs (id, zim, path, n_win, first) VALUES (?, ?, ?, ?, ?)", rows)
    if window:
        # Sıra hiç düşmez: silinen ZIM'in numarası tekrar kullanılsa yeni sıra
        # kalanların arasına düşer ve vektör dosyaları yanlış sırayla birleşir.
        con.execute("INSERT INTO zims (zim, seq) VALUES (?, ?)", (zim.name, seq))
        _renumber(con)
    con.commit()
    con.close()

    if not window:
        # Makalesi olmayan ZIM: meta dosyası yazılmaz, arama onu atlar.
        vecs_path.unlink(missing_ok=True)
        return {"zim": zim.name, "docs": 0, "windows": 0}

    meta = {
        "zim": zim.name,
        "dim": embedder.dim,
        "docs": docs,
        "windows": window,
        "seconds": round(time.time() - started, 1),
        "windows_per_s": round(window / max(time.time() - started, 1e-9), 1),
        "built": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    (out / f"{zim.name}.meta.json").write_text(json.dumps(meta, indent=2))
    return meta


def _renumber(con):
    """Aralıkları `zims` sırasına göre yeniden numaralar (her ZIM sıfırdan başlar)."""
    con.execute(
        """
        WITH seq AS (
            SELECT d.id, SUM(d.n_win) OVER (
                PARTITION BY z.seq ORDER BY d.first, d.id ROWS UNBOUNDED PRECEDING
            ) - d.n_win + COALESCE((
                SELECT SUM(d2.n_win) FROM docs d2
                JOIN zims z2 ON z2.zim = d2.zim WHERE z2.seq < z.seq
            ), 0) AS first
            FROM docs d JOIN zims z ON z.zim = d.zim
        )
        UPDATE docs SET first = (SELECT first FROM seq WHERE seq.id = docs.id)
        """
    )


_SHAPE_BYTES = 16  # dosya sonundaki "pencere sayısı" alanı


def _write_header(fh, dim, rows):
    """int8 [rows, dim] .npy başlığını yazar (dosyanın en başına)."""
    np.lib.format.write_array_header_1_0(
        fh, {"descr": "|i1", "fortran_order": False, "shape": (rows, dim)}
    )


def _write_shape(fh, rows):
    """Pencere sayısını dosyanın sonundaki sabit genişlikli alana yazar.

    İndeks kurulurken şekil baştan bilinmez; .npy başlığını sonradan yazmak
    veriyi kaydırmak gerekir. Onun yerine son 16 bayt şekli taşır.
    """
    fh.write(rows.to_bytes(_SHAPE_BYTES, "little"))  # imleç dosya sonundadır


def _normalize(vecs):
    """int8 yuvarlaması vektör boyunu ±%0,5 değiştirir; kosinüs için yeniden ölçeklenir."""
    if vecs is None:
        return None
    return vecs / np.clip(np.linalg.norm(vecs, axis=1, keepdims=True), 1e-12, None)


def _load_vecs(path):
    """int8 [n, dim] vektörleri okur; son 16 bayt pencere sayısıdır.

    Şekil alanı okunurken başlıktaki pencere sayısına güvenilmez (yazım sırasında
    yer tutucu 0'dır); satır sayısı yalnızca son 16 bayttan gelir.
    """
    with open(path, "rb") as fh:
        fh.seek(0)
        np.lib.format.read_magic(fh)
        header = np.lib.format.read_array_header_1_0(fh)
        dim = header[0][1]
        offset = fh.tell()
        fh.seek(-_SHAPE_BYTES, 2)
        rows = int.from_bytes(fh.read(_SHAPE_BYTES), "little")
    return np.memmap(path, dtype=np.int8, mode="r", offset=offset, shape=(rows, dim))


def is_indexed(zim_path, index_dir):
    """İndeks var mı ve ZIM değişmemiş mi?"""
    zim = Path(zim_path)
    meta = Path(index_dir) / f"{zim.name}.meta.json"
    vecs = Path(index_dir) / f"{zim.name}.vecs.npy"
    return meta.exists() and vecs.exists() and vecs.stat().st_mtime >= zim.stat().st_mtime


class SearchIndex:
    """Tüm ZIM'leri tek vektör dizisinde birleştiren arama indeksi."""

    def __init__(self, index_dir, load_vectors=True):
        # İndeks kurarken (load_vectors=False) vektörler RAM'e alınmaz: kurulum
        # dakikalarca sürer ve Pi'de boşuna yüzlerce MB tutmaya gerek yok.
        self.dir = Path(index_dir)
        self.vecs = None
        self.docs = []
        self.zims = []
        self._load() if load_vectors else self._load_docs()

    def _load(self):
        self._load_docs()
        # Her ZIM'in first değeri kendi ZIM'inde değil, tüm indekste geçerli tek bir
        # kaydırmadır; vektör dosyaları da aynı sırayla birleşmeli. Sıra, dosya adı
        # değil indeksleme sırasıdır: alfabetik sıra yeniden indekslemede kayar.
        # Toplamlar docs'tan gelir, böylece meta ile vektör dosyası tutmasa bile
        # pencere numaraları dizinin uzunluğuyla birebir örtüşür.
        con = connect(self.dir)
        seqs = dict(con.execute("SELECT zim, seq FROM zims"))
        counts = dict(con.execute("SELECT zim, SUM(n_win) FROM docs GROUP BY zim"))
        con.close()
        parts = []
        for name in sorted((z for z in counts if z in seqs), key=seqs.get):
            vecs = _load_vecs(self.dir / f"{name}.vecs.npy")
            # Eksik ya da artık satır kalırsa aralıklar kaymasın: sayı docs'a uydurulur.
            rows = min(counts[name], len(vecs))
            if rows < counts[name]:
                self.docs = [d for d in self.docs if d[1] != name]
            parts.append(vecs[:rows])
            self.zims.append(name)
        # int8 diskte kalır, RAM'de yalnızca arama kopyası durur. float16 pencere başına
        # 2 bayt: float32'nin yarısı, int8'in iki katı. 1 milyon pencere 512 MB yerine 1 GB
        # eder; Pi 5'te sorun değil, 2 GB'lık Pi'lerde hangi ZIM'lerin indekslendiği önemli.
        self.vecs = _normalize(np.concatenate(parts).astype(np.float16) / 127) if parts else None

    def _load_docs(self):
        con = connect(self.dir)  # arama salt okunur; ilk kurulumda şemayı da oluşturur
        self.docs = con.execute(
            "SELECT d.id, d.zim, d.path, d.n_win, d.first FROM docs d"
            " LEFT JOIN zims z ON z.zim = d.zim ORDER BY z.seq, d.first, d.id"
        ).fetchall()
        con.close()

    def search(self, query_vec, k=10):
        """Kosinüs skoruyla en iyi k makaleyi döner (makale başına en iyi pencere)."""
        if self.vecs is None or not len(self.vecs):
            return []
        scores = self.vecs.astype(np.float32) @ query_vec.astype(np.float32)
        # İlk aşama tüm pencerelerde tarama; aday sayısı yalnızca k'ye bağlı kalsın diye
        # sabit 512 pencereye bakılır (tam Vikipedi'de de maliyet sabit kalır).
        n = min(512, len(scores))
        candidates = np.argpartition(-scores, n - 1)[:n]
        candidates = candidates[np.argsort(-scores[candidates])]

        seen, hits = set(), []
        for idx in candidates:
            doc = self._doc_for_window(int(idx))
            if doc is None or doc[0] in seen:
                continue
            seen.add(doc[0])
            hits.append({"score": round(float(scores[idx]), 3), "zim": doc[1], "path": doc[2]})
            if len(hits) >= k:
                break
        return hits

    def _doc_for_window(self, window_idx):
        lo, hi = 0, len(self.docs) - 1
        while lo <= hi:
            mid = (lo + hi) // 2
            doc_id, zim, path, n_win, first = self.docs[mid]
            if window_idx < first:
                hi = mid - 1
            elif window_idx >= first + n_win:
                lo = mid + 1
            else:
                return doc_id, zim, path
        return None
