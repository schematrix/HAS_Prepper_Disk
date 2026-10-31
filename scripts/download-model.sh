#!/usr/bin/env bash
# Cevher Nüve gömme modelini indirir (semantik arama için).
# Downloads the Cevher Nüve embedding model (used by semantic search).
#
# Sadece ONNX ağırlığı indirilir (~58 MB): Pi'de PyTorch gerekmez.
# Only the ONNX weight is downloaded (~58 MB): no PyTorch needed on the Pi.
#
# Kullanım / usage:  sudo ./scripts/download-model.sh
set -euo pipefail

REPO_ID="${REPO_ID:-batuhanozkose/cevher-nuve}"
SHA256="${SHA256:-}"  # istenirse doğrulama / optional checksum for onnx/model.onnx
REVISION="${REVISION:-main}"  # üretimde sabit commit sha önerilir / pin a commit sha in production
DST="${DST:-/library/models/cevher-nuve}"
BASE="https://huggingface.co/$REPO_ID/resolve/$REVISION"

mkdir -p "$DST/onnx"
for f in config.json tokenizer.json tokenizer_config.json onnx/model.onnx; do
  echo ">> $f"
  curl -fL --retry 3 -C - -o "$DST/$f" "$BASE/$f"
done
if [ -n "$SHA256" ]; then
  echo "$SHA256  $DST/onnx/model.onnx" | sha256sum -c - || { echo "!! sha256 uyuşmadı / mismatch" >&2; exit 1; }
fi
echo "Model hazır / model ready: $DST"
