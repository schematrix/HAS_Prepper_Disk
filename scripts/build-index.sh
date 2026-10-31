#!/usr/bin/env bash
# config/content.conf içindeki "# index" ile işaretli ZIM'ler için semantik arama indeksi kurar.
# Builds the semantic search index for the ZIM files marked "# index" in config/content.conf.
#
# Varsayılan olarak hiçbir ZIM indekslenmez; content.conf'taki örnek satırı silmek serbest.
# Nothing is indexed by default; the example line in content.conf can be removed.
#
# Kullanım / usage:  sudo ./scripts/build-index.sh [config-dosyası]
#   env: INDEX_DIR (varsayılan /library/index), WORKERS (paralel süreç sayısı)
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "sudo ile çalıştır / run with sudo" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="${1:-$ROOT/config/content.conf}"
ZIM_DIR=/library/zims/content
INDEX_DIR="${INDEX_DIR:-/library/index}"
MODEL_DIR=/library/models/cevher-nuve

[ -f "$MODEL_DIR/onnx/model.onnx" ] || "$ROOT/scripts/download-model.sh"
python3 -c "import numpy, onnxruntime, transformers" 2>/dev/null || {
  echo "!! numpy, onnxruntime ve transformers gerekli / required: sudo apt install -y python3-numpy && pip3 install onnxruntime transformers" >&2
  exit 1
}

zims=()
while read -r folder prefix rest; do
  case "$folder" in ''|\#*) continue;; esac
  case " $rest " in *" index "*) ;; *) continue;; esac
  latest=$(ls -1 "$ZIM_DIR/${prefix}"_*.zim 2>/dev/null | sort | tail -1 || true)
  if [ -z "$latest" ]; then echo "!! $prefix yüklü değil, atlandı / not downloaded, skipped"; continue; fi
  zims+=("$latest")
done < "$CONF"

[ "${#zims[@]}" -gt 0 ] || { echo "content.conf içinde 'index' işaretli yüklü ZIM yok / no installed ZIM marked 'index'"; exit 0; }

echo ">> ${#zims[@]} ZIM indeksleniyor / indexing"
cd "$ROOT"
exec python3 -m search.cli --index "$INDEX_DIR" build ${WORKERS:+--workers "$WORKERS"} "${zims[@]}"
