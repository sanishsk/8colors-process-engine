#!/usr/bin/env python3
"""
research_embed.py — chunking, embedding providers, and provider resolution.

The half of the research index that turns markdown into vectors:
paragraph-aware chunking, the Embedder ABC and its four concrete
providers (fastembed, voyage, gemini, openai), and the resolution order
that picks one — CLI flag, then .process-engine.yaml, then env
detection, then the local default.

Split out of research_index.py in v0.52.0. That file was 1027 lines
against the engine's own 800-line budget and was exempted by name in
tests/test_size_budget_repo.sh's KNOWN_OVER list. The cut is one-way:
nothing here imports from research_index, which is what makes it a seam
rather than a rearrangement — this module knows how to make a vector and
nothing about where vectors are stored or searched.

Requires numpy. One provider package, per the provider chosen.
"""

from __future__ import annotations

import os
import re
import sys
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Optional


# ─── chunking ────────────────────────────────────────────────────────────────

CHUNK_SIZE = 800
CHUNK_OVERLAP = 120
MIN_CHUNK = 100

# P2.11: BGE-small (fastembed default) truncates at ~512 tokens ≈
# 2000 chars. Long code blocks or wall-of-text paragraphs above this
# would be silently truncated, dropping the tail from the embedding.
# Split oversized paragraphs before chunking so every produced chunk
# fits within CHUNK_SIZE.
MAX_PARA_CHARS = CHUNK_SIZE


def _split_oversized_para(para: str, max_chars: int) -> list[str]:
    """Split a single oversized paragraph into ≤ max_chars slices at
    the nearest sentence / newline / word boundary (P2.11)."""
    out: list[str] = []
    remaining = para
    while len(remaining) > max_chars:
        # Prefer boundaries in this order: sentence, newline, space.
        window = remaining[:max_chars]
        cut = max(
            window.rfind(". "),
            window.rfind("\n"),
            window.rfind(" "),
        )
        if cut <= max_chars // 2:
            cut = max_chars  # hard split — para has no boundaries
        out.append(remaining[:cut].rstrip())
        remaining = remaining[cut:].lstrip()
    if remaining:
        out.append(remaining)
    return out


def chunk_markdown(text: str) -> list[str]:
    """Paragraph-aware chunking with overlap.

    P2.11: pre-splits paragraphs larger than MAX_PARA_CHARS so
    long code blocks aren't silently truncated by the embedder.
    """
    raw_paras = re.split(r"\n\s*\n", text.strip())
    paras: list[str] = []
    for p in raw_paras:
        p = p.strip()
        if not p:
            continue
        if len(p) > MAX_PARA_CHARS:
            paras.extend(_split_oversized_para(p, MAX_PARA_CHARS))
        else:
            paras.append(p)
    if not paras:
        return []

    chunks: list[str] = []
    current = ""
    for para in paras:
        if not current:
            current = para
        elif len(current) + len(para) + 2 <= CHUNK_SIZE:
            current = f"{current}\n\n{para}"
        else:
            chunks.append(current)
            tail = current[-CHUNK_OVERLAP:] if len(current) > CHUNK_OVERLAP else current
            current = f"{tail}\n\n{para}" if tail else para
    if current and len(current) >= MIN_CHUNK:
        chunks.append(current)
    elif current and chunks:
        chunks[-1] = f"{chunks[-1]}\n\n{current}"
    return chunks


# ─── embedder ABC + concrete providers ──────────────────────────────────────


class Embedder(ABC):
    """Provider-agnostic embedding interface."""

    NAME: str = "abstract"
    MODEL: str = "abstract"
    DIM: int = 0

    @abstractmethod
    def embed_doc(self, text: str) -> list[float]:
        """Embed a document chunk (for indexing)."""

    @abstractmethod
    def embed_query(self, text: str) -> list[float]:
        """Embed a query string. Providers with asymmetric task_types use them here."""

    def embed_docs_batch(self, texts: list[str]) -> list[list[float]]:
        """Default batching: loop over embed_doc. Providers can
        override with a real batch API (see FastEmbedEmbedder)."""
        return [self.embed_doc(t) for t in texts]


