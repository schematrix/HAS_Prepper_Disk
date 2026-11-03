#!/usr/bin/env bash
# Cevher Nüve gömme modelini indirir (semantik arama için).
# Downloads the Cevher Nüve embedding model (used by semantic search).
#
# Sadece ONNX ağırlığı indirilir (~58 MB): Pi'de PyTorch gerekmez.
# Only the ONNX weight is downloaded (~58 MB): no PyTorch needed on the Pi.
#
# Model tek bir commit'e ve SHA-256 özetine sabitlenir; "main" dalı ilerlediğinde
# indirilen dosyalar sessizce değişmez. Yeni sürüm için REVISION ve SHA256 güncellenir.
# Pinned to one commit and checksum so a later push to the model repo cannot change it.
#
# Kullanım / usage:  sudo ./scripts/download-model.sh
set -euo pipefail

REPO_ID="${REPO_ID:-batuhanozkose/cevher-nuve}"
REVISION="${REVISION:-6d1aa0259883f494879c9e0b35273bb8b6000028}"
SHA256="${SHA256:-0060d5af84acd79cb3cf4464c3da72024fde3fbc77030cc86152372c8f767a5b}"
DST="${DST:-/library/models/cevher-nuve}"
BASE="https://huggingface.co/$REPO_ID/resolve/$REVISION"

mkdir -p "$DST/onnx"
for f in config.json tokenizer.json tokenizer_config.json onnx/model.onnx; do
  echo ">> $f"
  curl -fL --retry 3 -C - -o "$DST/$f" "$BASE/$f"
done
echo "$SHA256  $DST/onnx/model.onnx" | sha256sum -c - || { echo "!! sha256 uyuşmadı / mismatch" >&2; exit 1; }
echo "Model hazır / model ready: $DST"
