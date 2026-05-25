#!/bin/bash

set -e

error_exit() {
  echo -n "!! ERROR: "
  echo $*
  echo "!! Exiting script (ID: $$)"
  exit 1
}

ok_exit() {
  echo $*
  echo "++ Exiting script (ID: $$)"
  exit 0
}

## Environment variables loaded when passing environment variables from user to user
# Ignore list: variables to ignore when loading environment variables from user to user
export ENV_IGNORELIST="HOME PWD USER SHLVL TERM OLDPWD SHELL _ SUDO_COMMAND HOSTNAME LOGNAME MAIL SUDO_GID SUDO_UID SUDO_USER CHECK_NV_CUDNN_VERSION VIRTUAL_ENV VIRTUAL_ENV_PROMPT ENV_IGNORELIST ENV_OBFUSCATE_PART"
# Obfuscate part: part of the key to obfuscate when loading environment variables from user to user, ex: HF_TOKEN, ...
export ENV_OBFUSCATE_PART="TOKEN API KEY"

# Check for ENV_IGNORELIST and ENV_OBFUSCATE_PART
if [ -z "${ENV_IGNORELIST+x}" ]; then error_exit "ENV_IGNORELIST not set"; fi
if [ -z "${ENV_OBFUSCATE_PART+x}" ]; then error_exit "ENV_OBFUSCATE_PART not set"; fi

whoami=`whoami`
script_dir=$(dirname $0)
script_name=$(basename $0)
echo ""; echo ""
echo "======================================"
echo "=================== Starting script (ID: $$)"
echo "== Running ${script_name} in ${script_dir} as ${whoami}"
script_fullname=$0
echo "  - script_fullname: ${script_fullname}"
ignore_value="VALUE_TO_IGNORE"

# everyone can read our files by default
umask 0022

# Write a world-writeable file (preferably inside /tmp -- ie within the container)
write_worldtmpfile() {
  tmpfile=$1
  if [ -z "${tmpfile}" ]; then error_exit "write_worldfile: missing argument"; fi
  if [ -f $tmpfile ]; then rm -f $tmpfile; fi
  echo -n $2 > ${tmpfile}
  chmod 777 ${tmpfile}
}

itdir=/tmp/hermeswebui_init
if [ ! -d $itdir ]; then mkdir $itdir; chmod 777 $itdir; fi
if [ ! -d $itdir ]; then error_exit "Failed to create $itdir"; fi

# Set user and group id
# logic: if not set and file exists, use file value, else use default. Create file for persistence when the container is re-run
# reasoning: needed when using docker compose as the file will exist in the stopped container, and changing the value from environment variables or configuration file must be propagated from hermeswebuitoo to hermeswebuitoo transition (those values are the only ones loaded before the environment variables dump file are loaded)
it=$itdir/hermeswebui_user_uid
if [ -z "${WANTED_UID+x}" ]; then
  if [ -f $it ]; then WANTED_UID=$(cat $it); fi
fi
# Auto-detect from mounted volumes if still unset (#569, #668).
# On macOS, host UIDs start at 501. Using the wrong UID means the container