class FastEmbedEmbedder(Embedder):
    """Fully local. Default. No API key required.

    Uses BAAI/bge-small-en-v1.5 by default (384 dims, ~33 MB model).
    First call downloads the model to ~/.cache/fastembed/.
    """

    NAME = "fastembed"
    MODEL = "BAAI/bge-small-en-v1.5"
    DIM = 384

    def __init__(self, model: Optional[str] = None) -> None:
        # P2.11: catch both ImportError AND TypeError. Protobuf under
        # Python 3.14 raises TypeError from within fastembed's transit
        # deps ("Descriptors cannot not be created directly …") — the
        # old handler let that traceback through raw. The documented
        # incident under Python 3.14 was invisible from the user's POV.
        try:
            from fastembed import TextEmbedding
        except (ImportError, TypeError) as exc:
            raise RuntimeError(
                "fastembed not installed OR incompatible with this Python.\n"
                f"  Root cause: {type(exc).__name__}: {exc}\n"
                "  Fix: pip install --upgrade fastembed protobuf, or run\n"
                "       against a Python version where fastembed builds\n"
                "       cleanly (3.11–3.13 known-good as of 2026-07).\n"
                "  (fastembed adds ~150 MB of ONNX runtime + downloads a\n"
                "  ~33 MB model on first use to ~/.cache/fastembed/.)"
            ) from exc

        self.MODEL = model or self.MODEL
        self._embedding_model = TextEmbedding(model_name=self.MODEL)

    def _embed(self, text: str) -> list[float]:
        # fastembed yields a generator; take the first (only) result.
        vecs = list(self._embedding_model.embed([text]))
        return vecs[0].tolist()

    def embed_doc(self, text: str) -> list[float]:
        return self._embed(text)

    def embed_query(self, text: str) -> list[float]:
        # BGE benefits from a "query:" prefix on retrieval queries.
        return self._embed(f"query: {text}")

    def embed_docs_batch(self, texts: list[str]) -> list[list[float]]:
        """P2.11: batch embedding for the rebuild loop. Single-text
        `embed()` calls in a loop create per-chunk overhead that
        dominates rebuild time on large corpora."""
        if not texts:
            return []
        vecs = list(self._embedding_model.embed(texts))
        return [v.tolist() for v in vecs]


class GeminiEmbedder(Embedder):
    """Google Gemini text-embedding-004 (768 dims). Free tier covers RAG."""

    NAME = "gemini"
    MODEL = "models/text-embedding-004"
    DIM = 768

    def __init__(self, model: Optional[str] = None) -> None:
        api_key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
        if not api_key:
            raise RuntimeError(
                "GEMINI_API_KEY not set. Get a free key at "
                "https://aistudio.google.com/apikey then "
                "`export GEMINI_API_KEY=AIza...`."
            )

        try:
            import google.generativeai as genai
        except ImportError as exc:
            raise RuntimeError(
                "google-generativeai not installed. "
                "Run: pip install google-generativeai"
            ) from exc

        self.MODEL = model or self.MODEL
        genai.configure(api_key=api_key)
        self._genai = genai

    def embed_doc(self, text: str) -> list[float]:
        result = self._genai.embed_content(
            model=self.MODEL,
            content=text,
            task_type="RETRIEVAL_DOCUMENT",
        )
        return result["embedding"]

    def embed_query(self, text: str) -> list[float]:
        result = self._genai.embed_content(
            model=self.MODEL,
            content=text,
            task_type="RETRIEVAL_QUERY",
        )
        return result["embedding"]


class VoyageEmbedder(Embedder):
    """Voyage AI voyage-3 (1024 dims). Anthropic-recommended partner."""

    NAME = "voyage"
    MODEL = "voyage-3"
    DIM = 1024

    def __init__(self, model: Optional[str] = None) -> None:
        api_key = os.environ.get("VOYAGE_API_KEY")
        if not api_key:
            raise RuntimeError(
                "VOYAGE_API_KEY not set. Sign up at https://www.voyageai.com/ "
                "(free credit available) then `export VOYAGE_API_KEY=...`."
            )

        try:
            import voyageai
        except ImportError as exc:
            raise RuntimeError(
                "voyageai not installed. Run: pip install voyageai"
            ) from exc

        self.MODEL = model or self.MODEL
        self._client = voyageai.Client(api_key=api_key)

    def embed_doc(self, text: str) -> list[float]:
        result = self._client.embed(
            [text], model=self.MODEL, input_type="document"
        )
        return result.embeddings[0]

    def embed_query(self, text: str) -> list[float]:
        result = self._client.embed(
            [text], model=self.MODEL, input_type="query"
        )
        return result.embeddings[0]


