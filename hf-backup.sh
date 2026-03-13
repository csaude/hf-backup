#!/usr/bin/env bash
set -euo pipefail

log(){ echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
die(){ echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; exit 1; }

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo $0"; }

_read_ini_value(){
    local file="$1" key="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d'=' -f2- \
        | tr -d '"' | tr -d "'"
}

_write_status(){
    local key="$1" value="$2"
    local statusfile=".env"
    # update or add the key
    if grep -q "^${key}=" "$statusfile" 2>/dev/null; then
        sed -i "s/^${key}=.*/${key}=${value}/" "$statusfile"
    else
        echo "${key}=${value}" >> "$statusfile"
    fi
}

_read_status(){
    local key="$1"
    local statusfile=".env"
    if [[ -f "$statusfile" ]]; then
        grep -E "^${key}=" "$statusfile" 2>/dev/null | head -n1 | cut -d'=' -f2- || echo ""
    fi
}

load_ini() {
  local f="$1"
  [[ -f "$f" ]] || die "Installer config not found: $f"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue
    [[ "$line" =~ ^\; ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    local key="${line%%=*}"
    local val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" =~ ^\".*\"$ ]]; then val="${val:1:${#val}-2}"; fi  
    if [[ "$val" =~ ^\'.*\'$ ]]; then val="${val:1:${#val}-2}"; fi
    export "$key=$val"
  done < "$f"
}

require_docker() {
  have_cmd docker || die "docker not found. Install Docker first."
  if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD=$(which docker)" compose"
  elif have_cmd docker-compose; then
    DOCKER_COMPOSE_CMD=$(which docker-compose)
  else
    die "Docker Compose not found. Install docker-compose-plugin or docker-compose."
  fi
}

# Ensure the given docker image is available locally.
# If missing, interactively offer to `docker pull` or `docker load` from a tarball.
# Returns 0 when the image is available, 1 on user abort.
ensure_image_available() {
  local image="$1"

  have_cmd docker || die "docker not found; cannot verify image ${image}"

  # If image exists locally, quietly return success
  if docker image inspect "${image}" >/dev/null 2>&1; then
    return 0
  fi

  # Interactive loop until user succeeds or aborts
  while true; do
    echo "Image '${image}' not found locally."
    read -rp "Pull from registry (p) or load from file (l)? [p/l] " choice
    choice="${choice,,}"
    if [[ "${choice}" == "p" || "${choice}" == "pull" ]]; then
      log "Pulling image ${image} ..."
      if docker pull "${image}"; then
        log "Image ${image} pulled successfully."
        return 0
      else
        warn "docker pull failed for ${image}."
      fi
    elif [[ "${choice}" == "l" || "${choice}" == "load" ]]; then
      while true; do
        read -rp "Path to image tarball (enter '.' to abort): " fpath
        if [[ "${fpath}" == "." ]]; then
          warn "User aborted image load for ${image}."
          return 1
        fi
        if [[ -f "${fpath}" ]]; then
          log "Loading image from ${fpath} ..."
          if docker load -i "${fpath}"; then
            log "Image loaded from ${fpath}."
            return 0
          else
            warn "docker load failed for ${fpath}."
          fi
        else
          warn "File not found: ${fpath}"
        fi
      done
    else
      echo "Please enter 'p' (pull) or 'l' (load)."
    fi
  done
}

write_dirs() {
  : "${BASE_DIR:=/opt/hf-backup}"
  mkdir -p \
    "${BASE_DIR}/ssh/tls" \
    "${BASE_DIR}/state" \
    "${BASE_DIR}/backups" \
    "${BASE_DIR}/config/borgmatic.d" \
    "${BASE_DIR}/runtime" \
    "${BASE_DIR}/logs"

  chmod 700 "${BASE_DIR}/ssh"
  chmod 750 "${BASE_DIR}/backups"
}

gen_ssh_keys() {
  local key="${BASE_DIR}/ssh/id_rsa"
  local pub="${BASE_DIR}/ssh/id_rsa.pub"
  local knh="${BASE_DIR}/ssh/known_hosts"
  local kekkey="${BASE_DIR}/ssh/id_kek"
  local kekpub="${BASE_DIR}/ssh/id_kek.pub"

  if [[ -f "$key" && -f "$pub" ]]; then
    log "SSH key exists: ${key}"
  else
    log "Generating SSH key (no passphrase) ..."
    ssh-keygen -t rsa -N "" -f "$key" -C "hf-backup@$(hostname -f 2>/dev/null || hostname)" >/dev/null
    ssh-keyscan -H "${CENTRAL_HOST}" > "$knh" 2>/dev/null || true
    chmod 600 "$key"
    chmod 600 "$knh"
    chmod 644 "$pub"
    key_generated=true
  fi
  
  if [[ -f "$kekkey" && -f "$kekpub" ]]; then
    log "SSH key exists: ${kekkey}"
  else
    log "Generating SSH Key Exchange Key (no passphrase) ..."
    ssh-keygen -t rsa -N "" -f "$kekkey" -C "hf-backup-kek@$(hostname -f 2>/dev/null || hostname)" >/dev/null
    ssh-keyscan -H "${CENTRAL_HOST}" > "$knh" 2>/dev/null || true
    chmod 600 "$kekkey"
    chmod 644 "$kekpub"
    kek_generated=true
  fi
  
  if [[ "${key_generated:-false}" == true || "${kek_generated:-false}" == true ]]; then
    tar -czf "./hf-${facility_code}-keys.tar.gz" -C "${BASE_DIR}/ssh" id_rsa.pub id_kek.pub
    log "SSH public keys generated and archived to ./hf-${facility_code}-keys.tar.gz. Please share this file with central backup team to set up the server side access for this facility."
  fi
  echo
}

validate_password() {
    local password="$1"
    if [[ "$password" != "$2" ]]; then
      echo "Passphrases do not match. Please try again."
      return 1
    fi
    
    # Check minimum length
    if [[ ${#password} -lt 8 ]]; then
        echo "Error: Password must be at least 8 characters long"
        return 1
    fi
    
    # Count character type categories present
    local category_count=0
    
    # Check for lowercase letters
    if [[ "$password" =~ [a-z] ]]; then
        ((category_count++))
    fi
    
    # Check for uppercase letters
    if [[ "$password" =~ [A-Z] ]]; then
        ((category_count++))
    fi
    
    # Check for numbers
    if [[ "$password" =~ [0-9] ]]; then
        ((category_count++))
    fi
    
    # Check for special characters (anything that's not alphanumeric)
    if [[ "$password" =~ [^a-zA-Z0-9] ]]; then
        ((category_count++))
    fi
    
    # Validate that at least 3 categories are present
    if [[ $category_count -lt 3 ]]; then
        echo "Error: Password must contain at least 3 of 4 character types (lowercase, uppercase, numbers, special characters)"
        return 1
    fi
    
    echo "Password is valid"
    return 0
}

show_welcome_message() {
  echo "============================================================"
  echo "Setup for Health Facility: ${facility_code^^}"
  echo "============================================================"
  echo
  echo "This installer will set up the Health Facility Backup system on this machine."
  echo
  read -rp "Backup artifacts will be installed on [$(pwd)] ENTER to continue or CTRL+C to abort."
  echo

}

prompt_borg_passphrase() {
  ENV_FILE=".env"
  borg_passphrase1=""
  if [[ -f "${ENV_FILE}" ]]; then
    log "Found existing config ${ENV_FILE}; loading BORG_PASSPHRASE from it."
    load_ini "${ENV_FILE}"
    borg_passphrase1="${BORG_PASSPHRASE:-}"
    if [[ -n "$borg_passphrase1" && "$borg_passphrase1" != "CHANGE_ME_TO_A_STRONG_PASSPHRASE" ]]; then
      log "Existing BORG_PASSPHRASE loaded from ${ENV_FILE} (will be reused)."
      return 0
    else
      warn "BORG_PASSPHRASE in .env is not set or is placeholder; will prompt for new passphrase."
      echo
      borg_passphrase1=""
    fi
  else
    log "No existing config found at ${ENV_FILE}; will prompt for new BORG_PASSPHRASE and create config file."
  fi
  while [[ -z "$borg_passphrase1" ]]; do
    read -srp "Define BORG_PASSPHRASE (will be stored in ${ENV_FILE}, HF safe): " borg_passphrase1
    echo
    read -srp "Confirm BORG_PASSPHRASE: " borg_passphrase2
    echo
    if ! validate_password "$borg_passphrase1" "$borg_passphrase2"; then
      borg_passphrase1=""
      borg_passphrase2=""
    fi
  done
  _write_status "BORG_PASSPHRASE" "$borg_passphrase1"
}

write_backup_script() {
  local f="${BASE_DIR}/runtime/backup.sh"
  cat > "$f" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[backup] $*"; }
warn(){ echo "[backup][WARN] $*"; }
die(){ echo "[backup][ERROR] $*" >&2; exit 1; }

load_ini() {
  local f="$1"
  [[ -f "$f" ]] || die "Config file not found: $f"
  if [[ $(grep -ci "CHANGE_ME_TO_A_STRONG_PASSPHRASE" "$f") -gt 0 ]]; then
    die "Please edit ${f} and replace BORG passphrase value (e.g. BORG_PASSPHRASE=Passw0rd) before running backup."
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    # trim
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue
    [[ "$line" =~ ^\; ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue

    local key="${line%%=*}"
    local val="${line#*=}"

    # trim val
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"

    # unquote
    if [[ "$val" =~ ^\".*\"$ ]]; then val="${val:1:${#val}-2}"; fi
    if [[ "$val" =~ ^\'.*\'$ ]]; then val="${val:1:${#val}-2}"; fi

    export "$key=$val"
  done < "$f"
}

tolower() { echo "${1,,}"; }

# --- Load runtime config ---
load_ini "$ENV_FILE"

# --- Defaults ---
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups}"
DB_DIR="${BACKUP_ROOT}/db"
TS="$(date +%F_%H-%M-%S)"
mkdir -p "${DB_DIR}/mysql" "${DB_DIR}/postgres"

log "Using config: ${ENV_FILE}"
log "Timestamp: ${TS}"

# --- Retention cleanup for local dumps ---
if [[ -n "${LOCAL_DUMP_RETENTION_DAYS:-}" ]]; then
  if [[ "${LOCAL_DUMP_RETENTION_DAYS}" =~ ^[0-9]+$ ]]; then
    if [[ "${LOCAL_DUMP_RETENTION_DAYS}" -eq 0 ]]; then
      log "Retention: deleting ALL previous dump files in ${DB_DIR}"
      find "${DB_DIR}" -type f -print -delete || true
    else
      log "Retention: deleting dump files older than ${LOCAL_DUMP_RETENTION_DAYS} days in ${DB_DIR}"
      find "${DB_DIR}" -type f -mtime +"${LOCAL_DUMP_RETENTION_DAYS}" -print -delete || true
    fi
  else
    warn "LOCAL_DUMP_RETENTION_DAYS not numeric (${LOCAL_DUMP_RETENTION_DAYS}); skipping cleanup."
  fi
else
  log "Retention: not set (keeping all local dumps)."
fi

# ---------- MySQL dump ----------
if [[ -n "${MYSQL_HOST:-}" && -n "${MYSQL_USER:-}" && -n "${MYSQL_PASSWORD:-}" ]]; then
  MYSQL_PORT="${MYSQL_PORT:-3306}"

  if [[ -n "${MYSQL_DATABASE:-}" ]]; then
    OUT="${DB_DIR}/mysql/mysql_${MYSQL_DATABASE}_${TS}.sql.gz"
    log "MySQL: dumping '${MYSQL_DATABASE}' from ${MYSQL_HOST}:${MYSQL_PORT} -> ${OUT}"
    mysqldump \
      --host="${MYSQL_HOST}" --port="${MYSQL_PORT}" \
      --user="${MYSQL_USER}" --password="${MYSQL_PASSWORD}" \
      --single-transaction --routines --triggers --events \
      --databases "${MYSQL_DATABASE}" \
    | gzip -1 > "${OUT}"
  else
    OUT="${DB_DIR}/mysql/mysql_all_${TS}.sql.gz"
    log "MySQL: dumping ALL databases from ${MYSQL_HOST}:${MYSQL_PORT} -> ${OUT}"
    mysqldump \
      --host="${MYSQL_HOST}" --port="${MYSQL_PORT}" \
      --user="${MYSQL_USER}" --password="${MYSQL_PASSWORD}" \
      --single-transaction --routines --triggers --events \
      --all-databases \
    | gzip -1 > "${OUT}"
  fi
else
  log "MySQL: skipped (MYSQL_HOST/MYSQL_USER/MYSQL_PASSWORD not fully set)."
fi

# ---------- PostgreSQL dump ----------
if [[ -n "${PGHOST:-}" && -n "${PGUSER:-}" && -n "${PGPASSWORD:-}" && -n "${PGDATABASE:-}" ]]; then
  PGPORT="${PGPORT:-5432}"
  export PGPASSWORD

  OUT="${DB_DIR}/postgres/pg_${PGDATABASE}_${TS}.dump"
  log "Postgres: dumping '${PGDATABASE}' from ${PGHOST}:${PGPORT} -> ${OUT}"
  pg_dump \
    -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" \
    -F c -Z 1 \
    -f "${OUT}" \
    "${PGDATABASE}"
else
  log "Postgres: skipped (PGHOST/PGUSER/PGPASSWORD/PGDATABASE not fully set)."
fi

# ---------- Borg upload behavior (Borg 1.2.x safe mode) ----------
BORG_SERVER_ENABLED="$(tolower "${BORG_SERVER_ENABLED:-true}")"
BORG_FAIL_MODE="$(tolower "${BORG_FAIL_MODE:-warn}")"
v="${BORGMATIC_VERBOSITY:-1}"

if [[ "${BORG_SERVER_ENABLED}" != "true" ]]; then
  log "BORG_SERVER_ENABLED=false -> skipping borg upload (local dumps only)."
  log "Done."
  exit 0
fi

# Validate required vars for borgmatic (only if enabled)
if [[ -z "${BORG_REPO:-}" ]]; then
  msg="BORG_REPO is empty but BORG_SERVER_ENABLED=true"
  if [[ "${BORG_FAIL_MODE}" == "fail" ]]; then
    die "${msg}"
  else
    warn "${msg}. Skipping borg upload."
    log "Done."
    exit 0
  fi
fi

# Best-effort: try borgmatic; if it fails due to no internet/ssh, do warn/fail based on BORG_FAIL_MODE
log "borgmatic: running (verbosity ${v}) ..."
set +e
borgmatic --verbosity "${v}"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  msg="borgmatic failed (exit ${rc}). Likely no internet / SSH unreachable / repo not ready."
  if [[ "${BORG_FAIL_MODE}" == "fail" ]]; then
    die "${msg}"
  else
    warn "${msg} (BORG_FAIL_MODE=warn -> treating as success; local dumps are kept)."
    log "Done."
    exit 0
  fi
fi

log "Done."

EOF
  chmod +x "$f"
}

write_env_file() {
  local f=".env"
  if [[ -f "$f" ]]; then
    log ".env exists (not overwriting): ${f}"
    return 0
  fi

  : "${BACKUP_ROOT:=/var/backups}"
  : "${LOCAL_DUMP_RETENTION_DAYS:=7}"
  : "${CENTRAL_HOST:=CENTRAL_HOST}"
  : "${CENTRAL_PORT:=22}"
  : "${REPO_PATH:=/repos/HF001}"

  cat > "$f" <<EOF
# =========================================================
# Runtime config for container (${f})
# HF edits ONLY this file (safe).
# =========================================================

# Where backup.sh writes dumps inside container
BACKUP_ROOT=${BACKUP_ROOT}

ENABLE_MONIT=true

# Local dump retention:
# empty => keep forever
# 0     => delete all previous dumps before new run
# N     => delete dumps older than N days
LOCAL_DUMP_RETENTION_DAYS=7

FACILITY_CODE="${facility_code}"

# ---- BORG Central Server ----
CENTRAL_HOST=${CENTRAL_HOST}
CENTRAL_PORT=${CENTRAL_PORT:-22}

# ---- MySQL / MariaDB (leave empty to skip) ----
MYSQL_HOST=localhost
MYSQL_PORT=3306
MYSQL_USER=
MYSQL_PASSWORD=
MYSQL_DATABASE=

# ---- PostgreSQL (leave empty to skip) ----
PGHOST=localhost
PGPORT=5432
PGUSER=
PGPASSWORD=
PGDATABASE=

# ---- Central borg upload control ----
# true  => try upload to central (best-effort)
# false => only create local dumps (never tries SSH)
BORG_SERVER_ENABLED=true

# warn => if upload fails (no internet), log warning and exit success
# fail => if upload fails, job fails
BORG_FAIL_MODE=warn

# Borg repo settings
BORG_REPO=ssh://${facility_code}@${CENTRAL_HOST}:${CENTRAL_PORT}/./repo
BORG_PASSPHRASE=CHANGE_ME_TO_A_STRONG_PASSPHRASE
# Optional:
BORG_RSH="ssh -o StrictHostKeyChecking=accept-new -i /root/.ssh/id_rsa"

BORGMATIC_VERBOSITY=2

# ---- Central notifications server ----
# Settings to sent backup status to central Pushgateway
PUSHGATEWAY_URL="https://pushdev.csaude.org.mz"
PUSHGW_CLIENT_CERT="/root/.ssh/tls/hf-backup-${facility_code}-client.crt"
PUSHGW_CLIENT_KEY="/root/.ssh/tls/hf-backup-${facility_code}-client.key"
PUSHGW_CA_CERT="/root/.ssh/tls/csaude-ca.crt"
#PUSHGW_JOB="hf_backup"  #Default hf_backup

# -----------------------------------------------------------------------------
# Dynamic parameters do not modify below (unless you know what you are doing)
# -----------------------------------------------------------------------------
_monitoring=unknown
_csr_generated=no
_private_key_generated=no
_csr_submitted=no
_cert_downloaded=no
_borg_initialized=no
_status=not_initialized
# -----------------------------------------------------------------------------

EOF
  chmod 640 "$f"
  warn "Created ${f}. Please edit DB settings if needed."
}

write_borgmatic_config() {
  local cfg="${BASE_DIR}/config/borgmatic.d/config.yaml"
  local runtime_ini=".env"
  : "${BACKUP_ROOT:=/var/backups}"

  # Load runtime_ini (safe key=value) to extract central settings
  local CENTRAL_HOST="" CENTRAL_PORT="" CENTRAL_REPO_PATH=""
  if [[ -f "$runtime_ini" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^# ]] && continue
      [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      key="${line%%=*}"
      val="${line#*=}"
      case "$key" in
        CENTRAL_HOST) CENTRAL_HOST="$val" ;;
        CENTRAL_PORT) CENTRAL_PORT="$val" ;;
        CENTRAL_REPO_PATH) CENTRAL_REPO_PATH="$val" ;;
      esac
    done < "$runtime_ini"
  fi

  # Defaults (if not set yet)
  CENTRAL_HOST="${CENTRAL_HOST:-central-backup.csaude.org.mz}"
  CENTRAL_PORT="${CENTRAL_PORT:-22}"
  CENTRAL_REPO_PATH="${CENTRAL_REPO_PATH:-/repos/HF001}"

  # Build full repo URL (no placeholders!)
  local repo="ssh://${FACILITY_CODE}@${CENTRAL_HOST}:${CENTRAL_PORT}/./repo"

  if [[ ! -f "${cfg}" ]]; then
    log "Creating borgmatic config: ${cfg}"
    cat > "$cfg" <<EOF
# ================================================================================
# ${facility_code^^}"  Health Facility Backup borgmatic - Installer config
# ================================================================================
source_directories:
  - ${BACKUP_ROOT}
  - /host/etc
  - /host/home
  - /host/root
  - /host/var/spool/cron

repositories:
  - path: "${repo}"
    label: central
    encryption: repokey-blake2

compression: zstd,6
archive_name_format: "{hostname}-{now}"

# keep_minutely: 60
keep_hourly: 24
keep_daily: 7
keep_weekly: 4
keep_monthly: 6

checks:
  - name: repository
  - name: archives

commands:
  # ---- BACKUP (create) ----
  - before: action
    when: [create]
    run:
      - /app/pushgw_event.sh backup starting

  - after: action
    when: [create]
    run:
      - /app/pushgw_event.sh backup completed

  - after: error
    when: [create]
    run:
      - /app/pushgw_event.sh backup failed

  # ---- PRUNE ----
  - before: action
    when: [prune]
    run:
      - /app/pushgw_event.sh prune starting

  - after: action
    when: [prune]
    run:
      - /app/pushgw_event.sh prune completed

  - after: error
    when: [prune]
    run:
      - /app/pushgw_event.sh prune failed

  # ---- CHECK ----
  - before: action
    when: [check]
    run:
      - /app/pushgw_event.sh check starting

  - after: action
    when: [check]
    run:
      - /app/pushgw_event.sh check completed

  - after: error
    when: [check]
    run:
      - /app/pushgw_event.sh check failed

  # ---- COMPACT (optional but nice to track) ----
  - before: action
    when: [compact]
    run:
      - /app/pushgw_event.sh compact starting

  - after: action
    when: [compact]
    run:
      - /app/pushgw_event.sh compact completed

  - after: error
    when: [compact]
    run:
      - /app/pushgw_event.sh compact failed

EOF
  else
    log "Borgmatic config already exists (not overwriting): ${cfg}"
  fi
  chmod 600 "$cfg"
}

write_compose() {
  local yml="${BASE_DIR}/compose.yml"
  log "Writing compose.yml: ${yml}"

  # Host path mounts from HOST_PATHS
  local mounts=""
  IFS=',' read -r -a paths <<< "${HOST_PATHS:-/etc,/home,/root,/var/spool/cron}"
  for p in "${paths[@]}"; do
    mounts+="      - ${p}:/host${p}:ro"$'\n'
  done

  : "${IMAGE:?IMAGE must be set in .env}"
  : "${TZ:=Africa/Maputo}"
  : "${BACKUP_ROOT:=/var/backups}"

  cat > "$yml" <<EOF
services:
  hf-backup-${facility_code}:
    image: ${IMAGE}
    container_name: hf-backup-${facility_code}
    hostname: hf-backup-${facility_code}
    network_mode: host
    env_file: 
      - ./.env
    volumes:
      # runtime config for backup.sh
      - ${BASE_DIR}/runtime:/app

      # borgmatic config
      - ${BASE_DIR}/config/borgmatic.d:/etc/borgmatic.d:ro

      # borg cache/state persistence
      - ${BASE_DIR}/state:/root/.cache

      # local backups storage (mapped to BACKUP_ROOT inside container)
      - ${BASE_DIR}/backups:${BACKUP_ROOT}

      # ssh keys
      - ${BASE_DIR}/ssh:/root/.ssh:ro
      
      # Log volume
      - ${BASE_DIR}/logs:/app/logs

      # host data mounts (read-only)
${mounts}

EOF
}

write_systemd() {
  local svc="/etc/systemd/system/hf-backup-${facility_code}.service"
  local tmr="/etc/systemd/system/hf-backup-${facility_code}.timer"

  : "${RUN_DAILY_AT:=01:00}"

  log "Writing systemd units..."

  cat > "$svc" <<EOF
[Unit]
Description=Health Facility Backup (${facility_code^^})
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${BASE_DIR}
ExecStart=${DOCKER_COMPOSE_CMD} -f ${BASE_DIR}/compose.yml run --rm hf-backup-${facility_code}
TimeoutStartSec=0

EOF

  local hh="${RUN_DAILY_AT%:*}"
  local mm="${RUN_DAILY_AT#*:}"
  if [[ ! -f "${tmr}" ]]; then
    log "Creating systemd timer: ${tmr}"
    cat > "$tmr" <<EOF
[Unit]
Description=Backup schedule for Health Facility (${facility_code^^})

[Timer]
OnCalendar=*-*-* ${hh}:${mm}:00
Persistent=true

[Install]
WantedBy=timers.target

EOF
  else
    log "Timer file already exists (not overwriting). See hf-tool.sh: ${tmr}"
  fi
  systemctl daemon-reload
  systemctl enable --now "${tmr}"
  log "Enabled ${tmr} (daily at ${RUN_DAILY_AT})"
}

write_hf_tool() {
  local f="${BASE_DIR}/hf-tool.sh"
  cat > "$f" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# common helpers

log(){ echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
die(){ echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# read simple key=value from an INI-like file
_read_ini_value(){
    local file="$1" key="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d'=' -f2- \
        | tr -d '"' | tr -d "'"
}

# write status key=value to .env
_write_status(){
    local key="$1" value="$2"
    local statusfile=".env"
    # update or add the key
    if grep -q "^${key}=" "$statusfile" 2>/dev/null; then
        sed -i "s/^${key}=.*/${key}=${value}/" "$statusfile"
    else
        echo "${key}=${value}" >> "$statusfile"
    fi
}

# read status from .env
_read_status(){
    local key="$1"
    local statusfile=".env"
    if [[ -f "$statusfile" ]]; then
        grep -E "^${key}=" "$statusfile" 2>/dev/null | head -n1 | cut -d'=' -f2- || echo ""
    fi
}

# check if initialization is complete (signed cert exists)
_is_init_complete(){
    local cert="${BASE_DIR}/ssh/tls/hf-backup-${facility_code}-client.crt"
    [[ -f "$cert" ]]
}

# default restore point directory for shell mode
default_restore_point="/tmp/hf-backup-"$(basename `pwd`)

# run an interactive shell inside the backup container
_do_shell(){
    echo "If you are going to restore files, please specify temporary restore directory."
    read -rp "Enter directory name default [${default_restore_point}]: " restore_point
    if [[ -n ${restore_point} ]];then
      volume="-v "${restore_point}":/restore"
    else
      volume="-v "${default_restore_point}":/restore"
    fi
    echo
    echo "Starting container...... ${restore_point:-$default_restore_point} mounted on /restore"
    echo
    docker compose -f /opt/hf-backup/${facility_code}/compose.yml run ${volume} -w /restore --rm hf-backup-${facility_code} shell
    echo
    echo "=============================="
    echo "Container destroyed, bye!"
    echo "=============================="
    echo
    echo "You can find your files in ${restore_point:-$default_restore_point}"
    echo "If you want to remove the temporary restore directory, please run: rm -rf ${restore_point:-$default_restore_point}"
    echo
    echo "Have a nice day!"
    echo
}

# interactive schedule editor (merged from hf_backup_schedule.sh)
_do_schedule(){
    # require root permissions
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run with sudo"
    fi

    local TIMER_FILE
    TIMER_FILE="/etc/systemd/system/hf-backup-"$(basename `pwd`)".timer"

    if [[ ! -f "$TIMER_FILE" ]]; then
         die "Timer file not found: $TIMER_FILE"
    fi

    echo "Current OnCalendar schedules:"
    grep "^OnCalendar=" "$TIMER_FILE" || echo "No OnCalendar entries found"

    echo ""
    # prepare a comma-separated default value from existing lines (times only)
    local current_schedule
    current_schedule=$(grep "^OnCalendar=" "$TIMER_FILE" \
        | sed -e 's/^OnCalendar=\*-\*-\* *//' \
        | paste -sd, -)

    # if no existing entries, try pulling from INI
    if [[ -z "$current_schedule" ]]; then
        local run_daily
        run_daily=${RUN_DAILY_AT}
        if [[ -n "$run_daily" ]]; then
            IFS=',' read -ra times <<< "$run_daily"
            local valid=true
            for t in "${times[@]}"; do
                if ! [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    warn "INI provides invalid RUN_DAILY_AT value: '$t'"
                    valid=false
                    break
                fi
            done
            if $valid; then
                current_schedule="$run_daily"
                echo "(default schedule from .env: $current_schedule)"
            fi
        fi
    fi

    read -p "Do you want to modify the schedules? (y/n): " -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
         return 0
    fi

    # Backup original file
    cp "$TIMER_FILE" "${TIMER_FILE}.bak"

    # Create temporary file for editing
    local temp_file
    temp_file=$(mktemp)
    grep -v "^OnCalendar=" "$TIMER_FILE" > "$temp_file"

    # ask for new schedule
    local schedule
    while true; do
        read -rp "Enter new OnCalendar schedule(s) (comma-separated HH:MM) [${current_schedule}]: " schedule
        schedule=${schedule:-$current_schedule}
        # validate each comma-separated element
        local bad=false
        IFS=',' read -ra parts <<< "$schedule"
        for t in "${parts[@]}"; do
            t="${t// /}"
            if [[ -z "$t" ]]; then
                continue
            fi
            if ! [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                bad=true
                break
            fi
        done
        if $bad; then
            echo "Invalid schedule format; please separate times with commas and use HH:MM." >&2
        else
            break
        fi
    done

    # generate schedule lines and insert under [Timer]
    if [[ -n "$schedule" ]]; then
        local schedule_lines
        schedule_lines=""
        IFS=',' read -ra parts <<< "$schedule"
        for t in "${parts[@]}"; do
            t="${t// /}"
            [[ -z "$t" ]] && continue
            schedule_lines+="OnCalendar=*-*-* $t\\n"
        done
        if [[ -n "$schedule_lines" ]]; then
            sed -i "/^\[Timer\]/a $schedule_lines" "$temp_file"
        fi
    fi

    # Replace timer file
    mv "$temp_file" "$TIMER_FILE"

    echo "Timer file updated. Reloading systemd..."
    systemctl daemon-reload
    systemctl restart hf-backup-${facility_code}.timer

    # show newly written schedule lines
    if [[ -n "$schedule" ]]; then
        echo "New OnCalendar entries:"
        IFS=',' read -ra parts <<< "$schedule"
        for t in "${parts[@]}"; do
            t="${t// /}"
            [[ -z "$t" ]] && continue
            echo "  * $t"
        done
    fi

    echo "Changes applied successfully!"
}

# run a one-time backup container invocation
_do_backup_now(){
    # check if initialization is complete
    if [[ ! -f "${BASE_DIR}/.env" ]]; then
        die "Initialization status not found. Run: ./hf-tool.sh --init"
    fi
    if  grep -q "^_monitoring=enabled" "${BASE_DIR}/.env"; then
        if ! _is_init_complete; then
            die "Initialization not complete. Signed certificate missing. Run: ./hf-tool.sh --gen-cert"
        fi
    fi
    local cmd
    if docker compose version >/dev/null 2>&1; then
        cmd="$(which docker) compose"
    elif command -v docker-compose >/dev/null; then
        cmd="$(which docker-compose)"
    else
        die "Docker Compose not found."
    fi

    echo "Running immediate backup container..."
    $cmd -f /opt/hf-backup/${facility_code}/compose.yml run --rm hf-backup-${facility_code}
}

_do_gen_monitoring_cert() {
  have_cmd openssl || die "openssl not found; install openssl to generate TLS credentials"
  have_cmd sftp || die "sftp not found; install OpenSSH client for CSR exchange"

  if [[ -f ".env" ]]; then
      enable_monit=$(_read_ini_value ".env" "^_monitoring")
  fi

  if [[ "$enable_monit" != "enabled" ]]; then
      warn "Monitoring is not enabled in .env skipping monitoring configuration."
      _write_status "_monitoring" "disabled"
  else
      _write_status "_monitoring" "enabled"

      local tlsdir="${BASE_DIR}/ssh/tls"
      mkdir -p "$tlsdir"
      local key="${tlsdir}/hf-backup-${facility_code}-client.key"
      local csr="${tlsdir}/hf-backup-${facility_code}-client.csr"
      local cert="${tlsdir}/hf-backup-${facility_code}-client.crt"
      local cacert="${tlsdir}/private-ca.crt"
    
      echo
      log "Starting certificate key exchange process for monitoring setup..."
    
      # check if signed certificate already exists - if so, skip CSR generation and upload
      if [[ -f "$cert" ]]; then
        log "Signed certificate already present: ${cert}"
        _write_status "_cert_downloaded" "yes"
        _write_status "_status" "complete"
        echo
        warn "Certificate already exists. You can now proceed with initialization: ./hf-tool.sh --init"
        echo
        exit 0
      fi
    
      if [[ -f "$key" && -f "$csr" ]]; then
        log "Monitoring TLS key and CSR already exist: ${key}"
      else
        log "Generating monitoring TLS Private key"
        openssl genrsa -out "$key" 4096
        _write_status "_private_key_generated" "yes"
        log "Generating monitoring TLS CSR with CN=hf-backup-${facility_code}"
        openssl req -new -key "$key" -out "$csr" \
          -subj "/C=MZ/O=CSAude/OU=HF/CN=hf-backup-${facility_code}"
        _write_status "_csr_generated" "yes"
        chmod 600 "$key"
        chmod 644 "$csr"
      fi
    
      # remote server configuration
      local remote_host remote_port
      if [[ -f ".env" ]]; then
          remote_host=$(_read_ini_value ".env" CENTRAL_HOST)
          remote_port=$(_read_ini_value ".env" CENTRAL_PORT)
      fi
      remote_host=${remote_host:-hf-backup.csaude.org.mz}
      remote_port=${remote_port:-22}
      local remote_user="${facility_code}"
      # Paths are relative to the chrooted home directory (e.g., /backup/csaude/chabeco/)
      # Use . for current dir in csr folder, ../signed for sibling signed folder
      local csr_filename="hf-backup-${facility_code}-client.csr"
      local cert_filename="hf-backup-${facility_code}-client.crt"
    
      # test SFTP connectivity before attempting uploads
      echo
      log "Testing SFTP connectivity to ${remote_user}@${remote_host}:${remote_port} with KEK key..."
      log "SSH key location: ${BASE_DIR}/ssh/id_kek"
      echo
      if [[ ! -f "${BASE_DIR}/ssh/id_kek" ]]; then
          die "KEK SSH key not found: ${BASE_DIR}/ssh/id_kek"
      fi
      
      # Test connectivity - disable errexit temporarily
      local sftp_conn_output
      set +e
      sftp_conn_output=$(sftp -q -oBatchMode=yes -P "$remote_port" -i "${BASE_DIR}/ssh/id_kek" "${remote_user}@${remote_host}" 2>&1 <<'SFTP_TEST'
pwd
bye
SFTP_TEST
)
      local sftp_rc=$?
      set -e
      
      log "SFTP connection test output: $sftp_conn_output"
      
      if [[ $sftp_rc -ne 0 ]]; then
          die "SFTP connectivity failed (code $sftp_rc). Error: $sftp_conn_output"
      fi
      log "SFTP connectivity confirmed."
    
      # check if CSR already exists on remote server
      log "Checking if CSR already exists on server..."
      local remote_csr_check
      set +e
    
      remote_csr_check=$(sftp -q -oBatchMode=yes -P "$remote_port" -i "${BASE_DIR}/ssh/id_kek" "${remote_user}@${remote_host}" 2>&1 <<SFTP_LS
ls "$csr_filename"
bye
SFTP_LS
)
      local csr_exists_rc=$?
      set -e
      
      if [[ $csr_exists_rc -eq 0 ]] && [[ $(echo "$remote_csr_check" | grep -c "^$csr_filename") -gt 0 ]]; then
          log "CSR already exists on server, skipping upload."
          _write_status "_csr_submitted" "yes"
      else
          log "CSR not found on server or checking failed, uploading now..."
          
          # upload CSR
          if [[ ! -f "$csr" ]]; then
              warn "CSR file not found at $csr; skipping upload"
              _write_status "_status" "pending_csr_submit"
              return 1
          fi
          
          log "Uploading CSR to ${remote_user}@${remote_host}:22"
          local sftp_output
          set +e
          sftp_output=$(sftp -q -oBatchMode=yes -P "$remote_port" -i "${BASE_DIR}/ssh/id_kek" "${remote_user}@${remote_host}" 2>&1 <<SFTP_UPLOAD
put "$csr" "$csr_filename"
bye
SFTP_UPLOAD
)
          local csr_rc=$?
          set -e
          
          log "SFTP output: $sftp_output"
          
          if [[ $csr_rc -ne 0 ]]; then
              warn "CSR upload failed (exit code $csr_rc). SFTP error: $sftp_output"
              _write_status "_status" "pending_csr_submit"
          else
              if echo "$sftp_output" | grep -qi "error\|failed\|not found"; then
                  warn "SFTP command may have failed. Output: $sftp_output"
                  _write_status "_status" "pending_csr_submit"
              else
                  log "CSR uploaded successfully."
                  _write_status "_csr_submitted" "yes"
              fi
          fi
      fi
      
      _write_status "_status" "pending_cert_download"
    
      # attempt download of signed certificate
      log "Checking for signed certificate on server..."
      local cert_output
      set +e
      cert_output=$(sftp -q -oBatchMode=yes -P "$remote_port" -i "${BASE_DIR}/ssh/id_kek" "${remote_user}@${remote_host}" 2>&1 <<SFTP_GET
get "../signed/$cert_filename" "$cert"
get "../signed/private-ca.crt" "$cacert"
bye
SFTP_GET
)
      local cert_rc=$?
      set -e
    
      if [[ $cert_rc -eq 0 ]]; then
          if [[ -f "$cert" ]]; then
              log "Downloaded signed certificate to $cert"
              _write_status "_cert_downloaded" "yes"
              _write_status "_status" "complete"
              echo
              warn "Certificate download complete. You can now proceed with initialization: ./hf-tool.sh --init"
              echo
              exit 0
          else
              _write_status "_status" "pending_cert_download"
              warn "Signed certificate not yet available. Initialization aborted. Rerun this script once admin has signed and placed the certificate."
              exit 1
          fi
      else
          log "Certificate download returned code $cert_rc. Output: $cert_output"
          _write_status "_status" "pending_cert_download"
      fi
    fi
}

_do_init() {
    log "Initializing Health Facility Backup repo..."

    # check if signed certificate is present
    if  grep -q "^_monitoring=enabled" "${BASE_DIR}/.env"; then
        if ! _is_init_complete; then
            log "Monitoring is enabled but signed certificate is missing. Cannot proceed with initialization."
            echo
            die "Signed certificate not yet available. Initialization aborted. Run: ./hf-tool.sh --gen-cert"
        fi
    fi

    log "Signed certificate confirmed. Proceeding with borg repo initialization..."

    # finally run borg init via container
    local cmd
    if docker compose version >/dev/null 2>&1; then
        cmd="$(which docker) compose"
    elif command -v docker-compose >/dev/null; then
        cmd="$(which docker-compose)"
    else
        die "Docker Compose not found."
    fi

    $cmd -f ${BASE_DIR}/compose.yml run --rm hf-backup-${facility_code} init
    _write_status "_borg_initialized" "yes"
    log "Initialization complete! You can now run backups using: $0 --backup-now"
    rm -f hf-"${facility_code}"-keys.tar.gz
}

_usage(){
    cat <<'EOH' >&2
Usage: ./hf-tool.sh [COMMAND]

Commands:
  --help       show this help message
  --shell      open a shell in the HF backup container (restore files)
  --gen-cert   generate TLS key and CSR for monitoring (uploads CSR to server)
  --init       initialize borg repo on central server (requires signed certificate)
  --schedule   interactively edit the systemd timer schedule
  --backup-now run an immediate backup using the container (requires completed init)
  --status     check initialization status (private key, CSR, cert download)


EOH
  exit 1
}

# ===== entry point =====
BASE_DIR=$(pwd)
 enable_monit=$(cat .env | grep -i 'ENABLE_MONIT=' |sed 's/ //g'|sed 's/-//g' |grep -i "^ENABLE_MONIT=" || true)
 if [[ -n "$enable_monit" ]]; then
    enable_monit=${enable_monit#*=}
 else
    enable_monit="false"
 fi
 
if [[ "$enable_monit" == "true" ]]; then
    _write_status "_monitoring" "enabled"
else
    _write_status "_monitoring" "disabled"
fi

if [[ $# -lt 1 ]]; then
    _usage
fi
facility_code=$(basename "$(pwd)")
: ".env"

case "$1" in
    --help|-h)     _usage ;;
    --shell)       _do_shell ;; 
    --schedule)    _do_schedule ;; 
    --backup-now)  _do_backup_now ;;
    --gen-cert)    _do_gen_monitoring_cert ;;
    --init)        _do_init ;;
    --status)      cat "${BASE_DIR}/.env" |grep "^_" 2>/dev/null || echo "No status file found." ;;
    *)             _usage ;; 
esac

EOF
  chmod +x "$f"
}

write_pushgw_event_script() {
  local f="${BASE_DIR}/runtime/pushgw_event.sh"
  cat > "$f" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   pushgw_event.sh <phase> <state>
# Example:
#   pushgw_event.sh backup starting

PHASE="${1:-unknown}"
STATE="${2:-unknown}"
LOG_FILE="/app/logs/"`date +'%Y%m%d'`-"${facility_code}-backup.log"
# Identify this HF / instance
INSTANCE="${BORG_HOSTNAME:-$(hostname -s)}"

# Where to push (behind NGINX with mTLS)
PUSH_URL="${PUSHGATEWAY_URL:-https://push.csaude.org.mz}"

# mTLS client credentials (issued by your Private CA)
CLIENT_CERT="${PUSHGW_CLIENT_CERT:-/root/.ssh/pushgw-client.crt}"
CLIENT_KEY="${PUSHGW_CLIENT_KEY:-/root/.ssh/pushgw-client.key}"
CA_CERT="${PUSHGW_CA_CERT:-/root/.ssh/private-ca.crt}"

JOB="${PUSHGW_JOB:-hf_backup}"

# unix timestamp
NOW="$(date +%s)"

# Map state to numeric
# 1 = starting, 2 = completed, 3 = failed (simple but useful)
CODE=0
case "${STATE}" in
  starting)  CODE=1 ;;
  completed) CODE=2 ;;
  failed)    CODE=3 ;;
  *)         CODE=0 ;;
esac

# Optional: record borgmatic command context
BM_ACTION="${BORG_ACTION:-}"
BM_REPO="${BORG_REPOSITORY:-}"

# Push metrics in Prometheus text format
# NOTE: Pushgateway groups by job + instance + (optional) phase label.
# We'll encode phase as a label.
PAYLOAD="$(cat <<EOFPUSH
# TYPE hf_backup_phase_state gauge
hf_backup_phase_state{phase="${PHASE}",state="${STATE}"} ${CODE}
# TYPE hf_backup_phase_last_timestamp_seconds gauge
hf_backup_phase_last_timestamp_seconds{phase="${PHASE}",state="${STATE}"} ${NOW}
# TYPE hf_backup_info gauge
hf_backup_info{instance="${INSTANCE}",action="${BM_ACTION}",repository="${BM_REPO}"} 1
EOFPUSH
)"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] - phase=${PHASE} state=${STATE} code=${CODE}" >>$LOG_FILE
echo ${PAYLOAD} >>$LOG_FILE
# Push to a stable grouping key so later pushes replace prior values
# (job/instance are grouping keys; labels inside metrics can vary)

if $ENABLE_MONIT; then
  echo "Sending event to Pushgateway......." >>$LOG_FILE
  echo "${PAYLOAD}" | curl -sS --fail \
    --cert "${CLIENT_CERT}" \
    --key "${CLIENT_KEY}" \
    --cacert "${CA_CERT}" \
    --data-binary @- \
    "${PUSH_URL}/metrics/job/${JOB}/instance/${INSTANCE}"
else
  echo "Monitoring disabled; skipping Pushgateway event." >>$LOG_FILE
fi

find ./logs/*.log -type f -mtime +$((LOCAL_DUMP_RETENTION_DAYS * 2)) -delete

EOF
  chmod +x "$f"
}

main() {
  BASE_DIR=$(pwd)
  facility_code=$(pwd | xargs basename)
  IMAGE="hub.csaude.org.mz/backup/hf_backup:1.0"
  CENTRAL_HOST="hf-backup.csaude.org.mz"
  show_welcome_message  
  write_env_file
  prompt_borg_passphrase
  load_ini ".env"
  require_docker
  write_dirs
  gen_ssh_keys
  write_backup_script
  write_pushgw_event_script
  write_borgmatic_config
  write_hf_tool
  write_compose
  write_systemd
  
  if ! ensure_image_available "$(cat compose.yml |grep image |sed 's/image://g'|sed 's/ //g')"; then
    die "Required image '${IMAGE:-}' not available; aborting."
  else
    log "Required image '${IMAGE:-}' is already loaded."
  fi
  
  echo
  log "Installer complete."
  echo
  echo
  echo "NEXT STEPS:"
  echo "  1) Edit runtime config (HF safe):"
  echo "     sudo vim ${BASE_DIR}/.env"
  echo "     - Set DB credentials (optional)"
  echo
  echo "  2) Send delivery archive to central admin:"
  echo "     ${BASE_DIR}/hf-backup-${facility_code}-credentials.tar.gz"
  echo
  echo "  3) When central repo is ready, init once:"
  echo "     ./hf-tool.sh --gen-cert"
  echo "     ./hf-tool.sh --init"
  echo
  echo "  5) Run a manual backup test:"
  echo "     sudo ./hf-tool.sh --backup-now"
}

main "$@"
