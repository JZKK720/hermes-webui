"""Regression tests for #926 Hindsight dependency in Docker WebUI venv."""
import pathlib


REPO_ROOT = pathlib.Path(__file__).parent.parent
INIT_SH = (REPO_ROOT / "docker_init.bash").read_text(encoding="utf-8")
REQUIREMENTS_TXT = (REPO_ROOT / "requirements.txt").read_text(encoding="utf-8")


def test_926_docker_init_installs_hindsight_distribution():
    """Docker init must still know how to install the hindsight-client distribution."""
    assert '/app/venv/bin/python -c "import hindsight_client"' in INIT_SH
    assert '"hindsight-client>=0.4.22"' in INIT_SH
    assert 'uv pip install "${_hindsight_client_requirement}"' in INIT_SH
    assert "if is_reduced_functionality_attach_mode; then" in INIT_SH


def test_926_hindsight_install_can_be_skipped_in_reduced_attach_mode():
    """Reduced-functionality attach mode must not block startup on hindsight-client."""
    assert "== Skipping optional Hindsight memory provider dependency in reduced-functionality mode" in INIT_SH
    assert "is_reduced_functionality_attach_mode()" in INIT_SH


def test_926_hindsight_install_runs_after_fast_restart_guard():
    """Existing Docker venvs with .deps_installed must still get hindsight-client."""
    deps_guard_pos = INIT_SH.find("if [ -f /app/venv/.deps_installed ]; then")
    assert deps_guard_pos != -1, ".deps_installed fast-restart guard not found"

    call_after_guard_pos = INIT_SH.find("\nensure_hindsight_client_docker_dependency\n", deps_guard_pos)
    assert call_after_guard_pos != -1, (
        "hindsight-client install check must run outside the .deps_installed guard "
        "so old Docker venvs self-heal on fast restart"
    )

    ensure_extra_shell_pos = INIT_SH.find("\nensure_extra_shell_python_packages\n", call_after_guard_pos)
    assert ensure_extra_shell_pos != -1 and call_after_guard_pos < ensure_extra_shell_pos, (
        "hindsight-client install check must still run before the extra shell-package "
        "self-heal hook on restart"
    )


def test_926_hindsight_dependency_stays_docker_specific():
    """Local non-Docker bootstrap should not install optional memory clients."""
    assert "hindsight-client" not in REQUIREMENTS_TXT


def test_extra_shell_python_packages_hook_exists_for_docker_attach_workflows():
    """Docker init must support persistent shell-visible Python packages via env."""
    assert "HERMES_WEBUI_EXTRA_SHELL_PYTHON_PACKAGES" in INIT_SH
    assert 'uv pip install --target "$_shell_python_target"' in INIT_SH
    assert 'export PYTHONPATH="$_shell_python_target${PYTHONPATH:+:$PYTHONPATH}"' in INIT_SH


def test_reportlab_shell_package_uses_uv_target_install_path():
    """reportlab should use the persistent uv target path in the attach image."""
    assert 'shell_python_target_dir()' in INIT_SH
    assert 'shell_python_target_has_packages()' in INIT_SH
    assert 'import reportlab' in INIT_SH
    assert 'reportlab is not importable yet; reinstalling' in INIT_SH
    assert 'reportlab requested but is not importable from $_shell_python_target' in INIT_SH


def test_extra_shell_python_packages_can_be_skipped_in_reduced_attach_mode():
    """Reduced-functionality attach mode must not block startup on shell extras."""
    assert "== Skipping optional shell Python package bootstrap in reduced-functionality mode" in INIT_SH


def test_extra_shell_python_packages_run_after_fast_restart_guard():
    """Existing Docker venvs must still self-heal extra shell packages on restart."""
    deps_guard_pos = INIT_SH.find("if [ -f /app/venv/.deps_installed ]; then")
    assert deps_guard_pos != -1, ".deps_installed fast-restart guard not found"

    expected_sequence = "\nensure_hindsight_client_docker_dependency\nensure_extra_shell_python_packages\n"
    call_after_guard_pos = INIT_SH.find(expected_sequence, deps_guard_pos)
    assert call_after_guard_pos != -1, (
        "extra shell Python package install check must run outside the .deps_installed "
        "guard so recreated attach containers regain requested shell libraries"
    )


def test_prepare_runtime_owned_paths_covers_persisted_venv_volume():
    """Fresh /app/venv volume mounts must be chowned before uv venv runs."""
    assert '_venv_dir=/app/venv' in INIT_SH
    assert 'mkdir -p "${_venv_dir}"' in INIT_SH
    assert 'chown ${WANTED_UID}:${WANTED_GID} "${_venv_dir}"' in INIT_SH