class OpenAIEmbedder(Embedder):
    """OpenAI text-embedding-3-small (1536 dims). Paid but cheap."""

    NAME = "openai"
    MODEL = "text-embedding-3-small"
    DIM = 1536

    def __init__(self, model: Optional[str] = None) -> None:
        api_key = os.environ.get("OPENAI_API_KEY")
        if not api_key:
            raise RuntimeError(
                "OPENAI_API_KEY not set. Get one at https://platform.openai.com/ "
                "then `export OPENAI_API_KEY=sk-...`."
            )

        try:
            from openai import OpenAI
        except ImportError as exc:
            raise RuntimeError(
                "openai not installed. Run: pip install openai"
            ) from exc

        self.MODEL = model or self.MODEL
        self._client = OpenAI(api_key=api_key)

    def _embed(self, text: str) -> list[float]:
        # OpenAI's embedding API has no document/query asymmetry.
        result = self._client.embeddings.create(model=self.MODEL, input=text)
        return result.data[0].embedding

    def embed_doc(self, text: str) -> list[float]:
        return self._embed(text)

    def embed_query(self, text: str) -> list[float]:
        return self._embed(text)


PROVIDERS = {
    "fastembed": FastEmbedEmbedder,
    "gemini": GeminiEmbedder,
    "voyage": VoyageEmbedder,
    "openai": OpenAIEmbedder,
}


# ─── provider resolution ────────────────────────────────────────────────────


# Why read_yaml_field tracks indent rather than just scanning for the key:
# it used to descend into sibling top-level blocks when the expected child
# was missing. For keys=("rag", "provider") against
#
#     some_block:
#       provider: A       # wrong parent, but same indent
#     rag:
#       model: bge-small  # no `provider:` here
#
# the old walker matched some_block.provider, because it kept scanning past
# `some_block:` without noticing it had left the parent scope. The fix is
# the `line_indent < indent` bail-out below: going shallower than the target
# indent means the parent block ended and the child key does not exist.
def read_yaml_field(path: Path, *keys: str) -> Optional[str]:
    """Minimal YAML reader — scalar values under nested keys only.

    Scope-aware — see the comment above for the sibling-block confusion
    the indent tracking exists to prevent.
    """
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    indent = 0
    i = 0
    for depth, part in enumerate(keys):
        found = False
        while i < len(lines):
            line = lines[i]
            # Skip blank / comment-only lines cheaply.
            if not line.strip() or line.lstrip().startswith("#"):
                i += 1
                continue
            stripped = line.lstrip(" ")
            line_indent = len(line) - len(stripped)

            # If we've gone SHALLOWER than the target indent while
            # searching for a child, the parent block ended — the
            # child key doesn't exist.
            if depth > 0 and line_indent < indent:
                return None

            if line_indent == indent and stripped.startswith(part + ":"):
                rest = stripped[len(part) + 1 :].strip().strip('"').strip("'")
                if rest and part == keys[-1]:
                    return rest
                indent += 2
                i += 1
                found = True
                break
            i += 1
        if not found:
            return None
    return None


def detect_provider_from_env() -> Optional[str]:
    """Return the first provider whose API key env-var is set."""
    if os.environ.get("VOYAGE_API_KEY"):
        return "voyage"
    if os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY"):
        return "gemini"
    if os.environ.get("OPENAI_API_KEY"):
        return "openai"
    return None


def resolve_provider(
    cli_provider: Optional[str], project_root: Path
) -> tuple[str, Optional[str]]:
    """Return (provider_name, model_name_or_None).

    Resolution order:
        1. --provider CLI flag
        2. .process-engine.yaml rag.provider
        3. Env detection (VOYAGE/GEMINI/OPENAI key set)
        4. fastembed default
    """
    if cli_provider:
        if cli_provider not in PROVIDERS:
            raise SystemExit(
                f"ERROR: unknown provider {cli_provider!r}. "
                f"Options: {', '.join(PROVIDERS)}"
            )
        return cli_provider, None

    config = project_root / ".process-engine.yaml"
    yaml_provider = read_yaml_field(config, "rag", "provider")
    yaml_model = read_yaml_field(config, "rag", "model")
    if yaml_provider:
        if yaml_provider not in PROVIDERS:
            raise SystemExit(
                f"ERROR: unknown rag.provider {yaml_provider!r} in "
                f"{config}. Options: {', '.join(PROVIDERS)}"
            )
        return yaml_provider, yaml_model

    env_provider = detect_provider_from_env()
    if env_provider:
        return env_provider, None

    return "fastembed", None


def make_embedder(name: str, model: Optional[str]) -> Embedder:
    cls = PROVIDERS[name]
    return cls(model=model)


