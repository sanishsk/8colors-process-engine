"""tests/test_api_credentials.py — coverage floor for the module.

Every project that materializes this module inherits these tests.
Extend them (don't replace) with project-specific integration tests.
"""

from __future__ import annotations

import os
from unittest import mock

import pytest
from cryptography.fernet import Fernet


@pytest.fixture(autouse=True)
def _master_key(monkeypatch):
    monkeypatch.setenv("CREDENTIALS_MASTER_KEY", Fernet.generate_key().decode())
    from modules.api_credentials import credential_service
    credential_service.invalidate_cache()
    yield
    credential_service.invalidate_cache()


class TestEncryption:
    def test_roundtrip(self):
        from modules.api_credentials.credential_service import (
            encrypt_for_storage, _master_fernet,
        )
        encrypted, last_four = encrypt_for_storage("sk_test_1234567890abcdef")
        assert last_four == "cdef"
        # Decrypt via the same key to prove roundtrip works.
        f = _master_fernet()
        assert f is not None
        assert f.decrypt(encrypted).decode() == "sk_test_1234567890abcdef"

    def test_write_requires_master_key(self, monkeypatch):
        monkeypatch.delenv("CREDENTIALS_MASTER_KEY", raising=False)
        from modules.api_credentials.credential_service import encrypt_for_storage
        with pytest.raises(RuntimeError, match="MASTER_KEY"):
            encrypt_for_storage("x" * 32)


class TestFallback:
    def test_env_var_fallback(self, monkeypatch):
        monkeypatch.setenv("ANTHROPIC_API_KEY", "env-fallback-value")
        # Ensure DB path returns nothing by keeping modules.db unimportable.
        from modules.api_credentials.credential_service import get_credential
        assert get_credential("anthropic") == "env-fallback-value"

    def test_returns_none_when_unset(self, monkeypatch):
        monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
        from modules.api_credentials.credential_service import get_credential
        assert get_credential("anthropic") is None

    def test_unknown_provider_returns_none(self):
        from modules.api_credentials.credential_service import get_credential
        assert get_credential("no-such-provider") is None


class TestCache:
    def test_cache_hit_avoids_second_env_read(self, monkeypatch):
        monkeypatch.setenv("ANTHROPIC_API_KEY", "v1")
        from modules.api_credentials.credential_service import get_credential
        assert get_credential("anthropic") == "v1"
        monkeypatch.setenv("ANTHROPIC_API_KEY", "v2")
        # Cache should still return v1 — no round-trip.
        assert get_credential("anthropic") == "v1"

    def test_invalidate_clears_specific_provider(self, monkeypatch):
        monkeypatch.setenv("ANTHROPIC_API_KEY", "v1")
        monkeypatch.setenv("OPENAI_API_KEY", "o1")
        from modules.api_credentials.credential_service import (
            get_credential, invalidate_cache,
        )
        assert get_credential("anthropic") == "v1"
        assert get_credential("openai") == "o1"
        invalidate_cache("anthropic")
        monkeypatch.setenv("ANTHROPIC_API_KEY", "v2")
        # anthropic re-reads, openai stays cached.
        assert get_credential("anthropic") == "v2"
        monkeypatch.setenv("OPENAI_API_KEY", "o2")
        assert get_credential("openai") == "o1"


class TestNoLogging:
    def test_plaintext_never_in_logs(self, caplog, monkeypatch):
        monkeypatch.setenv("ANTHROPIC_API_KEY", "top-secret-should-never-log")
        from modules.api_credentials.credential_service import get_credential
        with caplog.at_level("DEBUG"):
            get_credential("anthropic")
        for record in caplog.records:
            assert "top-secret-should-never-log" not in record.getMessage()