ensure_attach_ollama_runtime_config() {
  if [ -z "${OLLAMA_BASE_URL:-}" ] && [ -z "${OLLAMA_API_KEY:-}" ] && [ -z "${HERMES_MODEL:-}" ]; then
  return 0
  fi

  _attach_hermes_home=${HERMES_HOME:-/home/hermeswebui/.hermes}
  _attach_config_path=${HERMES_CONFIG_PATH:-${_attach_hermes_home}/config.yaml}
  _attach_env_path=${_attach_hermes_home}/.env

  echo ""; echo "== Applying attach-mode Ollama runtime config from environment"
  HERMES_ATTACH_OLLAMA_HOME="$_attach_hermes_home" \
  HERMES_ATTACH_OLLAMA_CONFIG="$_attach_config_path" \
  HERMES_ATTACH_OLLAMA_ENV="$_attach_env_path" \
  /app/venv/bin/python - <<'PY' || error_exit "Failed to apply attach-mode Ollama runtime config"
from pathlib import Path
import os
import stat

import yaml


def update_env_file(env_path: Path, updates: dict[str, str]) -> None:
  lines: list[str] = []
  if env_path.exists():
    lines = env_path.read_text(encoding="utf-8").splitlines()

  existing_keys: dict[str, int] = {}
  for idx, raw in enumerate(lines):
    stripped = raw.strip()
    if stripped and not stripped.startswith("#") and "=" in stripped:
      existing_keys[stripped.split("=", 1)[0].strip()] = idx

  output_lines = list(lines)
  new_keys: list[str] = []
  for key, value in updates.items():
    clean = str(value or "").strip()
    if not clean:
      continue
    if key in existing_keys:
      output_lines[existing_keys[key]] = f"{key}={clean}"
    else:
      new_keys.append(f"{key}={clean}")

  if new_keys:
    if output_lines and output_lines[-1].strip() != "":
      output_lines.append("")
    output_lines.extend(new_keys)

  env_path.parent.mkdir(parents=True, exist_ok=True)
  content = "\n".join(output_lines)
  if content:
    content += "\n"
  env_path.write_text(content, encoding="utf-8")
  env_path.chmod(stat.S_IRUSR | stat.S_IWUSR)


base_url = str(os.getenv("OLLAMA_BASE_URL") or "").strip().rstrip("/")
api_key = str(os.getenv("OLLAMA_API_KEY") or "").strip()
model = str(os.getenv("HERMES_MODEL") or "").strip()

hermes_home = Path(os.getenv("HERMES_ATTACH_OLLAMA_HOME") or "").expanduser()
config_path = Path(os.getenv("HERMES_ATTACH_OLLAMA_CONFIG") or "").expanduser()
env_path = Path(os.getenv("HERMES_ATTACH_OLLAMA_ENV") or "").expanduser()

env_updates: dict[str, str] = {}
if base_url:
  env_updates["OLLAMA_BASE_URL"] = base_url
if api_key:
  env_updates["OLLAMA_API_KEY"] = api_key
if env_updates:
  update_env_file(env_path, env_updates)

config_data: dict = {}
if config_path.exists():
  loaded = yaml.safe_load(config_path.read_text(encoding="utf-8"))
  if isinstance(loaded, dict):
    config_data = loaded

model_cfg = config_data.get("model")
if not isinstance(model_cfg, dict):
  model_cfg = {}

changed = False
if base_url:
  if str(model_cfg.get("provider") or "").strip() != "custom":
    model_cfg["provider"] = "custom"
    changed = True
  if str(model_cfg.get("base_url") or "").strip().rstrip("/") != base_url:
    model_cfg["base_url"] = base_url
    changed = True
if model:
  if str(model_cfg.get("default") or "").strip() != model:
    model_cfg["default"] = model
    changed = True

if changed:
  config_data["model"] = model_cfg
  config_path.parent.mkdir(parents=True, exist_ok=True)
  config_path.write_text(
    yaml.safe_dump(config_data, sort_keys=False, allow_unicode=True),
    encoding="utf-8",
  )

if hermes_home:
  hermes_home.mkdir(parents=True, exist_ok=True)
PY

  if [ -n "${OLLAMA_BASE_URL:-}" ]; then
  echo "-- Synced OLLAMA_BASE_URL into $_attach_env_path and $_attach_config_path"
  echo "-- Forced model.provider=custom for the local attach Ollama route"
  fi
  if [ -n "${OLLAMA_API_KEY:-}" ]; then
  echo "-- Synced OLLAMA_API_KEY into $_attach_env_path"
  fi
  if [ -n "${HERMES_MODEL:-}" ]; then
  echo "-- Synced HERMES_MODEL into $_attach_config_path as model.default"
  fi
}
# user cannot read the bind-mounted files, making the workspace appear empty.
# In two-container setups (hermes-agent + hermes-webui), the shared hermes-home
# volume may be owned by the agent container's UID — detect from there first.
if [ -z "${WANTED_UID+x}" ] || [ "${WANTED_UID}" = "1024" ]; then
  # Priority 1: hermes-home shared volume — covers two-container Zeabur/Compose setups (#668)
  for _probe_dir in "/home/hermeswebui/.hermes" "$HERMES_HOME" "/opt/data"; do
    if [ -d "$_probe_dir" ]; then
      _detected_uid=$(stat -c '%u' "$_probe_dir" 2>/dev/null || echo "")
      if [ -n "$_detected_uid" ] && [ "$_detected_uid" != "0" ]; then
        echo "-- Auto-detected UID: $_detected_uid (from $_probe_dir)"
        WANTED_UID=$_detected_uid
        break
      fi
    fi
  done
fi
if [ -z "${WANTED_UID+x}" ] || [ "${WANTED_UID}" = "1024" ]; then
  # Priority 2: /workspace bind-mount — the standard single-container mount point
  if [ -d "/workspace" ]; then
    _detected_uid=$(stat -c '%u' "/workspace" 2>/dev/null || echo "")
    if [ -n "$_detected_uid" ] && [ "$_detected_uid" != "0" ]; then
      echo "-- Auto-detected workspace UID: $_detected_uid (from /workspace)"
      WANTED_UID=$_detected_uid
    fi
  fi
fi
WANTED_UID=${WANTED_UID:-1024}
write_worldtmpfile $it "$WANTED_UID"
echo "-- WANTED_UID: \"${WANTED_UID}\""

