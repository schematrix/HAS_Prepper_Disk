"""Komut satırı: ZIM indeksle ve sorgula.

  python3 -m search.cli build <zim> [<zim> ...]   # config'teki ZIM'leri indeksler
  python3 -m search.cli search "suyu nasıl arıtırım"
"""
import argparse
import sys
import time
from pathlib import Path

from .embedder import DEFAULT_MODEL, Embedder, ParallelEmbedder
from .index import SearchIndex, build

INDEX_DIR = "/library/index"


def cmd_build(args):
    embedder = ParallelEmbedder(args.model, workers=args.workers)
    for zim in args.zims:
        if not Path(zim).exists():
            print(f"!! yok / missing: {zim}", file=sys.stderr)
            continue
        t0 = time.time()
        meta = build(zim, args.index, embedder, progress=_progress(t0))
        print(
            f"OK {Path(zim).name}: {meta['docs']} makale, {meta['windows']} pencere, "
            f"{meta['seconds']}s ({meta['windows_per_s']} pencere/s)"
        )
    embedder.close()


def _progress(t0):
    def report(docs, windows):
        print(f"   {docs} makale, {windows} pencere, {time.time() - t0:.0f}s", flush=True)

    return report


def cmd_search(args):
    embedder = Embedder(args.model)
    index = SearchIndex(args.index)
    t0 = time.time()
    hits = index.search(embedder.encode(args.query, role="query")[0], k=args.k)
    for hit in hits:
        print(f"{hit['score']:.3f}  {hit['zim']}  {hit['path']}")
    print(f"({(time.time() - t0) * 1000:.0f} ms)", file=sys.stderr)


def main(argv=None):
    p = argparse.ArgumentParser(prog="search")
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument("--index", default=INDEX_DIR)
    sub = p.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="ZIM dosyalarını indeksle / index ZIM files")
    b.add_argument("zims", nargs="+")
    b.add_argument("--workers", type=int, default=None, help="gömme süreçleri / embedding processes")
    b.set_defaults(func=cmd_build)

    s = sub.add_parser("search", help="indekste ara / search the index")
    s.add_argument("query")
    s.add_argument("-k", type=int, default=10)
    s.set_defaults(func=cmd_search)

    args = p.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
