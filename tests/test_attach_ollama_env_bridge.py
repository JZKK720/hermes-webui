"""Structural regressions for existing-agent attach Ollama env bridging."""
import pathlib


REPO_ROOT = pathlib.Path(__file__).parent.parent
INIT_SH = (REPO_ROOT / "docker_init.bash").read_text(encoding="utf-8")
ATTACH_COMPOSE = (REPO_ROOT / "docker-compose.existing-agent.yml").read_text(encoding="utf-8")
DOCKER_ENV_EXAMPLE = (REPO_ROOT / ".env.docker.example").read_text(encoding="utf-8")
LOCAL_ENV_EXAMPLE = (REPO_ROOT / ".env.example").read_text(encoding="utf-8")


def test_attach_compose_passes_repo_ollama_env_into_container():
    """Repo-local attach env must be forwarded into the existing-agent container."""
    assert "- OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-}" in ATTACH_COMPOSE
    assert "- OLLAMA_API_KEY=${OLLAMA_API_KEY:-}" in ATTACH_COMPOSE
    assert "- HERMES_MODEL=${HERMES_MODEL:-}" in ATTACH_COMPOSE


def test_attach_docker_init_syncs_repo_ollama_env_into_shared_runtime():
    """Attach startup must mirror repo-local Ollama env into Hermes home/config."""
    assert "ensure_attach_ollama_runtime_config()" in INIT_SH
    assert 'env_updates["OLLAMA_BASE_URL"] = base_url' in INIT_SH
    assert 'env_updates["OLLAMA_API_KEY"] = api_key' in INIT_SH
    assert 'model_cfg["provider"] = "custom"' in INIT_SH
    assert 'model_cfg["base_url"] = base_url' in INIT_SH
    assert 'model_cfg["default"] = model' in INIT_SH


def test_attach_ollama_bridge_runs_after_fast_restart_guard():
    """Existing Docker venvs must still re-apply attach Ollama env on restart."""
    deps_guard_pos = INIT_SH.find("if [ -f /app/venv/.deps_installed ]; then")
    assert deps_guard_pos != -1, ".deps_installed fast-restart guard not found"

    expected_sequence = (
        "\nensure_hindsight_client_docker_dependency\n"
        "ensure_extra_shell_python_packages\n"
        "ensure_attach_ollama_runtime_config\n"
    )
    call_after_guard_pos = INIT_SH.find(expected_sequence, deps_guard_pos)
    assert call_after_guard_pos != -1, (
        "attach-mode Ollama env sync must run outside the .deps_installed guard "
        "so recreated containers keep the repo-local runtime override"
    )


def test_env_templates_document_local_and_attach_ollama_values():
    """Both env templates should show the supported Ollama override keys."""
    assert "# HERMES_MODEL=nemotron3:33b-q8" in LOCAL_ENV_EXAMPLE
    assert "# OLLAMA_BASE_URL=http://127.0.0.1:11434/v1" in LOCAL_ENV_EXAMPLE
    assert "# OLLAMA_API_KEY=no-key-required" in LOCAL_ENV_EXAMPLE
    assert "# OLLAMA_BASE_URL=http://host.docker.internal:11434/v1" in DOCKER_ENV_EXAMPLE
    assert "# HERMES_MODEL=nemotron3:33b-q8" in DOCKER_ENV_EXAMPLE