it=$itdir/hermeswebui_user_gid
if [ -z "${WANTED_GID+x}" ]; then
  if [ -f $it ]; then WANTED_GID=$(cat $it); fi
fi
# Auto-detect GID from mounted volumes to match (#569, #668)
if [ -z "${WANTED_GID+x}" ] || [ "${WANTED_GID}" = "1024" ]; then
  # Priority 1: hermes-home shared volume
  for _probe_dir in "/home/hermeswebui/.hermes" "$HERMES_HOME" "/opt/data"; do
    if [ -d "$_probe_dir" ]; then
      _detected_gid=$(stat -c '%g' "$_probe_dir" 2>/dev/null || echo "")
      if [ -n "$_detected_gid" ] && [ "$_detected_gid" != "0" ]; then
        echo "-- Auto-detected GID: $_detected_gid (from $_probe_dir)"
        WANTED_GID=$_detected_gid
        break
      fi
    fi
  done
fi
if [ -z "${WANTED_GID+x}" ] || [ "${WANTED_GID}" = "1024" ]; then
  # Priority 2: /workspace bind-mount
  if [ -d "/workspace" ]; then
    _detected_gid=$(stat -c '%g' "/workspace" 2>/dev/null || echo "")
    if [ -n "$_detected_gid" ] && [ "$_detected_gid" != "0" ]; then
      echo "-- Auto-detected workspace GID: $_detected_gid (from /workspace)"
      WANTED_GID=$_detected_gid
    fi
  fi
fi
WANTED_GID=${WANTED_GID:-1024}
write_worldtmpfile $it "$WANTED_GID"
echo "-- WANTED_GID: \"${WANTED_GID}\""

echo "== Most Environment variables set"

# Check user id and group id
new_gid=`id -g`
new_uid=`id -u`
echo "== user ($whoami)"
echo "  uid: $new_uid / WANTED_UID: $WANTED_UID"
echo "  gid: $new_gid / WANTED_GID: $WANTED_GID"

save_env() {
  tosave=$1
  echo "-- Saving environment variables to $tosave"
  env | sort > "$tosave"
}

