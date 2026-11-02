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
        """
    )
    return con


def build(zim_path, index_dir, embedder, index, progress=None):
    """Bir ZIM dosyasını indeksler. Aynı ZIM'in eski kayıtlarını değiştirir.

    `index`, aralıkları ve sıradaki kimliği tutan SearchIndex'tir (vektörsüz);
    kurulum böylece mevcut indeksi her ZIM için yeniden okumaz.
    """
    from .zimtext import iter_articles

    zim = Path(zim_path)
    out = Path(index_dir)
    # Tüm ZIM'lerin vektörleri aramada tek dizide birleştiği için pencere numaraları
    # diğer ZIM'lerin ardından devam eder; 0'dan başlarsa sonraki ZIM'ler kayar.
    index.drop_zim(zim.name)
    con = connect(out)  # şemayı oluşturur / creates the schema
    con.execute("DELETE FROM docs WHERE zim = ?", (zim.name,))

    # Aynı ZIM yeniden indekslenirken yarım kalan .npy yeni veriye eklenmesin.
    vecs_path = out / f"{zim.name}.vecs.npy"
    vecs_path.unlink(missing_ok=True)
    (out / f"{zim.name}.meta.json").unlink(missing_ok=True)
    started = time.time()
    offset = index.windows
    doc_id = index.next_doc_id

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
    con.commit()
    con.close()
    index.add(zim.name, rows)

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
        # Vektör dosyaları docs'taki ofset sırasıyla birleşmeli; her ZIM'in first değeri
        # kendi ZIM'inde değil, tüm indekste geçerli tek bir kaydırmadır.
        present = {d[1] for d in self.docs}
        parts = []
        for meta_path in sorted(self.dir.glob("*.meta.json")):
            meta = json.loads(meta_path.read_text())
            if not meta["windows"] or meta["zim"] not in present:
                continue
            parts.append(_load_vecs(self.dir / f"{meta['zim']}.vecs.npy"))
            self.zims.append(meta["zim"])
        # int8 diskte kalır, RAM'de yalnızca arama kopyası durur. float16 pencere başına
        # 2 bayt: float32'nin yarısı, int8'in iki katı. 1 milyon pencere 512 MB yerine 1 GB
        # eder; Pi 5'te sorun değil, 2 GB'lık Pi'lerde hangi ZIM'lerin indekslendiği önemli.
        self.vecs = _normalize(np.concatenate(parts).astype(np.float16) / 127) if parts else None

    def _load_docs(self):
        con = connect(self.dir)  # arama salt okunur; ilk kurulumda şemayı da oluşturur
        self.docs = con.execute("SELECT id, zim, path, n_win, first FROM docs ORDER BY first").fetchall()
        con.close()

    @property
    def windows(self):
        return sum(d[3] for d in self.docs)

    @property
    def next_doc_id(self):
        return max((d[0] for d in self.docs), default=0) + 1

    def drop_zim(self, zim_name):
        """Yeniden indekslenecek ZIM'in aralıklarını bırakır.

        Kalan aralıklar 0'dan yeniden numaralanır: ZIM tek başına indekslenebilsin
        diye sıra korunur, boşluk kalmaz ve sıradaki ZIM aralığı bitişik başlar.
        """
        kept, first = [], 0
        for doc_id, zim, path, n_win, _ in self.docs:
            if zim == zim_name:
                continue
            kept.append((doc_id, zim, path, n_win, first))
            first += n_win
        self.docs = kept

    def add(self, zim_name, rows):
        """İndekslenen ZIM'in satırlarını sıraya ekler (aralık numaraları `build`'den)."""
        self.docs.extend(rows)

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
