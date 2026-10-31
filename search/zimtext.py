"""ZIM arşivlerinden düz metin çıkarır.

Kiwix ZIM'leri makaleleri HTML olarak tutar; bize sadece metin gerekir.
Önce script/style blokları atılır, sonra sayfa şablonu (başlık, menü, kenar çubuğu)
kırpılır. Şablon kırpma, arama kalitesini ciddi biçimde artırır: Vikipedi
sayfalarının yarısından fazlası gezinme ve betiktir.
"""
import re

BLOCK = re.compile(r"<(script|style|noscript|svg|template)\b[^>]*>.*?</\1>", re.S | re.I)
TAG = re.compile(r"<[^>]+>")
WS = re.compile(r"\s+")

# Her biri "asıl içeriğin başladığı" işarettir; ilk bulunan kullanılır.
CONTENT_START = [
    re.compile(r'<div[^>]+id="mw-content-text"', re.I),          # MediaWiki / Kiwix
    re.compile(r"<article\b", re.I),                              # Zimit (read.gov, ifixit)
    re.compile(r"<main\b", re.I),
]
# Zimit paketlerinde içerik sarmalayıcıları.
CONTENT_CLASS = re.compile(
    r'<(div|section)[^>]+class="[^"]*\b(mw-parser-output|post-content|entry-content|article-content)\b[^"]*"',
    re.I,
)


def _clip(html):
    for pat in CONTENT_START + [CONTENT_CLASS]:
        m = pat.search(html)
        if m:
            return html[m.start() :]
    return html


def to_text(html, max_chars=None):
    if not html:
        return ""
    html = BLOCK.sub(" ", html)
    body = _clip(html)
    text = WS.sub(" ", TAG.sub(" ", body)).strip()
    # Arama için makalenin tamamı gerekmez; ilk bölümü temsilidir ve RAM'i korur.
    return text[:max_chars] if max_chars else text


# Zimit arşivlerinde kategori, yazar ve sayfalama sayfaları (page/7, authors/kris)
# listelerden oluşur ve aramayı kirletir. Vikipedi'de bunlar yok, kural sadece
# Zimit paketlerine uygulanır.
LISTING = {"page", "tag", "tags", "author", "authors", "translator", "translators", "category", "categories"}


def is_article(path, zimit):
    return not (zimit and any(p in LISTING for p in path.split("/")))


def iter_articles(zim_path, min_chars=300, max_chars=12000):
    """ZIM içindeki HTML makalelerini (yol, metin) olarak verir."""
    from libzim.reader import Archive

    archive = Archive(str(zim_path))
    zimit = b"zimit" in archive.get_metadata("Scraper").lower()
    for i in range(archive.all_entry_count):
        entry = archive.get_entry_by_id(i)
        if entry.is_redirect:
            continue
        try:
            item = entry.get_item()
        except Exception:
            continue
        if item.mimetype.split(";")[0] != "text/html" or not is_article(entry.path, zimit):
            continue
        text = to_text(item.content.tobytes().decode("utf-8", "ignore"), max_chars)
        if len(text) >= min_chars:
            yield entry.path, text