ensure_sudo_ready_for_hermeswebui() {
  if ! command -v sudo >/dev/null 2>&1; then
    echo "-- sudo not found in the image; installing it for the attach bootstrap flow"
    apt-get update || error_exit "Failed to refresh apt metadata while installing sudo"
    apt-get install -y --no-install-recommends sudo || error_exit "Failed to install sudo"
    rm -rf /var/lib/apt/lists/*
  fi

  if ! id -nG hermeswebui | tr ' ' '\n' | grep -qx sudo; then
    usermod -aG sudo hermeswebui || error_exit "Failed to add hermeswebui to the sudo group"
  fi

  if ! grep -qx '%sudo ALL=(ALL) NOPASSWD:ALL' /etc/sudoers; then
    echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers || error_exit "Failed to enable passwordless sudo for hermeswebui"
  fi
}

prepare_runtime_owned_paths() {
  _bootstrap_user=$1
  _uv_cache_dir=${UV_CACHE_DIR:-/uv_cache}
  _venv_dir=/app/venv

  if [ "A${_bootstrap_user}" == "Aroot" ]; then
    mkdir -p /app || error_exit "Failed to create /app directory"
    chown ${WANTED_UID}:${WANTED_GID} /app || error_exit "Failed to set owner of /app to hermeswebui user"
    mkdir -p "${_venv_dir}" || error_exit "Failed to create ${_venv_dir} directory"
    chown ${WANTED_UID}:${WANTED_GID} "${_venv_dir}" || error_exit "Failed to set owner of ${_venv_dir} to hermeswebui user"
    mkdir -p "${_uv_cache_dir}" || error_exit "Failed to create ${_uv_cache_dir} directory"
    chown ${WANTED_UID}:${WANTED_GID} "${_uv_cache_dir}" || error_exit "Failed to set owner of ${_uv_cache_dir} to hermeswebui user"
    if [ -n "${HERMES_WEBUI_DEFAULT_WORKSPACE:-}" ] && [ ! -d "$HERMES_WEBUI_DEFAULT_WORKSPACE" ]; then
      mkdir -p "$HERMES_WEBUI_DEFAULT_WORKSPACE" || error_exit "Failed to create default workspace at $HERMES_WEBUI_DEFAULT_WORKSPACE"
      chown ${WANTED_UID}:${WANTED_GID} "$HERMES_WEBUI_DEFAULT_WORKSPACE" || echo "!! WARNING: Could not chown $HERMES_WEBUI_DEFAULT_WORKSPACE (continuing)"
    fi
    return 0
  fi

  ensure_sudo_ready_for_hermeswebui
  sudo mkdir -p /app || error_exit "Failed to create /app directory"
  sudo chown ${WANTED_UID}:${WANTED_GID} /app || error_exit "Failed to set owner of /app to hermeswebui user"
  sudo mkdir -p "${_venv_dir}" || error_exit "Failed to create ${_venv_dir} directory"
  sudo chown ${WANTED_UID}:${WANTED_GID} "${_venv_dir}" || error_exit "Failed to set owner of ${_venv_dir} to hermeswebui user"
  sudo mkdir -p "${_uv_cache_dir}" || error_exit "Failed to create ${_uv_cache_dir} directory"
  sudo chown ${WANTED_UID}:${WANTED_GID} "${_uv_cache_dir}" || error_exit "Failed to set owner of ${_uv_cache_dir} to hermeswebui user"
  if [ -n "${HERMES_WEBUI_DEFAULT_WORKSPACE:-}" ] && [ ! -d "$HERMES_WEBUI_DEFAULT_WORKSPACE" ]; then
    sudo mkdir -p "$HERMES_WEBUI_DEFAULT_WORKSPACE" || error_exit "Failed to create default workspace at $HERMES_WEBUI_DEFAULT_WORKSPACE"
    sudo chown ${WANTED_UID}:${WANTED_GID} "$HERMES_WEBUI_DEFAULT_WORKSPACE" || echo "!! WARNING: Could not chown $HERMES_WEBUI_DEFAULT_WORKSPACE (continuing)"
  fi
}

ensure_runtime_target_ownership() {
  _target=$1
  _target_uid=$(stat -c '%u' "$_target" 2>/dev/null || echo "")
  _target_gid=$(stat -c '%g' "$_target" 2>/dev/null || echo "")

  if [ "A${_target_uid}" == "A${WANTED_UID}" ] && [ "A${_target_gid}" == "A${WANTED_GID}" ]; then
    return 0
  fi

  if [ "$(id -u)" = "0" ]; then
    chown ${WANTED_UID}:${WANTED_GID} "$_target"
    return $?
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo chown ${WANTED_UID}:${WANTED_GID} "$_target"
    return $?
  fi

  return 1
}

restart_as_hermeswebui() {
  _bootstrap_user=$1
  _readonly_root=false

  # Guard for read-only root filesystem (podman with read_only=true, issue #1470).
  # Older images bootstrap through hermeswebuitoo and need sudo; newer GHCR
  # images start as root directly, so use plain sh/groupmod/usermod there.
  if [ "A${_bootstrap_user}" == "Aroot" ]; then
    if ! sh -c 'test -w /etc/group && test -w /etc/passwd' 2>/dev/null; then
      _readonly_root=true
      echo "  !! Detected read-only root filesystem — /etc/group or /etc/passwd is not writable"
    fi
  else
    if ! sudo sh -c 'test -w /etc/group && test -w /etc/passwd' 2>/dev/null; then
      _readonly_root=true
      echo "  !! Detected read-only root filesystem — /etc/group or /etc/passwd is not writable (even via sudo)"
    fi
  fi

  if [ "A${_readonly_root}" == "Atrue" ]; then
    _current_hermeswebui_gid=$(id -g hermeswebui 2>/dev/null || echo "")
    _current_hermeswebui_uid=$(id -u hermeswebui 2>/dev/null || echo "")
    if [ "A${_current_hermeswebui_gid}" == "A${WANTED_GID}" ] && [ "A${_current_hermeswebui_uid}" == "A${WANTED_UID}" ]; then
      echo "  -- Skipping groupmod/usermod — hermeswebui already has UID ${WANTED_UID} GID ${WANTED_GID} and root fs is read-only"
    else
      error_exit "Cannot modify /etc/group or /etc/passwd (read-only root fs). Set UID=${_current_hermeswebui_uid} and GID=${_current_hermeswebui_gid} to match, or run without read_only=true. See issue #1470."
    fi
  elif [ "A${_bootstrap_user}" == "Aroot" ]; then
    groupmod -o -g ${WANTED_GID} hermeswebui || error_exit "Failed to set GID of hermeswebui user"
    usermod -o -u ${WANTED_UID} hermeswebui || error_exit "Failed to set UID of hermeswebui user"
  else
    ensure_sudo_ready_for_hermeswebui
    groupmod_cmd=sudo
    ${groupmod_cmd} groupmod -o -g ${WANTED_GID} hermeswebui || error_exit "Failed to set GID of hermeswebui user"
    ${groupmod_cmd} usermod -o -u ${WANTED_UID} hermeswebui || error_exit "Failed to set UID of hermeswebui user"
  fi

  if [ "A${_bootstrap_user}" == "Aroot" ]; then
    chown -R ${WANTED_UID}:${WANTED_GID} /home/hermeswebui || error_exit "Failed to set owner of /home/hermeswebui"
  else
    sudo chown -R ${WANTED_UID}:${WANTED_GID} /home/hermeswebui || error_exit "Failed to set owner of /home/hermeswebui"
  fi

  prepare_runtime_owned_paths "${_bootstrap_user}"

  save_env /tmp/hermeswebuitoo_env.txt
  echo "-- Restarting as hermeswebui user with UID ${WANTED_UID} GID ${WANTED_GID}"
  exec su -s /bin/bash hermeswebui -c "$script_fullname"
}

ensure_root_managed_extra_shell_python_packages() {
  if [ -n "${HERMES_WEBUI_EXTRA_SHELL_PYTHON_PACKAGES:-}" ]; then
    echo "-- Deferring extra shell Python package bootstrap until after switching to hermeswebui"
  fi

  return 0
}

load_env() {
  tocheck=$1
  overwrite_if_different=$2
  ignore_list="${ENV_IGNORELIST}"
  obfuscate_part="${ENV_OBFUSCATE_PART}"
  if [ -f "$tocheck" ]; then
    echo "-- Loading environment variables from $tocheck (overwrite existing: $overwrite_if_different) (ignorelist: $ignore_list) (obfuscate: $obfuscate_part)"
    while IFS='=' read -r key value; do
      doit=false
      # checking if the key is in the ignorelist
      for i in $ignore_list; do
        if [[ "A$key" ==  "A$i" ]]; then doit=ignore; break; fi
      done
      if [[ "A$doit" == "Aignore" ]]; then continue; fi
      rvalue=$value
      # checking if part of the key is in the obfuscate list
      doobs=false
      for i in $obfuscate_part; do
        if [[ "A$key" == *"$i"* ]]; then doobs=obfuscate; break; fi
      done
      if [[ "A$doobs" == "Aobfuscate" ]]; then rvalue="**OBFUSCATED**"; fi

      if [ -z "${!key}" ]; then
        echo "  ++ Setting environment variable $key [$rvalue]"
        doit=true
      elif [ "A$overwrite_if_different" == "Atrue" ]; then
        cvalue="${!key}"
        if [[ "A${doobs}" == "Aobfuscate" ]]; then cvalue="**OBFUSCATED**"; fi
        if [[ "A${!key}" != "A${value}" ]]; then
          echo "  @@ Overwriting environment variable $key [$cvalue] -> [$rvalue]"
          doit=true
        else
          echo "  == Environment variable $key [$rvalue] already set and value is unchanged"
        fi
      fi
      if [[ "A$doit" == "Atrue" ]]; then
        export "$key=$value"
      fi
    done < "$tocheck"
  fi
}

# Current GHCR images start as root; older images started as hermeswebuitoo.
# Support both bootstrap users before handing off to hermeswebui.
if [ "A${whoami}" == "Aroot" ]; then
  echo "-- Running as root, will switch hermeswebui to the desired UID/GID"
  ensure_root_managed_extra_shell_python_packages
  restart_as_hermeswebui root
fi

# hermeswebuitoo is a specific bootstrap user used by older images.
if [ "A${whoami}" == "Ahermeswebuitoo" ]; then
  echo "-- Running as hermeswebuitoo, will switch hermeswebui to the desired UID/GID"
  restart_as_hermeswebui hermeswebuitoo
fi

# If we are here, the script is already running as the final runtime user.
# Because the whoami value for the remapped hermeswebui user can vary, check
# the UID/GID instead of the literal username.
if [ "$WANTED_GID" != "$new_gid" ]; then error_exit "hermeswebui MUST be running as UID ${WANTED_UID} GID ${WANTED_GID}, current UID ${new_uid} GID ${new_gid}"; fi
if [ "$WANTED_UID" != "$new_uid" ]; then error_exit "hermeswebui MUST be running as UID ${WANTED_UID} GID ${WANTED_GID}, current UID ${new_uid} GID ${new_gid}"; fi

########## 'hermeswebui' specific section below

# We are therefore running as hermeswebui
echo ""; echo "== Running as hermeswebui"

# Load environment variables one by one if they do not exist from /tmp/hermeswebuitoo_env.txt
it=/tmp/hermeswebuitoo_env.txt
if [ -f $it ]; then
  echo "-- Loading not already set environment variables from $it"
  load_env $it true
fi

##
echo ""; echo "-- Making sure /app is owned by the hermeswebui user to avoid permission issues when running the server "
mkdir -p /app || error_exit "Failed to create /app directory"
ensure_runtime_target_ownership /app || error_exit "Failed to set owner of /app to hermeswebui user"
rsync -av /apptoo/ /app/ || error_exit "Failed to sync /apptoo to /app with correct ownership"
it=/app/.testfile; touch $it || error_exit "Failed to verify /app directory"
rm -f $it || error_exit "Failed to delete test file in /app"

######## Environment variables (consume AFTER the load_env)

echo ""; echo "== Checking required environment variables for hermes-webui"

echo ""; echo "-- HERMES_WEBUI_VERSION: Where to store sessions, workspaces, and other state (default: ~/.hermes/webui-mvp)"
if [ -z "${HERMES_WEBUI_STATE_DIR+x}" ]; then error_exit "HERMES_WEBUI_STATE_DIR not set"; fi; 
echo "-- HERMES_WEBUI_STATE_DIR: $HERMES_WEBUI_STATE_DIR"
if [ ! -d "$HERMES_WEBUI_STATE_DIR" ]; then mkdir -p $HERMES_WEBUI_STATE_DIR || error_exit "Failed to create state directory at $HERMES_WEBUI_STATE_DIR"; fi
if [ ! -d "$HERMES_WEBUI_STATE_DIR" ]; then error_exit "HERMES_WEBUI_STATE_DIR directory does not exist at $HERMES_WEBUI_STATE_DIR"; fi
it="$HERMES_WEBUI_STATE_DIR/.testfile"; touch $it || error_exit "Failed to verify state directory at $HERMES_WEBUI_STATE_DIR"
rm -f $it || error_exit "Failed to delete test file in $HERMES_WEBUI_STATE_DIR"

echo ""; echo "-- HERMES_WEBUI_DEFAULT_WORKSPACE: Default workspace directory shown on first launch"
if [ -z "${HERMES_WEBUI_DEFAULT_WORKSPACE+x}" ]; then echo "HERMES_WEBUI_DEFAULT_WORKSPACE not set, setting to /workspace"; export HERMES_WEBUI_DEFAULT_WORKSPACE="/workspace"; fi;
echo "-- HERMES_WEBUI_DEFAULT_WORKSPACE: $HERMES_WEBUI_DEFAULT_WORKSPACE"
# Use sudo for mkdir — Docker may auto-create bind-mount directories as root (#357).
# Skip mkdir if the directory already exists (e.g. a read-only mount — #670).
if [ ! -d "$HERMES_WEBUI_DEFAULT_WORKSPACE" ]; then
  mkdir -p "$HERMES_WEBUI_DEFAULT_WORKSPACE" || error_exit "Failed to create default workspace at $HERMES_WEBUI_DEFAULT_WORKSPACE"
fi
if [ ! -d "$HERMES_WEBUI_DEFAULT_WORKSPACE" ]; then error_exit "HERMES_WEBUI_DEFAULT_WORKSPACE directory does not exist at $HERMES_WEBUI_DEFAULT_WORKSPACE"; fi
# Only chown and write-test if the workspace is writable. Read-only bind-mounts
# (:ro) are valid — the workspace is used for browsing, not writing by the server.
if [ -w "$HERMES_WEBUI_DEFAULT_WORKSPACE" ]; then
  ensure_runtime_target_ownership "$HERMES_WEBUI_DEFAULT_WORKSPACE" || echo "!! WARNING: Could not chown $HERMES_WEBUI_DEFAULT_WORKSPACE (continuing)"
  it="$HERMES_WEBUI_DEFAULT_WORKSPACE/.testfile"; touch $it && rm -f $it || echo "!! WARNING: Could not write to $HERMES_WEBUI_DEFAULT_WORKSPACE (continuing)"
else
  echo "-- HERMES_WEBUI_DEFAULT_WORKSPACE is read-only — skipping chown/write check (read-only workspace is supported)"
fi

echo ""; echo "==================="
echo ""; echo "== Installing uv and creating a new virtual environment for hermes-webui"

export PATH="/home/hermeswebui/.local/bin/:$PATH"
if command -v uv &>/dev/null; then
  echo "-- uv already installed ($(uv --version)), skipping download"
else
  echo "-- uv not found, downloading..."
  curl -LsSf https://astral.sh/uv/install.sh | sh || error_exit "Failed to install uv — check network connectivity"
fi
export UV_PROJECT_ENVIRONMENT=venv

export UV_CACHE_DIR=${UV_CACHE_DIR:-/uv_cache}
mkdir -p ${UV_CACHE_DIR} || error_exit "Failed to create ${UV_CACHE_DIR} directory"
ensure_runtime_target_ownership ${UV_CACHE_DIR} || error_exit "Failed to set owner of ${UV_CACHE_DIR} to hermeswebui user"

cd /app
SYSTEM_PYTHON=$(command -v python3)
if [ -z "$SYSTEM_PYTHON" ]; then error_exit "Failed to locate system python3"; fi
if [ -f /app/venv/bin/python3 ]; then
  echo ""; echo "== Existing virtual environment found — reusing (fast restart)"
else
  echo ""; echo "== Creating new virtual environment"
  uv venv venv
fi
export VIRTUAL_ENV=/app/venv
test -d /app/venv
test -f /app/venv/bin/activate

echo "";echo "== Activating hermes webui's virtual environment"
source /app/venv/bin/activate || error_exit "Failed to activate hermeswebui virtual environment"
test -x /app/venv/bin/python3

shell_python_target_dir() {
  echo "/app/venv/shell-python"
}

shell_python_target_has_packages() {
  _shell_python_target=$1
  find "$_shell_python_target" -mindepth 1 -maxdepth 1 ! -name '.lock' -print -quit 2>/dev/null | grep -q .
}

export_shell_python_target_path() {
  _shell_python_target=$1
  if ! shell_python_target_has_packages "$_shell_python_target"; then
    return 0
  fi

  case ":${PYTHONPATH:-}:" in
    *:$_shell_python_target:*)
      ;;
    *)
      export PYTHONPATH="$_shell_python_target${PYTHONPATH:+:$PYTHONPATH}"
      echo "-- Added $_shell_python_target to PYTHONPATH for command-agent shells"
      ;;
  esac
}

ensure_hindsight_client_docker_dependency() {
  if is_reduced_functionality_attach_mode; then
    echo ""; echo "== Skipping optional Hindsight memory provider dependency in reduced-functionality mode"
    return 0
  fi

  # Keep this outside the .deps_installed fast-restart guard so existing
  # two-container Docker venvs self-heal after this dependency was added.
  _hindsight_client_requirement="hindsight-client>=0.4.22"
  echo ""; echo "== Checking Hindsight memory provider dependency"
  if /app/venv/bin/python -c "import hindsight_client" >/dev/null 2>&1; then
    echo "-- hindsight-client already installed"
  else
    echo "-- Installing ${_hindsight_client_requirement} for Hindsight memory provider support"
    uv pip install "${_hindsight_client_requirement}" --trusted-host pypi.org --trusted-host files.pythonhosted.org || error_exit "Failed to install hindsight-client"
  fi
}

ensure_extra_shell_python_packages() {
  # Keep this outside the .deps_installed fast-restart guard so an attach
  # container can persist extra command-agent shell libraries across recreate.
  if [ -z "${HERMES_WEBUI_EXTRA_SHELL_PYTHON_PACKAGES:-}" ]; then
    return 0
  fi

  if is_reduced_functionality_attach_mode; then
    echo ""; echo "== Skipping optional shell Python package bootstrap in reduced-functionality mode"
    return 0
  fi

  read -r -a _extra_shell_package_args <<< "${HERMES_WEBUI_EXTRA_SHELL_PYTHON_PACKAGES}"
  if [ "${#_extra_shell_package_args[@]}" -eq 0 ]; then
    return 0
  fi

  _verify_reportlab_import=false
  for _extra_shell_package in "${_extra_shell_package_args[@]}"; do
    case "${_extra_shell_package}" in
      reportlab)
        _verify_reportlab_import=true
        ;;
    esac
  done

  _extra_shell_packages_normalized="${_extra_shell_package_args[*]}"
  _extra_shell_packages_marker="/app/venv/.extra_shell_python_packages_installed"
  _shell_python_target=$(shell_python_target_dir)
  mkdir -p "$_shell_python_target" || error_exit "Failed to create extra shell Python target directory at $_shell_python_target"

  echo ""; echo "== Checking extra shell Python packages"
  if [ -f "$_extra_shell_packages_marker" ] && [ "$(cat "$_extra_shell_packages_marker" 2>/dev/null)" = "$_extra_shell_packages_normalized" ]; then
    if ! shell_python_target_has_packages "$_shell_python_target"; then
      echo "-- Extra shell package marker matched, but target directory is empty; reinstalling"
    elif [ "A${_verify_reportlab_import}" == "Atrue" ] && ! PYTHONPATH="$_shell_python_target${PYTHONPATH:+:$PYTHONPATH}" "$SYSTEM_PYTHON" -c "import reportlab" >/dev/null 2>&1; then
      echo "-- Extra shell package marker matched, but reportlab is not importable yet; reinstalling"
    else
      export_shell_python_target_path "$_shell_python_target"
      echo "-- Extra shell Python packages already installed — skipping"
      return 0
    fi
  fi

  echo "-- Installing extra shell Python packages for command-agent shells: ${_extra_shell_package_args[*]}"
  rm -rf "$_shell_python_target" || error_exit "Failed to reset extra shell Python target directory at $_shell_python_target"
  mkdir -p "$_shell_python_target" || error_exit "Failed to recreate extra shell Python target directory at $_shell_python_target"
  uv pip install --target "$_shell_python_target" "${_extra_shell_package_args[@]}" --trusted-host pypi.org --trusted-host files.pythonhosted.org || error_exit "Failed to install extra shell Python packages"
  export_shell_python_target_path "$_shell_python_target"

  if [ "A${_verify_reportlab_import}" == "Atrue" ] && ! PYTHONPATH="$_shell_python_target${PYTHONPATH:+:$PYTHONPATH}" "$SYSTEM_PYTHON" -c "import reportlab" >/dev/null 2>&1; then
    error_exit "reportlab requested but is not importable from $_shell_python_target"
  fi

  printf '%s' "$_extra_shell_packages_normalized" > "$_extra_shell_packages_marker"
}

ensure_hermes_agent_docker_dependency() {
  # Keep this outside the .deps_installed fast-restart guard so an attach
  # container can self-heal when a persisted venv was created in reduced mode.
  if is_reduced_functionality_attach_mode; then
    echo ""
    echo "!! WARNING: Skipping hermes-agent dependency install by configuration."
    echo "!! The WebUI will start with reduced functionality (no model auto-detection,"
    echo "!! no personality routing, no CLI session imports)."
    echo ""
    return 0
  fi

  if /app/venv/bin/python -c "import run_agent" >/dev/null 2>&1; then
    echo ""; echo "== Hermes agent already importable — skipping dependency bootstrap"
    return 0
  fi

  echo ""; echo "== Installing hermes-agent base dependencies into the virtual environment"
  _agent_paths=(
    "/home/hermeswebui/.hermes/hermes-agent"
    "/opt/hermes"
  )
  _agent_src=""
  for _p in "${_agent_paths[@]}"; do
    if [ -d "$_p" ] && [ -f "$_p/pyproject.toml" ]; then
      _agent_src="$_p"
      break
    fi
  done
  if [ -n "$_agent_src" ] && PYTHONPATH="$_agent_src${PYTHONPATH:+:$PYTHONPATH}" /app/venv/bin/python -c "import run_agent" >/dev/null 2>&1; then
    export PYTHONPATH="$_agent_src${PYTHONPATH:+:$PYTHONPATH}"
    echo ""; echo "== Hermes agent already importable from $_agent_src — skipping dependency bootstrap"
    return 0
  fi
  if [ -n "$_agent_src" ]; then
    _agent_requirements_tmp="/tmp/hermes-agent-base-requirements.txt"
    "$SYSTEM_PYTHON" - "$_agent_src/pyproject.toml" "$_agent_requirements_tmp" <<'PY' || error_exit "Failed to extract hermes-agent dependencies from pyproject.toml"
import pathlib
import sys
import tomllib

pyproject_path = pathlib.Path(sys.argv[1])
requirements_path = pathlib.Path(sys.argv[2])
data = tomllib.loads(pyproject_path.read_text(encoding='utf-8'))
deps = data.get('project', {}).get('dependencies', [])
if not deps:
    raise SystemExit('No project.dependencies found in pyproject.toml')
requirements_path.write_text('\n'.join(deps) + '\n', encoding='utf-8')
PY
    uv pip install -r "$_agent_requirements_tmp" --trusted-host pypi.org --trusted-host files.pythonhosted.org || error_exit "Failed to install hermes-agent base dependencies"
    export PYTHONPATH="$_agent_src${PYTHONPATH:+:$PYTHONPATH}"
    echo "-- Added $_agent_src to PYTHONPATH"
  else
    echo ""
    echo "!! WARNING: hermes-agent source not found."
    echo "!!   Looked in: ${_agent_paths[0]}"
    echo "!!              ${_agent_paths[1]}"
    echo "!! The WebUI will start with reduced functionality (no model auto-detection,"
    echo "!! no personality routing, no CLI session imports)."
    echo "!! To fix: mount the agent source volume into the container:"
    echo "!!   -v /path/to/hermes-agent:/home/hermeswebui/.hermes/hermes-agent"
    echo "!! Or see the two-container compose example:"
    echo "!!   https://github.com/nesquena/hermes-webui/blob/master/docker-compose.two-container.yml"
    echo ""
  fi
}

is_reduced_functionality_attach_mode() {
  case "${HERMES_WEBUI_SKIP_AGENT_INSTALL:-}" in
    1|true|TRUE|True|yes|YES|Yes)
      return 0
      ;;
  esac

  return 1
}

if [ -f /app/venv/.deps_installed ]; then
  echo ""; echo "== Dependencies already installed — skipping (fast restart)"
else
  echo ""; echo "== Installing hermes-webui dependencies"
  uv pip install -r requirements.txt --trusted-host pypi.org --trusted-host files.pythonhosted.org
  touch /app/venv/.deps_installed
fi

ensure_hermes_agent_docker_dependency
ensure_hindsight_client_docker_dependency
ensure_extra_shell_python_packages
ensure_attach_ollama_runtime_config

echo ""; echo "== Running hermes-webui"
cd /app; python server.py || error_exit "hermes-webui failed or exited with an error"

# we should never be here because the server should be running indefinitely, but if we are, we exit safely
ok_exit "Clean exit"
