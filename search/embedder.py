"""Cevher Nüve modelini ONNX Runtime ile çalıştırır (Pi 5 dahil, CPU).

Tek süreç tek çekirdek kullanır; indeks kurarken `ParallelEmbedder(workers=N)`
ile N sürece bölünür. Pi 5'in 4 çekirdeğinde bu ~3–4× hız demek.
"""
import json
import multiprocessing as mp
import os
from pathlib import Path

import numpy as np

ROLE_TOKENS = {"query": "[QRY]", "doc": "[DOC]", "sym": "[SYM]"}
DEFAULT_MODEL = "/library/models/cevher-nuve"


class Embedder:
    def __init__(self, model_dir, threads=1):
        import onnxruntime as ort
        from transformers import PreTrainedTokenizerFast

        self.dir = Path(model_dir)
        self.cfg = json.loads((self.dir / "config.json").read_text())
        self.tok = PreTrainedTokenizerFast.from_pretrained(str(self.dir))
        self.role_ids = {r: self.tok.convert_tokens_to_ids(t) for r, t in ROLE_TOKENS.items()}
        self.max_length = int(self.cfg.get("max_length", 256))
        self.pad_id = self.tok.pad_token_id if self.tok.pad_token_id is not None else 0
        self.dim = int(self.cfg.get("dim", 256))

        opts = ort.SessionOptions()
        opts.intra_op_num_threads = threads
        opts.inter_op_num_threads = 1
        model = self.dir / "onnx" / "model.onnx"
        if not model.exists():
            raise FileNotFoundError(f"{model} yok / missing — önce ./scripts/download-model.sh")
        self.sess = ort.InferenceSession(str(model), sess_options=opts, providers=["CPUExecutionProvider"])

    def _batch(self, texts, role):
        rid = self.role_ids[role]
        ids = self.tok(list(texts), add_special_tokens=False, truncation=True, max_length=self.max_length - 1)["input_ids"]
        ids = [[rid] + row for row in ids]
        width = max(len(row) for row in ids)
        x = np.full((len(ids), width), self.pad_id, dtype=np.int64)
        mask = np.zeros((len(ids), width), dtype=np.int64)
        for i, row in enumerate(ids):
            x[i, : len(row)] = row
            mask[i, : len(row)] = 1
        return x, mask

    def encode(self, texts, role="doc", batch_size=64):
        """L2-normalize edilmiş vektörler: float32 [n, dim]."""
        texts = [texts] if isinstance(texts, str) else list(texts)
        out = np.empty((len(texts), self.dim), dtype=np.float32)
        for i in range(0, len(texts), batch_size):
            ids, mask = self._batch([t if t and t.strip() else " " for t in texts[i : i + batch_size]], role)
            out[i : i + batch_size] = self.sess.run(None, {"input_ids": ids, "attention_mask": mask})[0]
        norm = np.linalg.norm(out, axis=1, keepdims=True)
        return out / np.clip(norm, 1e-12, None)


_EMBEDDER = None


def _worker_init(model_dir):
    global _EMBEDDER
    _EMBEDDER = Embedder(model_dir)


def _worker_encode(job):
    texts, role, batch_size = job
    return _EMBEDDER.encode(texts, role=role, batch_size=batch_size)


class ParallelEmbedder:
    """Pencere gömmeyi birden fazla sürece dağıtır; sıra korunur."""

    def __init__(self, model_dir, workers=None):
        self.model_dir = model_dir
        self.dim = int(json.loads((Path(model_dir) / "config.json").read_text()).get("dim", 256))
        self.workers = workers or os.cpu_count() or 1
        self.pool = None
        if self.workers > 1:
            ctx = mp.get_context("fork")  # yalnızca Linux / Raspberry Pi OS
            self.pool = ctx.Pool(self.workers, initializer=_worker_init, initargs=(model_dir,))

    def encode(self, texts, role="doc", batch_size=64):
        texts = list(texts)
        if not texts:
            return np.zeros((0, self.dim), dtype=np.float32)
        if self.pool is None:
            _worker_init(self.model_dir)  # tek çekirdek: iş bu süreçte kalır / single core
            return _worker_encode((texts, role, batch_size))
        size = max(1, (len(texts) + self.workers - 1) // self.workers)
        jobs = [(texts[i : i + size], role, batch_size) for i in range(0, len(texts), size)]
        return np.concatenate(self.pool.map(_worker_encode, jobs))

    def close(self):
        if self.pool is not None:
            self.pool.close()
            self.pool.join()


def chunk_words(text, words=56, stride=40):
    """Model kartındaki parçalama: 56 kelimelik pencereler, 40 kelime adım."""
    w = text.split()
    if len(w) <= words:
        return [text] if text else [" "]
    starts = list(range(0, len(w) - words + 1, stride))
    if starts[-1] + words < len(w):
        starts.append(len(w) - words)
    return [" ".join(w[s : s + words]) for s in starts]


def quantize(vecs):
    """int8 indeks: bileşen başına sabit ölçek ([-1, 1] normalize vektörler)."""
    return np.round(np.clip(vecs, -1, 1) * 127).astype(np.int8)


def dequantize(vecs):
    return vecs.astype(np.float32) / 127.0
