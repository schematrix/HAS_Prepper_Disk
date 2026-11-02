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
# Sunucu ve indeks aynı bağımlılıkları kullanır / service and index share one environment
VENV=/library/.venv

[ -f "$MODEL_DIR/onnx/model.onnx" ] || "$ROOT/scripts/download-model.sh"
python3 -c "import libzim" 2>/dev/null || {
  echo "!! libzim gerekli / required: sudo apt install -y python3-libzim" >&2
  exit 1
}
# Raspberry Pi OS Bookworm sistem Python'una pip yazmayı engeller (PEP 668);
# bağımlılıklar depo dışı olduğu için venv içine kurulur.
if [ ! -x "$VENV/bin/python" ]; then
  echo ">> venv oluşturuluyor / creating venv: $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
fi
if ! "$VENV/bin/python" -c "import numpy, onnxruntime, tokenizers" 2>/dev/null; then
  echo ">> bağımlılıklar kuruluyor / installing dependencies"
  "$VENV/bin/pip" install --quiet numpy onnxruntime tokenizers || {
    echo "!! kurulamadı / install failed: $VENV/bin/pip install numpy onnxruntime tokenizers" >&2
    exit 1
  }
fi

zims=()
while read -r folder prefix rest; do
  case "$folder" in ''|\#*) continue;; esac
  # Yalnızca yorumdan (#) önceki kısma bakılır; açıklamadaki "index" kelimesi işaret sayılmaz.
  fields="${rest%%#*}"
  case " $fields " in *" index "*) ;; *) continue;; esac
  latest=$(ls -1 "$ZIM_DIR/${prefix}"_*.zim 2>/dev/null | sort | tail -1 || true)
  if [ -z "$latest" ]; then echo "!! $prefix yüklü değil, atlandı / not downloaded, skipped"; continue; fi
  zims+=("$latest")
done < "$CONF"

[ "${#zims[@]}" -gt 0 ] || { echo "content.conf içinde 'index' işaretli yüklü ZIM yok / no installed ZIM marked 'index'"; exit 0; }

echo ">> ${#zims[@]} ZIM indeksleniyor / indexing"
cd "$ROOT"
exec "$VENV/bin/python" -m search.cli --index "$INDEX_DIR" build ${WORKERS:+--workers "$WORKERS"} "${zims[@]}"
