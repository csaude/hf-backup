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
    # update or add the key; use | as delimiter to avoid clashing with / in paths
    if grep -q "^${key}=" "$statusfile" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$statusfile"
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

# _protect_write <target> <tmpfile>
# If target does not exist: moves tmpfile into place (returns 0 = created).
# If target exists and is identical to tmpfile: removes tmpfile (returns 1 = unchanged).
# If target exists and differs: writes target.new + target.diff, warns (returns 2 = diff written).
# tmpfile is always consumed (moved or removed).
_protect_write(){
    local target="$1" tmp="$2"
    if [[ ! -f "$target" ]]; then
        mv "$tmp" "$target"
        return 0
    fi
    if diff -q "$target" "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        log "$(basename "$target"): unchanged — no update needed."
        return 1
    fi
    mv "$tmp" "${target}.new"
    diff -u "$target" "${target}.new" > "${target}.diff" 2>/dev/null || true
    warn "$(basename "$target") already exists and differs from the new template."
    warn "  New version  : ${target}.new"
    warn "  Differences  : ${target}.diff"
    warn "  To apply     : cp ${target}.new ${target} && rm ${target}.new ${target}.diff"
    return 2
}

# _merge_env_file <existing> <template>
# Handles re-runs of the installer when .env already exists:
#   - Keys present in template but absent in existing  → shown to user, inserted at
#     the correct position (before the next template key that already exists), together
#     with any comment lines that immediately precede them in the template.
#   - Keys whose values differ (intentional customisations) → .diff written for review;
#     the existing values are never overwritten.
#   - template file is always removed on exit.
_merge_env_file(){
    local existing="$1" template="$2"

    # ── Build ordered key list from template ─────────────────────────────────
    local -a tpl_order=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
        tpl_order+=("${line%%=*}")
    done < "$template"

    # ── Categorise differences ────────────────────────────────────────────────
    local -a new_keys=()
    local has_value_changes=false
    for key in "${tpl_order[@]}"; do
        if ! grep -q "^${key}=" "$existing" 2>/dev/null; then
            new_keys+=("$key")
        else
            local tval xval
            tval=$(grep "^${key}=" "$template"  | head -1)
            xval=$(grep "^${key}=" "$existing"  | head -1)
            [[ "$tval" != "$xval" ]] && has_value_changes=true
        fi
    done

    # ── Changed values → diff for reference (never auto-applied) ─────────────
    if $has_value_changes; then
        local _s_ex _s_tpl
        _s_ex=$(mktemp); _s_tpl=$(mktemp)
        sed 's/^\(BORG_PASSPHRASE=\).*/\1***REDACTED***/' "$existing"  > "$_s_ex"
        sed 's/^\(BORG_PASSPHRASE=\).*/\1***REDACTED***/' "$template"  > "$_s_tpl"
        diff -u "$_s_ex" "$_s_tpl" > "${existing}.diff" 2>/dev/null || true
        rm -f "$_s_ex" "$_s_tpl"
        warn "$(basename "$existing"): some template values differ from your config."
        warn "  These are likely intentional customisations — see $(basename "${existing}.diff")"
        warn "  Review manually; existing values have NOT been changed."
    fi

    # ── New keys → interactive positional insert ──────────────────────────────
    if [[ ${#new_keys[@]} -eq 0 ]]; then
        $has_value_changes || log "$(basename "$existing"): up to date — no new variables."
        rm -f "$template"
        return 0
    fi

    echo
    log "New variables available in the updated template:"
    echo
    for key in "${new_keys[@]}"; do
        local val
        val=$(grep "^${key}=" "$template" | head -1 | cut -d'=' -f2-)
        printf "      %-32s = %s\n" "$key" "$val"
    done
    echo
    read -rp "Add these ${#new_keys[@]} new variable(s) to $(basename "$existing") at their correct positions? [Y/n] " _ans
    if [[ "${_ans,,}" == "n" ]]; then
        log "Skipped — new variables not added."
        rm -f "$template"
        return 0
    fi

    local work
    work=$(mktemp)
    cp "$existing" "$work"

    for key in "${new_keys[@]}"; do
        # Extract the comment block immediately preceding this key in the template
        # (lines between the previous blank line / key and this key) + the key=value line.
        local block_file
        block_file=$(mktemp)
        awk -v k="${key}=" '
            BEGIN { n=0 }
            /^[[:space:]]*$/ { n=0; delete buf; next }
            /^[A-Za-z_][A-Za-z0-9_]*=/ {
                if (index($0,k)==1) { for(i=0;i<n;i++) print buf[i]; print; exit }
                n=0; delete buf; next
            }
            { buf[n++]=$0 }
        ' "$template" > "$block_file"

        # Find anchor: first key after this one (in template order) that already
        # exists in the working copy — insert just before it.
        local anchor="" past=false
        for tk in "${tpl_order[@]}"; do
            [[ "$tk" == "$key" ]] && { past=true; continue; }
            $past && grep -q "^${tk}=" "$work" 2>/dev/null && { anchor="$tk"; break; }
        done

        if [[ -n "$anchor" ]]; then
            awk -v anchor="${anchor}=" -v bfile="$block_file" '
                !done && index($0,anchor)==1 {
                    if (substr(anchor,1,1) != "_") print ""
                    while ((getline line < bfile) > 0) print line
                    close(bfile)
                    done=1
                }
                { print }
            ' "$work" > "${work}.tmp" && mv "${work}.tmp" "$work"
        else
            # No anchor — insert before the dynamic-section separator, or append.
            if grep -q "^# .*Dynamic parameters" "$work"; then
                awk -v bfile="$block_file" '
                    !done && /^# .*Dynamic parameters/ {
                        print ""
                        while ((getline line < bfile) > 0) print line
                        close(bfile)
                        done=1
                    }
                    { print }
                ' "$work" > "${work}.tmp" && mv "${work}.tmp" "$work"
            else
                { echo ""; cat "$block_file"; } >> "$work"
            fi
        fi

        rm -f "$block_file"
        log "Added: ${key}=$(grep "^${key}=" "$template" | head -1 | cut -d'=' -f2-)"
    done

    # Collapse any double blank lines produced by insertions into a single blank line
    awk 'prev=="" && /^[[:space:]]*$/ { next } { prev=$0; print }' \
        "$work" > "${work}.tmp" && mv "${work}.tmp" "$work"

    mv "$work" "$existing"
    chmod 600 "$existing"
    rm -f "$template"
    log "$(basename "$existing") updated with ${#new_keys[@]} new variable(s)."
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

  # Interactive loop until user succeeds or skips
  while true; do
    echo "Image '${image}' not found locally."
    read -rp "Pull from registry (p), load from file (l), or skip for now (.)? [p/l/.] " choice
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
        read -rp "Path to image tarball (enter '.' to go back): " fpath
        if [[ "${fpath}" == "." ]]; then
          break
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
    elif [[ "${choice}" == "." ]]; then
      warn "Skipping image check. Ensure '${image}' is available before running backups."
      return 0
    else
      echo "Please enter 'p' (pull), 'l' (load), or '.' (skip)."
    fi
  done
}

write_dirs() {
  : "${BASE_DIR:=/opt/hf-backup}"
  mkdir -p \
    "${BASE_DIR}/ssh/tls" \
    "${BASE_DIR}/state" \
    "${BASE_DIR}/config/borgmatic.d" \
    "${BASE_DIR}/runtime/backups" \
    "${BASE_DIR}/runtime/logs" \
    "${BASE_DIR}/runtime/dbconf" \
    "${BASE_DIR}/runtime/web-server"

  chmod 700 "${BASE_DIR}/ssh"
  chmod 700 "${BASE_DIR}/runtime/dbconf"
  chmod 750 "${BASE_DIR}/runtime/backups"
}

gen_ssh_keys() {
  # SSH keys are only needed for central mode
  if [[ "${BORG_MODE:-central}" == "local" ]]; then
    log "Local mode — SSH key generation skipped."
    return 0
  fi

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
    _write_status "_keys" "yes"
    log "SSH public key bundle created: ./hf-${facility_code}-keys.tar.gz"
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
#load_ini "$ENV_FILE"

# --- Defaults ---
BACKUP_ROOT="${BACKUP_ROOT:-/app/backups}"
DB_DIR="${BACKUP_ROOT}/db"
TS="$(date +%F_%H-%M-%S)"
mkdir -p "${DB_DIR}/mysql" "${DB_DIR}/postgres"

#log "Using config: ${ENV_FILE}"
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

# ---------- DB dumps (conf-file driven) ----------
DB_CONF_DIR="${DB_CONF_DIR:-/app/dbconf}"

if compgen -G "${DB_CONF_DIR}/.*.conf" > /dev/null 2>&1; then
  for conf in "${DB_CONF_DIR}"/.*.conf; do
    [[ -f "$conf" ]] || continue

    # derive dump prefix from filename (strip leading dot and .conf)
    name=$(basename "$conf"); name="${name#.}"; name="${name%.conf}"

    # parse conf into local vars (scoped to subshell to avoid leaking)
    unset DB_TYPE BACKUP HOST PORT USER PASSWORD DATABASE
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      key="${line%%=*}"; val="${line#*=}"
      val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
      [[ "$val" =~ ^\".*\"$ ]] && val="${val:1:${#val}-2}"
      [[ "$val" =~ ^\'.*\'$ ]] && val="${val:1:${#val}-2}"
      export "$key=$val"
    done < "$conf"

    if [[ "${BACKUP,,:-false}" != "true" ]]; then
      log "DB [${name}]: BACKUP=false, skipping."
      continue
    fi

    case "${DB_TYPE^^:-}" in
      M)
        PORT="${PORT:-3306}"
        OUT="${DB_DIR}/mysql/${name}_${TS}.sql.gz"
        log "MySQL [${name}]: dumping '${DATABASE}' from ${HOST}:${PORT} -> ${OUT}"
        mysqldump \
          --host="${HOST}" --port="${PORT}" \
          --user="${USER}" --password="${PASSWORD}" \
          --single-transaction --routines --triggers --events \
          --databases "${DATABASE}" \
        | gzip -1 > "${OUT}"
        ;;
      P)
        PORT="${PORT:-5432}"
        export PGPASSWORD="${PASSWORD}"
        OUT="${DB_DIR}/postgres/${name}_${TS}.dump"
        log "Postgres [${name}]: dumping '${DATABASE}' from ${HOST}:${PORT} -> ${OUT}"
        pg_dump \
          -h "${HOST}" -p "${PORT}" -U "${USER}" \
          -F c -Z 1 -f "${OUT}" \
          "${DATABASE}"
        unset PGPASSWORD
        ;;
      *)
        warn "DB [${name}]: unknown DB_TYPE '${DB_TYPE:-}' (expected M or P), skipping."
        ;;
    esac
  done
else
  log "No DB config files found in ${DB_CONF_DIR}; skipping DB dumps."
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

_find_free_port() {
  # Find a free TCP port starting at $1, incrementing by 1 until one is available.
  local port="${1:-22587}"
  while ss -tlnH "sport = :${port}" 2>/dev/null | grep -q ":${port}"; do
    port=$(( port + 1 ))
  done
  echo "$port"
}

write_env_file() {
  local f=".env"

  : "${BACKUP_ROOT:=/app/backups}"
  : "${LOCAL_DUMP_RETENTION_DAYS:=7}"
  : "${CENTRAL_HOST:=CENTRAL_HOST}"
  : "${CENTRAL_PORT:=22}"
  : "${REPO_PATH:=/repos/HF001}"

  local _enable_monit
  [[ "${_borg_mode:-central}" == "local" ]] && _enable_monit="false" || _enable_monit="true"

  # Determine a free port for the local web server.
  # If .env already has a WEB_PORT, reuse it; otherwise probe for a free one.
  local _web_port=""
  if [[ -f ".env" ]]; then
    _web_port=$(grep -E '^WEB_PORT=' .env | cut -d= -f2 | tr -d '"' | tr -d "'" | head -1)
  fi
  if [[ -z "${_web_port}" ]]; then
    _web_port=$(_find_free_port 22587)
    log "Web server port: ${_web_port}"
  fi

  local _tmpf
  _tmpf=$(mktemp)
  cat > "$_tmpf" <<EOF
# =========================================================
# Runtime config for container (${f})
# HF edits ONLY this file (safe).
# =========================================================

# Where backup.sh writes dumps inside container
BACKUP_ROOT=${BACKUP_ROOT}

ENABLE_MONIT=${_enable_monit}

# Local dump retention:
# empty => keep forever
# 0     => delete all previous dumps before new run
# N     => delete dumps older than N days
LOCAL_DUMP_RETENTION_DAYS=7

FACILITY_CODE="${facility_code}"

# ---- BORG Central Server ----
CENTRAL_HOST=${CENTRAL_HOST}
CENTRAL_PORT=${CENTRAL_PORT:-22}

# ---- Central borg upload control ----
# true  => try upload to central (best-effort)
# false => only create local dumps (never tries SSH)
BORG_SERVER_ENABLED=true

# warn => if upload fails (no internet), log warning and exit success
# fail => if upload fails, job fails
BORG_FAIL_MODE=warn

# Backup mode: central (SSH borg server) or local (external storage device)
# Switch to 'local' if there is no central borg server.
BORG_MODE=${_borg_mode:-central}

# For local mode: absolute host path to the external storage mount point.
# Must be a mounted external device (USB drive, external HDD, NAS mount).
# Example: /mnt/usb   or   /media/backup-drive
EXTERNAL_STORAGE_PATH=

# Borg repo settings
BORG_REPO=ssh://${facility_code}@${CENTRAL_HOST}:${CENTRAL_PORT}/./repo
BORG_PASSPHRASE=CHANGE_ME_TO_A_STRONG_PASSPHRASE
# Optional (central mode only):
BORG_RSH="ssh -o StrictHostKeyChecking=accept-new -i /root/.ssh/id_rsa"

BORGMATIC_VERBOSITY=2

# Backup schedule (HH:MM, comma-separated for multiple daily runs)
SCHEDULE=14:30

# ---- Local Web Status Server ----
# Port for the local backup status web server (accessible on the HF LAN)
WEB_PORT=${_web_port}

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

_hf_backup_executed=no
_keys=no
_monitoring=unknown
_csr_generated=no
_private_key_generated=no
_csr_submitted=no
_cert_downloaded=no
_ca_cert_downloaded=no
_cert_downloaded=no
_borg_initialized=no
_status=not_initialized
# -----------------------------------------------------------------------------

EOF

  if [[ ! -f "$f" ]]; then
    mv "$_tmpf" "$f"
    chmod 600 "$f"
    log "Created ${f}."
  else
    # File already exists — smart merge: add new variables, diff changed values.
    _merge_env_file "$f" "$_tmpf"
  fi

  # Always ensure WEB_PORT reflects the resolved value (covers re-runs where
  # the merge skips already-present keys but the port may have changed).
  _write_status "WEB_PORT" "${_web_port}"
}

write_borgmatic_config() {
  local cfg="${BASE_DIR}/config/borgmatic.d/config.yaml"
  local runtime_ini=".env"
  : "${BACKUP_ROOT:=/app/backups}"

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

  local _tmpcfg
  _tmpcfg=$(mktemp)
  cat > "$_tmpcfg" <<EOF
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

  local _rccfg=0
  _protect_write "${cfg}" "$_tmpcfg" || _rccfg=$?
  if [[ $_rccfg -eq 0 ]]; then
    log "Created borgmatic config: ${cfg}"
  fi
  chmod 600 "${cfg}" 2>/dev/null || true
  [[ -f "${cfg}.new" ]] && chmod 600 "${cfg}.new" || true
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

  # Extra volumes for the hf-web service
  local web_extra_mounts=""
  web_extra_mounts+="      - ${BASE_DIR}/runtime/logs:/app/logs:ro"$'\n'
  if [[ "${BORG_MODE:-central}" == "local" && -n "${EXTERNAL_STORAGE_PATH:-}" ]]; then
    web_extra_mounts+="      - ${EXTERNAL_STORAGE_PATH}:/mnt/external:ro"$'\n'
  fi

  : "${IMAGE:?IMAGE must be set in .env}"
  : "${TZ:=Africa/Maputo}"
  : "${BACKUP_ROOT:=/app/backups}"

  cat > "$yml" <<EOF
services:
  hf-backup-${facility_code}:
    image: ${IMAGE}
    container_name: hf-backup-${facility_code}
    hostname: hf-backup-${facility_code}
    network_mode: host
    command: "true"
    env_file:
      - ./.env
    volumes:
      # runtime config for backup.sh
      - ${BASE_DIR}/runtime:/app

      # borgmatic config
      - ${BASE_DIR}/config/borgmatic.d:/etc/borgmatic.d:ro

      # borg cache/state persistence
      - ${BASE_DIR}/state:/root/.cache

      # ssh keys
      - ${BASE_DIR}/ssh:/root/.ssh:ro

      # host data mounts (read-only)
${mounts}

  hf-web-${facility_code}:
    image: ${IMAGE}
    container_name: hf-web-${facility_code}
    hostname: hf-web-${facility_code}
    network_mode: host
    restart: unless-stopped
    command: python3 /app/web-server/server.py
    env_file:
      - ./.env
    volumes:
      - ${BASE_DIR}/runtime/web-server:/app/web-server
${web_extra_mounts}
EOF
}

write_systemd() {
  local svc="/etc/systemd/system/hf-backup-${facility_code}.service"
  local tmr="/etc/systemd/system/hf-backup-${facility_code}.timer"

  : "${SCHEDULE:=14:30}"

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
ExecStart=${DOCKER_COMPOSE_CMD} -f ${BASE_DIR}/compose.yml run --rm hf-backup-${facility_code} run
TimeoutStartSec=0

EOF

  local hh="${SCHEDULE%:*}"
  local mm="${SCHEDULE#*:}"
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
  log "Enabled ${tmr} (daily at ${SCHEDULE})"
}

write_trigger_units() {
  local path_unit="/etc/systemd/system/hf-backup-trigger-${facility_code}.path"
  local svc_unit="/etc/systemd/system/hf-backup-trigger-${facility_code}.service"
  local sentinel="${BASE_DIR}/runtime/web-server/trigger_backup"

  log "Writing trigger units: ${path_unit}"

  cat > "$path_unit" <<EOF
[Unit]
Description=Watch for web-triggered backup request (${facility_code^^})

[Path]
PathExists=${sentinel}

[Install]
WantedBy=multi-user.target
EOF

  cat > "$svc_unit" <<EOF
[Unit]
Description=Run immediate backup triggered from web UI (${facility_code^^})

[Service]
Type=oneshot
User=root
StandardInput=null
WorkingDirectory=${BASE_DIR}
ExecStart=/bin/bash ${BASE_DIR}/hf-tool.sh --backup-now
ExecStartPost=/bin/rm -f ${sentinel}
EOF

  systemctl daemon-reload
  systemctl enable --now "hf-backup-trigger-${facility_code}.path"
  log "Trigger path unit enabled: hf-backup-trigger-${facility_code}.path"
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
need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo $0"; }

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
    # update or add the key; use | as delimiter to avoid clashing with / in paths
    if grep -q "^${key}=" "$statusfile" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$statusfile"
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
    if [[ "$(_read_ini_value "${BASE_DIR}/.env" "BORG_MODE")" == "local" ]]; then
        _validate_local_repo
    fi

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
        run_daily=${SCHEDULE}
        if [[ -n "$run_daily" ]]; then
            IFS=',' read -ra times <<< "$run_daily"
            local valid=true
            for t in "${times[@]}"; do
                if ! [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    warn "INI provides invalid SCHEDULE value: '$t'"
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
    if [[ ! -f "${BASE_DIR}/.env" ]]; then
        die "Initialization status not found. Run: ./hf-tool.sh --init"
    fi

    if [[ "$(_read_ini_value "${BASE_DIR}/.env" "BORG_MODE")" == "local" ]]; then
        _validate_local_repo
    else
        if grep -q "^_monitoring=enabled" "${BASE_DIR}/.env"; then
            if ! _is_init_complete; then
                die "Initialization not complete. Signed certificate missing. Run: ./hf-tool.sh --init"
            fi
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
    $cmd -f /opt/hf-backup/${facility_code}/compose.yml run --rm hf-backup-${facility_code} run
}

_do_gen_monitoring_cert() {
  local _skip_prereqs="${1:-false}"
  have_cmd openssl || die "openssl not found; install openssl to generate TLS credentials"
  have_cmd sftp    || die "sftp not found; install OpenSSH client for CSR exchange"

  if [[ -f ".env" ]]; then
      enable_monit=$(_read_ini_value ".env" "^_monitoring")
  fi

  if [[ "$enable_monit" != "enabled" ]]; then
      warn "Monitoring is not enabled in .env — skipping certificate exchange."
      _write_status "_monitoring" "disabled"
      return 0
  fi

  _write_status "_monitoring" "enabled"

  local tlsdir="${BASE_DIR}/ssh/tls"
  mkdir -p "$tlsdir"
  local key="${tlsdir}/hf-backup-${facility_code}-client.key"
  local csr="${tlsdir}/hf-backup-${facility_code}-client.csr"
  local cert="${tlsdir}/hf-backup-${facility_code}-client.crt"
  local cacert="${tlsdir}/csaude-ca.crt"
  local csr_filename="hf-backup-${facility_code}-client.csr"
  local cert_filename="hf-backup-${facility_code}-client.crt"

  echo
  log "Certificate exchange for monitoring setup (facility: ${facility_code})"
  echo

  # Early exit — cert already present
  if [[ -f "$cert" ]]; then
      log "Signed certificate already present — nothing to do."
      _write_status "_cert_downloaded" "yes"
      _write_status "_status" "complete"
      return 0
  fi

  # Load remote server config
  local remote_host remote_port
  remote_host=$(_read_ini_value ".env" CENTRAL_HOST)
  remote_port=$(_read_ini_value ".env" CENTRAL_PORT)
  remote_host="${remote_host:-hf-backup.csaude.org.mz}"
  remote_port="${remote_port:-22}"
  local remote_user="${facility_code}"

  [[ -f "${BASE_DIR}/ssh/id_kek" ]] \
      || die "KEK SSH key not found: ${BASE_DIR}/ssh/id_kek — re-run the installer."

  # ── Prerequisites: confirm key bundle was shared and account is ready ────────
  # (skipped when called from --init, which handles this in its own staged flow)
  if [[ "$_skip_prereqs" != "skip_prereqs" ]]; then
    local keys_bundle="${BASE_DIR}/hf-${facility_code}-keys.tar.gz"
    echo
    if [[ -f "$keys_bundle" ]]; then
        warn "SSH key bundle: ${keys_bundle}"
    else
        warn "SSH key bundle: hf-${facility_code}-keys.tar.gz (not found in ${BASE_DIR})"
    fi
    echo
    read -rp "Have you shared the key bundle and has the central admin confirmed the account is ready? [y/N] " ans
    if [[ "${ans,,}" != "y" ]]; then
        echo
        warn "Share the key bundle with the central admin and wait for account confirmation."
        warn "Then re-run:  sudo ./hf-tool.sh --gen-cert"
        return 1
    fi
    echo
  fi

  # ── Step 1/3: test SFTP connectivity ────────────────────────────────────────
  log "Step 1/3 — Testing SFTP connectivity to ${remote_user}@${remote_host}:${remote_port}..."
  local sftp_conn_output sftp_rc
  set +e
  sftp_conn_output=$(sftp -q -oBatchMode=yes -P "$remote_port" \
      -i "${BASE_DIR}/ssh/id_kek" "${remote_user}@${remote_host}" 2>&1 <<'SFTP_TEST'
pwd
bye
SFTP_TEST
)
  sftp_rc=$?
  set -e

  if [[ $sftp_rc -ne 0 ]]; then
      echo
      die "Cannot reach the central server via SFTP (exit ${sftp_rc}).
       Verify that:
         1. The SSH key bundle was delivered to the central admin
         2. The admin has created the facility account on the server
         3. ${remote_host}:${remote_port} is reachable from this machine
       SFTP error: ${sftp_conn_output}"
  fi
  log "SFTP connectivity confirmed."
  echo

  # ── Step 2/3: generate TLS key + CSR ────────────────────────────────────────
  log "Step 2/3 — Generating TLS key and CSR..."
  if [[ -f "$key" && -f "$csr" ]]; then
      log "Key and CSR already exist — reusing."
  else
      log "Generating 4096-bit private key..."
      openssl genrsa -out "$key" 4096
      _write_status "_private_key_generated" "yes"
      log "Generating CSR (CN=hf-backup-${facility_code})..."
      openssl req -new -key "$key" -out "$csr" \
          -subj "/C=MZ/O=CSAude/OU=HF/CN=hf-backup-${facility_code}"
      _write_status "_csr_generated" "yes"
      chmod 600 "$key"
      chmod 644 "$csr"
  fi
  echo

  # ── Step 3/3: upload CSR ─────────────────────────────────────────────────────
  log "Step 3/3 — Uploading CSR to central server..."
  local remote_csr_check csr_exists_rc
  set +e
  remote_csr_check=$(sftp -q -oBatchMode=yes -P "$remote_port" \
      -i "${BASE_DIR}/ssh/id_kek" "${remote_user}@${remote_host}" 2>&1 <<SFTP_LS
ls "$csr_filename"
bye
SFTP_LS
)
  csr_exists_rc=$?
  set -e

  if [[ $csr_exists_rc -eq 0 ]] && echo "$remote_csr_check" | grep -q "^${csr_filename}"; then
      log "CSR already present on server — skipping upload."
      _write_status "_csr_submitted" "yes"
  else
      local sftp_output sftp_put_rc
      set +e
      sftp_output=$(sftp -q -oBatchMode=yes -P "$remote_port" \
          -i "${BASE_DIR}/ssh/id_kek" "${remote_user}@${remote_host}" 2>&1 <<SFTP_UPLOAD
put "$csr" "$csr_filename"
bye
SFTP_UPLOAD
)
      sftp_put_rc=$?
      set -e

      if [[ $sftp_put_rc -ne 0 ]] || echo "$sftp_output" | grep -qi "error\|failed\|not found"; then
          warn "CSR upload failed. SFTP output: ${sftp_output}"
          _write_status "_status" "pending_csr_submit"
          return 1
      fi
      log "CSR uploaded: ${csr_filename}"
      _write_status "_csr_submitted" "yes"
  fi

  _write_status "_status" "pending_cert_download"

  # ── Try to download the signed certificate ───────────────────────────────────
  # Downloads each file independently so a partial state is preserved across
  # retries and tracked in .env via _cert_downloaded / _ca_cert_downloaded.
  _try_download_cert(){
    local ok=0

    if [[ "$(_read_status '_cert_downloaded')" != "yes" ]]; then
      local c_out c_rc
      set +e
      c_out=$(sftp -q -oBatchMode=yes -P "$remote_port" \
          -i "${BASE_DIR}/ssh/id_kek" "${remote_user}@${remote_host}" 2>&1 <<SFTP_CERT
get "../signed/$cert_filename" "$cert"
bye
SFTP_CERT
)
      c_rc=$?
      set -e
      if [[ $c_rc -eq 0 && -f "$cert" ]]; then
        log "Signed certificate downloaded: ${cert_filename}"
        _write_status "_cert_downloaded" "yes"
      fi
    fi

    if [[ "$(_read_status '_ca_cert_downloaded')" != "yes" ]]; then
      local ca_out ca_rc
      set +e
      ca_out=$(sftp -q -oBatchMode=yes -P "$remote_port" \
          -i "${BASE_DIR}/ssh/id_kek" "${remote_user}@${remote_host}" 2>&1 <<SFTP_CA
get "../signed/csaude-ca.crt" "$cacert"
bye
SFTP_CA
)
      ca_rc=$?
      set -e
      if [[ $ca_rc -eq 0 && -f "$cacert" ]]; then
        log "CA certificate downloaded: csaude-ca.crt"
        _write_status "_ca_cert_downloaded" "yes"
      fi
    fi

    [[ "$(_read_status '_cert_downloaded')" == "yes" && \
       "$(_read_status '_ca_cert_downloaded')" == "yes" ]]
  }

  echo
  log "Checking whether the admin has already signed the certificate..."

  # Quick first attempt — succeeds silently if both files are already available
  if _try_download_cert; then
      _write_status "_status" "complete"
      return 0
  fi

  # Not yet fully available — show banner and poll for up to 30 seconds
  echo
  warn "═══════════════════════════════════════════════════════════"
  warn " Waiting for the central admin to sign the certificate."
  warn "═══════════════════════════════════════════════════════════"
  warn " The CSR has been uploaded. The admin must:"
  warn "   1. Sign:  ${csr_filename}"
  warn "   2. Place the signed .crt in the 'signed/' directory"
  warn "      on the central server for facility '${facility_code}'"
  warn ""
  warn " Once signed, re-run:  sudo ./hf-tool.sh --init"
  warn "═══════════════════════════════════════════════════════════"

  local waited=0 max_wait=30 interval=3
  printf " Waiting for signed certificate: %d" $(( max_wait - waited ))
  while [[ $waited -lt $max_wait ]]; do
      local tick=0
      while [[ $tick -lt $interval ]]; do
          sleep 1
          tick=$(( tick + 1 ))
          waited=$(( waited + 1 ))
          local remaining=$(( max_wait - waited ))
          if [[ $tick -lt $interval ]]; then
              printf "."
          else
              printf "%d" "$remaining"
          fi
      done
      if _try_download_cert; then
          printf "\n"
          _write_status "_status" "complete"
          return 0
      fi
  done
  printf "\n"

  die "Signed certificate not yet available. Re-run --init once the admin has signed the CSR."
}

_do_install_systemd(){
    need_root
    local svc="/etc/systemd/system/hf-backup-${facility_code}.service"
    local tmr="/etc/systemd/system/hf-backup-${facility_code}.timer"

    local dc_cmd
    if docker compose version >/dev/null 2>&1; then
        dc_cmd="$(which docker) compose"
    elif command -v docker-compose >/dev/null; then
        dc_cmd="$(which docker-compose)"
    else
        die "Docker Compose not found."
    fi

    local run_daily_at
    run_daily_at=$(_read_ini_value ".env" "SCHEDULE")
    run_daily_at="${run_daily_at:-14:30}"
    local hh="${run_daily_at%:*}"
    local mm="${run_daily_at#*:}"

    log "Writing systemd service: ${svc}"
    cat > "$svc" <<SVCEOF
[Unit]
Description=Health Facility Backup (${facility_code^^})
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${BASE_DIR}
ExecStart=${dc_cmd} -f ${BASE_DIR}/compose.yml run --rm hf-backup-${facility_code} run
TimeoutStartSec=0

SVCEOF

    if [[ ! -f "${tmr}" ]]; then
        log "Writing systemd timer: ${tmr}"
        cat > "$tmr" <<TMREOF
[Unit]
Description=Backup schedule for Health Facility (${facility_code^^})

[Timer]
OnCalendar=*-*-* ${hh}:${mm}:00
Persistent=true

[Install]
WantedBy=timers.target

TMREOF
    else
        log "Timer already exists (not overwriting): ${tmr}"
    fi

    systemctl daemon-reload
    systemctl enable --now "hf-backup-${facility_code}.timer"
    log "Timer enabled (default schedule: ${run_daily_at})"
}

_validate_external_storage(){
    local path="$1"
    [[ -z "$path" ]] && die "EXTERNAL_STORAGE_PATH is not set. Run: ./hf-tool.sh --set EXTERNAL_STORAGE_PATH"
    [[ -d "$path" ]] || die "External storage path does not exist: ${path}"

    # must be a mount point — not just any directory
    mountpoint -q "$path" 2>/dev/null \
        || die "${path} is not a mount point. Please mount your external storage device first."

    # must not be on the same block device as the root filesystem
    local root_dev ext_dev
    root_dev=$(stat -c %d /)
    ext_dev=$(stat -c %d "$path")
    [[ "$root_dev" != "$ext_dev" ]] \
        || die "${path} is on the same device as the root filesystem. An external storage device is required."

    log "External storage validated: ${path}"
}

_validate_local_repo(){
    local ext_path
    ext_path=$(_read_ini_value "${BASE_DIR}/.env" "EXTERNAL_STORAGE_PATH")

    # device must be present and mounted
    _validate_external_storage "$ext_path"

    # must contain an initialized borg repository
    local repo_config="${ext_path}/repo/config"
    if [[ ! -f "$repo_config" ]] || ! grep -q "^\[repository\]" "$repo_config"; then
        die "No initialized borg repository found on ${ext_path}. Run: ./hf-tool.sh --init"
    fi

    log "Borg repository verified on external storage: ${ext_path}/repo"
}

_select_and_prepare_external_disk() {
    # Check all required commands and collect missing packages in one pass
    local -a missing_pkgs=()
    have_cmd lsblk     || missing_pkgs+=(util-linux)
    have_cmd wipefs    || missing_pkgs+=(util-linux)
    have_cmd fdisk     || missing_pkgs+=(fdisk)
    have_cmd mkfs.ext4 || missing_pkgs+=(e2fsprogs)
    have_cmd partprobe || missing_pkgs+=(parted)
    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        # Deduplicate
        local -a deduped=()
        local prev=""
        for pkg in $(printf '%s\n' "${missing_pkgs[@]}" | sort -u); do
            deduped+=("$pkg")
        done
        die "Missing required tools. Run:  sudo apt install ${deduped[*]}"
    fi

    echo
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log " External Storage Setup"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Insert the USB drive or external disk now, then press ENTER to scan..."
    read -r
    echo

    # Determine the root disk(s) so we can exclude them.
    # Use lsblk -s (inverse tree) to handle LVM/LUKS/RAID stacks where the root
    # filesystem sits on /dev/mapper/... rather than directly on a disk partition.
    local root_dev
    root_dev=$(df / | tail -1 | awk '{print $1}')
    local -a root_disks=()
    mapfile -t root_disks < <(lsblk -slno NAME,TYPE "$root_dev" 2>/dev/null | awk '$2=="disk" {print $1}')
    if [[ ${#root_disks[@]} -eq 0 ]]; then
        # Fallback: strip trailing partition number from the device name
        root_disks=( "$(basename "$root_dev" | sed 's/p\?[0-9]\+$//')" )
    fi

    # Collect disk-type block devices, excluding the OS disk(s).
    # Use NAME,TYPE only (TYPE is reliably $2) to avoid MODEL spaces breaking awk.
    # Then fetch SIZE and MODEL per-device separately.
    local -a disks=()
    local -a disk_labels=()
    while IFS= read -r name; do
        local _is_root=false
        local _rd
        for _rd in "${root_disks[@]}"; do
            [[ "$name" == "$_rd" ]] && _is_root=true && break
        done
        [[ "$_is_root" == true ]] && continue
        local size model
        size=$(lsblk -d -n -o SIZE "/dev/${name}" 2>/dev/null | head -1 | xargs)
        model=$(lsblk -d -n -o MODEL "/dev/${name}" 2>/dev/null | head -1 | xargs)
        disks+=("$name")
        disk_labels+=("/dev/${name}  ${size}  ${model}")
    done < <(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk" {print $1}')

    if [[ ${#disks[@]} -eq 0 ]]; then
        warn "No external disks detected."
        warn "Connect the device and re-run:  sudo ./hf-tool.sh --init"
        return 1
    fi

    echo "Available external disks:"
    echo
    local i
    for (( i=0; i<${#disks[@]}; i++ )); do
        printf "  %d) %s\n" "$(( i+1 ))" "${disk_labels[$i]}"
    done
    echo

    local choice
    while true; do
        read -rp "Select disk number [1-${#disks[@]}] or '.' to cancel: " choice
        [[ "$choice" == "." ]] && { warn "Cancelled."; return 1; }
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#disks[@]} )); then
            break
        fi
        warn "Invalid selection. Enter a number between 1 and ${#disks[@]}."
    done

    local selected_disk="/dev/${disks[$(( choice-1 ))]}"
    local selected_label="${disk_labels[$(( choice-1 ))]}"

    echo
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn " VERIFY YOUR SELECTION BEFORE CONTINUING"
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    warn "  You selected : ${selected_label}"
    echo
    warn " Selecting the WRONG device will PERMANENTLY DESTROY"
    warn " all data on it — including other USB drives, external"
    warn " HDDs, or any disk not intended for backup use."
    warn ""
    warn " Make absolutely sure this is the correct external"
    warn " device before proceeding. This action CANNOT be undone."
    echo
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    read -rp "Is this the correct external backup device? [y/N] " _verify
    if [[ "${_verify,,}" != "y" ]]; then
        warn "Cancelled. Re-run and select the correct device."
        return 1
    fi
    echo
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn " ALL DATA ON ${selected_disk} WILL BE PERMANENTLY DESTROYED"
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    # Random 6-digit confirmation loop
    while true; do
        local confirm_code user_input
        confirm_code=$(( (RANDOM * 32768 + RANDOM) % 900000 + 100000 ))
        echo "To confirm the wipe, type this 6-digit code exactly, or '.' to cancel:"
        echo
        echo "    ${confirm_code}"
        echo
        read -rp "Code: " user_input
        [[ "$user_input" == "." ]] && { warn "Cancelled."; return 1; }
        if [[ "$user_input" == "$confirm_code" ]]; then
            break
        fi
        echo
        warn "Code mismatch — try again with the new code below."
        echo
    done

    echo
    log "Preparing ${selected_disk} — this may take a moment..."

    # Unmount any mounted partitions on this disk
    while IFS= read -r part; do
        [[ "$part" == "$(basename "$selected_disk")" ]] && continue
        umount "/dev/${part}" 2>/dev/null || true
    done < <(lsblk -ln -o NAME "$selected_disk" | tail -n +2)

    # Wipe existing signatures, create GPT table + single partition
    wipefs -a "$selected_disk" >/dev/null 2>&1
    fdisk "$selected_disk" >/dev/null 2>&1 <<'FDISK_CMDS'
g
n
1


w
FDISK_CMDS

    # Allow the kernel to re-read the new partition table and wait for udev
    partprobe "$selected_disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 2

    # Resolve partition name (sda->sda1, nvme0n1->nvme0n1p1, mmcblk0->mmcblk0p1)
    local part_dev
    if [[ "$selected_disk" =~ nvme|mmcblk ]]; then
        part_dev="${selected_disk}p1"
    else
        part_dev="${selected_disk}1"
    fi

    log "Formatting ${part_dev} as ext4 (label: ${facility_code})..."
    mkfs.ext4 -L "${facility_code}" "${part_dev}" >/dev/null 2>&1

    # Mount and persist
    local mount_point="/mnt/hf-backup-${facility_code}"
    mkdir -p "$mount_point"
    mount "$part_dev" "$mount_point"
    _write_status "EXTERNAL_STORAGE_PATH" "$mount_point"
    log "Device mounted at ${mount_point} and saved to .env."

    # Configure automount on insertion via udev + fstab.
    # x-systemd.automount only mounts on first access, not on plug-in — so we use
    # a udev rule that fires systemd-run to mount immediately when the device appears.
    # fstab entry (noauto) provides a stable target for the udev rule and for
    # manual/recovery use without blocking boot when the drive is absent.
    local part_uuid
    part_uuid=$(blkid -s UUID -o value "$part_dev" 2>/dev/null)
    if [[ -n "$part_uuid" ]]; then
        # fstab: noauto so boot does not stall; nofail as belt-and-suspenders
        sed -i "\|[[:space:]]${mount_point}[[:space:]]|d" /etc/fstab
        echo "UUID=${part_uuid}  ${mount_point}  ext4  defaults,noauto,nofail  0  2" >> /etc/fstab

        # udev rule: on block device add, match our UUID and mount via a transient
        # systemd unit (systemd-run --no-block avoids blocking the udev event queue)
        local udev_rule="/etc/udev/rules.d/99-hf-backup-${facility_code}.rules"
        cat > "$udev_rule" <<UDEV
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_UUID}=="${part_uuid}", ENV{ID_FS_TYPE}=="ext4", RUN+="/bin/systemd-run --no-block /bin/mount UUID=${part_uuid} ${mount_point}"
UDEV
        udevadm control --reload-rules
        log "Automount configured: drive will mount at ${mount_point} on insertion (UUID=${part_uuid})."
    else
        warn "Could not read UUID from ${part_dev} — automount not configured. Manual mount required after reboot."
    fi
    echo
}

_do_init() {
    need_root

    # ── Passphrase ────────────────────────────────────────────────────────────
    local current_passphrase
    current_passphrase=$(_read_ini_value "${BASE_DIR}/.env" "BORG_PASSPHRASE")
    if [[ -z "$current_passphrase" || "$current_passphrase" == "CHANGE_ME_TO_A_STRONG_PASSPHRASE" ]]; then
        warn "BORG_PASSPHRASE is not set. Please define a strong passphrase now."
        warn "Store it safely — without it, backups cannot be decrypted."
        echo
        local new_pass new_pass2
        while true; do
            read -srp "BORG_PASSPHRASE: " new_pass; echo
            read -srp "BORG_PASSPHRASE (confirm): " new_pass2; echo
            if [[ "$new_pass" != "$new_pass2" ]]; then
                warn "Passphrases do not match. Try again."
                continue
            fi
            if [[ ${#new_pass} -lt 8 ]]; then
                warn "Passphrase must be at least 8 characters."
                continue
            fi
            break
        done
        _write_status "BORG_PASSPHRASE" "$new_pass"
        log "BORG_PASSPHRASE saved to .env."
        echo
    fi

    local borg_mode dc_cmd
    borg_mode=$(_read_ini_value "${BASE_DIR}/.env" "BORG_MODE")
    borg_mode="${borg_mode:-central}"
    if docker compose version >/dev/null 2>&1; then
        dc_cmd="$(which docker) compose"
    elif command -v docker-compose >/dev/null; then
        dc_cmd="$(which docker-compose)"
    else
        die "Docker Compose not found."
    fi

    # ══════════════════════════════════════════════════════════════════════════
    # STAGE 1 — SSH keys  (central mode only)
    # Keys are normally created by the installer, but if missing (e.g. the
    # facility switched from local to central mode) generate them here and
    # guide the user through the share-and-wait flow before continuing.
    # ══════════════════════════════════════════════════════════════════════════
    if [[ "$borg_mode" != "local" ]]; then
        local _rsa="${BASE_DIR}/ssh/id_rsa"
        local _kek="${BASE_DIR}/ssh/id_kek"
        local _bundle="${BASE_DIR}/hf-${facility_code}-keys.tar.gz"

        if [[ ! -f "$_rsa" || ! -f "${_rsa}.pub" ]]; then
            log "Generating SSH backup key..."
            mkdir -p "${BASE_DIR}/ssh"
            ssh-keygen -t rsa -N "" -f "$_rsa" \
                -C "hf-backup@$(hostname -f 2>/dev/null || hostname)" >/dev/null
            chmod 600 "$_rsa"
        fi
        if [[ ! -f "$_kek" || ! -f "${_kek}.pub" ]]; then
            log "Generating SSH KEK key..."
            ssh-keygen -t rsa -N "" -f "$_kek" \
                -C "hf-backup-kek@$(hostname -f 2>/dev/null || hostname)" >/dev/null
            chmod 600 "$_kek"
        fi
        if [[ ! -f "$_bundle" ]]; then
            tar -czf "$_bundle" -C "${BASE_DIR}/ssh" id_rsa.pub id_kek.pub
            _write_status "_keys" "yes"
            # Keys are new — central repo has not been initialised yet.
            # Reset the borg_initialized flag in case this is a local→central switch.
            _write_status "_borg_initialized" "no"
            log "SSH public key bundle created: ${_bundle}"
            echo
            log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log " Share SSH Keys with the Central Backup Team"
            log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo
            log "  Key bundle: ${_bundle}"
            echo
            echo "While waiting, you can add your databases:"
            echo "  sudo ./hf-tool.sh --db-add"
            echo "  sudo ./hf-tool.sh --db-list"
            echo "  sudo ./hf-tool.sh --db-remove <name>"
            echo
            warn "Once the central admin confirms the account is ready, re-run:"
            warn "  sudo ./hf-tool.sh --init"
            return 0
        fi
    fi
    if [[ "$borg_mode" == "local" ]]; then
        log "Mode: local (external storage device)"
        echo
        local ext_path
        ext_path=$(_read_ini_value "${BASE_DIR}/.env" "EXTERNAL_STORAGE_PATH")
        if [[ -z "$ext_path" ]]; then
            _select_and_prepare_external_disk || return 1
            ext_path=$(_read_ini_value "${BASE_DIR}/.env" "EXTERNAL_STORAGE_PATH")
        fi
        _validate_external_storage "$ext_path"
        local cfg="${BASE_DIR}/config/borgmatic.d/config.yaml"
        sed -i "s|path: \"ssh://.*\"|path: \"/mnt/external/repo\"|" "$cfg"
        sed -i "s|label: central|label: local|" "$cfg"
        log "Borgmatic config updated to use local repo."
        if ! grep -q "/mnt/external" "${BASE_DIR}/compose.yml"; then
            sed -i "s|# host data mounts|# external storage device (local mode)\n      - ${ext_path}:/mnt/external\n\n      # host data mounts|" "${BASE_DIR}/compose.yml"
            log "External storage volume added to compose.yml."
        fi
        _write_status "BORG_REPO" "/mnt/external/repo"
        _write_status "ENABLE_MONIT" "false"
        _write_status "_monitoring" "disabled"
        log "Monitoring disabled (not applicable in local mode)."
    else
        local enable_monit
        enable_monit=$(_read_ini_value "${BASE_DIR}/.env" "ENABLE_MONIT")
        enable_monit="${enable_monit:-true}"

        if [[ "$enable_monit" == "true" ]]; then
            _write_status "_monitoring" "enabled"
            if ! _is_init_complete; then
                echo
                log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log " STEP 1 — TLS Certificate Exchange"
                log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo
                read -rp "Has the central admin confirmed the facility account is ready on the server? [y/N] " _ans
                if [[ "${_ans,,}" != "y" ]]; then
                    echo
                    warn "Wait for the admin confirmation, then re-run:  sudo ./hf-tool.sh --init"
                    return 0
                fi
                echo
                _do_gen_monitoring_cert "skip_prereqs" || true
                if ! _is_init_complete; then
                    echo
                    warn "Signed certificate not yet available."
                    warn "Re-run once the admin has signed the CSR:  sudo ./hf-tool.sh --init"
                    return 0
                fi
            fi
        else
            _write_status "_monitoring" "disabled"
        fi
    fi

    # ══════════════════════════════════════════════════════════════════════════
    # STAGE 2 — Borg repository initialisation + systemd
    # ══════════════════════════════════════════════════════════════════════════
    if [[ "$(_read_status '_borg_initialized')" != "yes" ]]; then
        echo
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log " STEP 2 — Initialising Borg Repository"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        $dc_cmd -f "${BASE_DIR}/compose.yml" run --rm "hf-backup-${facility_code}" init
        _write_status "_borg_initialized" "yes"
        log "Installing systemd service and timer..."
        _do_install_systemd
        echo
        log "Configure backup schedule:"
        _do_schedule
        _write_status "_status" "complete"
        rm -f "${BASE_DIR}/hf-${facility_code}-keys.tar.gz"
        _do_backup_config
    fi

    # ── Done ──────────────────────────────────────────────────────────────────
    echo
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log " Setup complete!"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "  Optionally add databases to backup:"
    echo "    sudo ./hf-tool.sh --db-add"
    echo "    sudo ./hf-tool.sh --db-list"
    echo "    sudo ./hf-tool.sh --db-remove <name>"
    echo
    echo "  Run first backup to verify everything:"
    echo "    sudo ./hf-tool.sh --backup-now"
    echo
}

ensure_image_available() {
  local image="$1"

  have_cmd docker || die "docker not found; cannot verify image ${image}"

  if docker image inspect "${image}" >/dev/null 2>&1; then
    log "Image '${image}' already present."
    return 0
  fi

  while true; do
    echo "Image '${image}' not found locally."
    read -rp "Pull from registry (p), load from file (l), or skip for now (.)? [p/l/.] " choice
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
        read -rp "Path to image tarball (enter '.' to go back): " fpath
        if [[ "${fpath}" == "." ]]; then
          break
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
    elif [[ "${choice}" == "." ]]; then
      warn "Skipping image check. Ensure '${image}' is available before running backups."
      return 0
    else
      echo "Please enter 'p' (pull), 'l' (load), or '.' (skip)."
    fi
  done
}

_do_load_image(){
    local image
    image=$(grep image "${BASE_DIR}/compose.yml" | sed 's/.*image://;s/ //g')
    [[ -z "$image" ]] && die "Could not determine image name from compose.yml"
    ensure_image_available "${image}"
}

_do_db_add(){
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        read -rp "Config name (used as dump filename prefix): " name
    fi
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid name '${name}': use letters, numbers, _ or -"

    local conf="${BASE_DIR}/runtime/dbconf/.${name}.conf"
    if [[ -f "$conf" ]]; then
        warn "Config already exists: ${conf}"
        read -rp "Overwrite? [y/N] " ans
        [[ "${ans,,}" == "y" ]] || return 0
    fi

    local db_type
    while true; do
        read -rp "DB type [M=MySQL/MariaDB, P=PostgreSQL]: " db_type
        db_type="${db_type^^}"
        [[ "$db_type" == "M" || "$db_type" == "P" ]] && break
        echo "Please enter M or P."
    done

    local default_port
    [[ "$db_type" == "M" ]] && default_port=3306 || default_port=5432

    read -rp "Host [localhost]: " host;     host="${host:-localhost}"
    read -rp "Port [${default_port}]: " port; port="${port:-${default_port}}"
    read -rp "Database: " database
    read -rp "User: " user

    local password
    while true; do
        read -srp "Password: " password; echo
        read -srp "Password (confirm): " password2; echo
        [[ "$password" == "$password2" ]] && break
        warn "Passwords do not match. Try again."
    done

    read -rp "Enable backup? [Y/n]: " ans
    local backup=true
    [[ "${ans,,}" == "n" ]] && backup=false

    mkdir -p "${BASE_DIR}/runtime/dbconf"
    cat > "$conf" <<CONFEOF
DB_TYPE=${db_type}
BACKUP=${backup}
HOST=${host}
PORT=${port}
DATABASE=${database}
USER=${user}
PASSWORD=${password}
CONFEOF
    chmod 600 "$conf"
    log "Created DB config: ${conf}"
}

_do_db_list(){
    local dir="${BASE_DIR}/runtime/dbconf"
    local found=false
    for conf in "${dir}"/.*.conf; do
        [[ -f "$conf" ]] || continue
        found=true
        local name
        name=$(basename "$conf"); name="${name#.}"; name="${name%.conf}"
        local db_type backup host database
        db_type=$(_read_ini_value "$conf" "DB_TYPE")
        backup=$(_read_ini_value "$conf" "BACKUP")
        host=$(_read_ini_value "$conf" "HOST")
        database=$(_read_ini_value "$conf" "DATABASE")
        echo "  ${name}: type=${db_type} backup=${backup} host=${host} db=${database}"
    done
    $found || echo "No DB configurations found in ${dir}"
}

_do_db_remove(){
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        read -rp "Config name to remove: " name
    fi
    local conf="${BASE_DIR}/runtime/dbconf/.${name}.conf"
    [[ -f "$conf" ]] || die "Config not found: ${conf}"
    read -rp "Remove '${name}'? [y/N] " ans
    if [[ "${ans,,}" == "y" ]]; then
        rm -f "$conf"
        log "Removed: ${conf}"
    else
        log "Aborted."
    fi
}

_do_list_vars(){
    if [[ ! -f ".env" ]]; then
        die ".env not found"
    fi
    grep -E "^[A-Z][A-Za-z0-9_]*=" ".env" || true
    echo
    echo "# Dynamic parameters do not modify below (unless you know what you are doing)"
    grep -E "^_[A-Za-z0-9_]*=" ".env" || echo "# (none)"
}

_do_set_var(){
    local key="${1:-}"
    [[ -z "$key" ]] && die "Usage: $0 --set <VARIABLE>"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid variable name: ${key}"
    [[ "$key" =~ ^_ ]] && die "'${key}' is an internal variable and cannot be set directly."
    [[ "${key^^}" == "SCHEDULE" ]] && die "Use --schedule to change the backup schedule."
    if [[ ! -f ".env" ]]; then
        die ".env not found"
    fi

    local value=""
    if [[ "${key^^}" =~ PASSWORD|PASSPHRASE ]]; then
        while true; do
            read -srp "${key}: " value
            echo
            read -srp "${key} (confirm): " value2
            echo
            if [[ "$value" == "$value2" ]]; then
                break
            fi
            warn "Values do not match. Try again."
        done
    else
        read -rp "${key}: " value
    fi

    _write_status "$key" "$value"
    log "Set ${key}:"
    grep "^${key}=" .env
}

_do_backup_config(){
    local files_to_backup=()

    [[ -f "${BASE_DIR}/.env" ]]        && files_to_backup+=(.env)
    [[ -f "${BASE_DIR}/compose.yml" ]] && files_to_backup+=(compose.yml)
    [[ -d "${BASE_DIR}/config" ]]      && files_to_backup+=(config)
    [[ -d "${BASE_DIR}/ssh" ]]         && files_to_backup+=(ssh)

    if [[ ${#files_to_backup[@]} -eq 0 ]]; then
        die "No configuration files found in ${BASE_DIR}. Is the installation complete?"
    fi

    # Build a dated, sequenced filename: hf-<facility>-config-YYYYMMDD-001.tar.gz
    local date_str seqno out
    date_str=$(date +%Y%m%d)
    seqno=1
    while true; do
        out="${BASE_DIR}/hf-${facility_code}-config-${date_str}-$(printf '%03d' "$seqno").tar.gz"
        [[ ! -f "$out" ]] && break
        (( seqno++ ))
        (( seqno > 999 )) && die "Sequence number overflow — too many config backups for today."
    done

    log "Creating configuration backup archive..."
    tar -czf "$out" -C "${BASE_DIR}" "${files_to_backup[@]}"
    chmod 600 "$out"

    echo
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn "                     ! ! !   I M P O R T A N T   ! ! !                       "
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    warn "  File: ${out}"
    echo
    warn " !! ACTION REQUIRED !!"
    warn ""
    warn " Copy this file to a SECURE OFF-SITE location NOW."
    warn " It contains:"
    warn "   - BORG_PASSPHRASE  (without it, backups cannot be decrypted)"
    warn "   - SSH private keys (without them, you cannot connect to the repo)"
    warn ""
    warn " Without this file you CANNOT restore backups after a total system loss."
    echo
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
}

_do_set_mode() {
    need_root
    local target_mode="${1:-}"
    [[ "$target_mode" == "central" || "$target_mode" == "local" ]] \
        || die "Usage: ./hf-tool.sh --set-mode <central|local>"

    local current_mode
    current_mode=$(_read_ini_value "${BASE_DIR}/.env" "BORG_MODE")
    current_mode="${current_mode:-central}"

    if [[ "$current_mode" == "$target_mode" ]]; then
        log "Already in ${target_mode} mode — nothing to do."
        return 0
    fi

    local cfg="${BASE_DIR}/config/borgmatic.d/config.yaml"

    # ── Switch TO central ─────────────────────────────────────────────────────
    if [[ "$target_mode" == "central" ]]; then
        log "Switching to central mode..."

        local central_host central_port
        central_host=$(_read_ini_value "${BASE_DIR}/.env" "CENTRAL_HOST")
        central_port=$(_read_ini_value "${BASE_DIR}/.env" "CENTRAL_PORT")
        central_host="${central_host:-hf-backup.csaude.org.mz}"
        central_port="${central_port:-22}"
        local central_repo="ssh://${facility_code}@${central_host}:${central_port}/./repo"

        # Update borgmatic config
        sed -i "s|path: \"/mnt/external/repo\"|path: \"${central_repo}\"|" "$cfg"
        sed -i "s|label: local|label: central|" "$cfg"
        log "Borgmatic config updated to central repo: ${central_repo}"

        # Remove the external storage volume from compose.yml
        sed -i "/# external storage device (local mode)/d" "${BASE_DIR}/compose.yml"
        sed -i "/\/mnt\/external/d" "${BASE_DIR}/compose.yml"
        log "External storage volume removed from compose.yml."

        # Remove the fstab automount entry for the external drive (if any)
        local ext_path
        ext_path=$(_read_ini_value "${BASE_DIR}/.env" "EXTERNAL_STORAGE_PATH")
        if [[ -n "$ext_path" ]]; then
            sed -i "\|[[:space:]]${ext_path}[[:space:]]|d" /etc/fstab
            rm -f "/etc/udev/rules.d/99-hf-backup-${facility_code}.rules"
            udevadm control --reload-rules
            umount "$ext_path" 2>/dev/null || true
            log "Automount entry and udev rule removed; external drive unmounted."
        fi

        # Update .env
        _write_status "BORG_MODE" "central"
        _write_status "BORG_REPO" "$central_repo"
        _write_status "ENABLE_MONIT" "true"
        _write_status "_monitoring" "enabled"
        _write_status "_borg_initialized" "no"
        _write_status "EXTERNAL_STORAGE_PATH" ""

        echo
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log " Mode changed to: central"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        log "Proceed with initialisation:"
        echo "       sudo ./hf-tool.sh --init"
        echo
        return 0
    fi

    # ── Switch TO local ───────────────────────────────────────────────────────
    if [[ "$target_mode" == "local" ]]; then
        log "Switching to local mode..."

        # Update .env before calling disk setup so _do_init picks up the new mode
        _write_status "BORG_MODE" "local"
        _write_status "ENABLE_MONIT" "false"
        _write_status "_monitoring" "disabled"
        _write_status "_borg_initialized" "no"
        # Clear stale central path; disk setup will write the real one
        _write_status "EXTERNAL_STORAGE_PATH" ""

        # Remove any existing /mnt/external entry to allow a clean re-add
        sed -i "/# external storage device (local mode)/d" "${BASE_DIR}/compose.yml"
        sed -i "/\/mnt\/external/d" "${BASE_DIR}/compose.yml"

        # Disk selection, partitioning, formatting, and mounting
        _select_and_prepare_external_disk || return 1
        local ext_path
        ext_path=$(_read_ini_value "${BASE_DIR}/.env" "EXTERNAL_STORAGE_PATH")

        # Update borgmatic config
        sed -i "s|path: \"ssh://.*\"|path: \"/mnt/external/repo\"|" "$cfg"
        sed -i "s|label: central|label: local|" "$cfg"
        log "Borgmatic config updated to local repo."

        # Add the external storage volume to compose.yml
        if ! grep -q "/mnt/external" "${BASE_DIR}/compose.yml"; then
            sed -i "s|# host data mounts|# external storage device (local mode)\n      - ${ext_path}:/mnt/external\n\n      # host data mounts|" "${BASE_DIR}/compose.yml"
            log "External storage volume added to compose.yml."
        fi

        _write_status "BORG_REPO" "/mnt/external/repo"

        # Initialise the borg repository on the external disk
        local dc_cmd
        if docker compose version >/dev/null 2>&1; then
            dc_cmd="$(which docker) compose"
        elif command -v docker-compose >/dev/null; then
            dc_cmd="$(which docker-compose)"
        else
            die "Docker Compose not found."
        fi

        echo
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log " Initialising Borg Repository on external storage"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        $dc_cmd -f "${BASE_DIR}/compose.yml" run --rm "hf-backup-${facility_code}" init
        _write_status "_borg_initialized" "yes"
        _write_status "_status" "complete"

        log "Installing systemd service and timer..."
        _do_install_systemd
        echo
        log "Configure backup schedule:"
        _do_schedule
        _do_backup_config

        echo
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log " Mode changed to: local — setup complete!"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        echo "  Run first backup to verify everything:"
        echo "    sudo ./hf-tool.sh --backup-now"
        echo
        return 0
    fi
}

_usage(){
    cat <<'EOH' >&2
Usage: ./hf-tool.sh [COMMAND]

Commands:
  --help              show this help message
  --shell             open a shell in the HF backup container (restore files)
  --init              initialize borg repo on central server (handles cert exchange automatically; requires sudo)
  --set-mode MODE     switch backup mode: 'central' or 'local' (requires sudo)
  --schedule          interactively edit the systemd timer schedule (requires sudo)
  --backup-now        run an immediate backup using the container (requires completed init)
  --backup-config     create hf-<facility>-config.tar.gz with all files needed for disaster recovery
  --init-status       show internal state flags from .env
  --load-image        pull, load from file, or skip the backup Docker image
  --db-add [name]     add a database backup configuration
  --db-list           list configured databases
  --db-remove [name]  remove a database backup configuration
  --list-vars         list all variables and their values from .env
  --set VAR           prompt for and set a variable in .env (masked input for sensitive vars)


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
if [[ "$(pwd)" == *" "* ]]; then
    die "The working directory path contains spaces: $(pwd)\nRename the directory (or any parent) so that no path component has a space."
fi
: ".env"

case "$1" in
    --help|-h)     _usage ;;
    --shell)       _do_shell ;;
    --schedule)    _do_schedule ;;
    --backup-now)  _do_backup_now ;;
    --gen-cert)    _do_gen_monitoring_cert ;;
    --init)        _do_init ;;
    --set-mode)    _do_set_mode "${2:-}" ;;
    --backup-config) _do_backup_config ;;
    --init-status) echo "# Dynamic parameters do not modify below (unless you know what you are doing)" && grep "^_" "${BASE_DIR}/.env" 2>/dev/null || echo "No status file found." ;;
    --load-image)  _do_load_image ;;
    --db-add)      _do_db_add "${2:-}" ;;
    --db-list)     _do_db_list ;;
    --db-remove)   _do_db_remove "${2:-}" ;;
    --list-vars)   _do_list_vars ;;
    --set)         _do_set_var "${2:-}" ;;
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
LOG_FILE="/app/logs/"`date +'%Y%m%d'`-"${FACILITY_CODE}-backup.log"
# Identify this HF / instance
INSTANCE="${BORG_HOSTNAME:-$(hostname -s)}"

# Where to push (behind NGINX with mTLS)
PUSH_URL="${PUSHGATEWAY_URL:-https://push.csaude.org.mz}"

# mTLS client credentials (issued by your Private CA)
CLIENT_CERT="${PUSHGW_CLIENT_CERT:-/root/.ssh/pushgw-client.crt}"
CLIENT_KEY="${PUSHGW_CLIENT_KEY:-/root/.ssh/pushgw-client.key}"
CA_CERT="${PUSHGW_CA_CERT:-/root/.ssh/tls/csaude-ca.crt}"

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

# Always update local backup status DB (visible via local web server)
python3 /app/web-server/update_db.py "${PHASE}" "${STATE}" "${NOW}" 2>/dev/null || true

find ./logs/*.log -type f -mtime +$((LOCAL_DUMP_RETENTION_DAYS * 2)) -delete

EOF
  chmod +x "$f"
}

write_web_server_files() {
  local dir="${BASE_DIR}/runtime/web-server"
  mkdir -p "$dir"

  # ── update_db.py — called by pushgw_event.sh after every borgmatic hook ─────
  cat > "${dir}/update_db.py" <<'PYEOF'
#!/usr/bin/env python3
"""Record borgmatic hook events into a local SQLite DB for the status web UI."""
import os, sys, sqlite3
from datetime import datetime, timedelta

DB_PATH = os.environ.get("STATUS_DB_PATH", "/app/web-server/backup_status.db")
RETENTION_DAYS = 60


def open_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS backup_events (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            task             TEXT    NOT NULL,
            status           TEXT    NOT NULL,
            start_time       TEXT,
            end_time         TEXT,
            duration_seconds INTEGER,
            recorded_at      TEXT    DEFAULT (strftime('%Y-%m-%d %H:%M:%S', 'now'))
        )
    """)
    conn.commit()
    return conn


def purge_old(conn):
    cutoff = (datetime.utcnow() - timedelta(days=RETENTION_DAYS)).strftime("%Y-%m-%d %H:%M:%S")
    conn.execute("DELETE FROM backup_events WHERE recorded_at < ?", (cutoff,))
    conn.commit()


def record(phase, state, now_ts):
    conn = open_db()
    purge_old(conn)
    now_str = datetime.utcfromtimestamp(int(now_ts)).strftime("%Y-%m-%d %H:%M:%S")

    if state == "starting":
        conn.execute(
            "INSERT INTO backup_events (task, status, start_time) VALUES (?, ?, ?)",
            (phase, state, now_str),
        )
    else:
        row = conn.execute(
            "SELECT id, start_time FROM backup_events "
            "WHERE task = ? AND status = 'starting' ORDER BY id DESC LIMIT 1",
            (phase,),
        ).fetchone()
        if row:
            row_id, start_str = row
            try:
                start_dt = datetime.strptime(start_str, "%Y-%m-%d %H:%M:%S")
                end_dt   = datetime.utcfromtimestamp(int(now_ts))
                duration = int((end_dt - start_dt).total_seconds())
            except Exception:
                duration = None
            conn.execute(
                "UPDATE backup_events SET status=?, end_time=?, duration_seconds=? WHERE id=?",
                (state, now_str, duration, row_id),
            )
        else:
            conn.execute(
                "INSERT INTO backup_events (task, status, end_time) VALUES (?, ?, ?)",
                (phase, state, now_str),
            )

    conn.commit()
    conn.close()


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: update_db.py <phase> <state> <unix_timestamp>", file=sys.stderr)
        sys.exit(1)
    record(sys.argv[1], sys.argv[2], sys.argv[3])
PYEOF

  # ── server.py — simple HTTP status page, always running in hf-web container ─
  cat > "${dir}/server.py" <<'PYEOF'
#!/usr/bin/env python3
"""Enhanced HTTP server — backup status, drive check, log viewer, trigger."""
import json, os, re, sqlite3, subprocess
from datetime import datetime, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

DB_PATH         = os.environ.get("STATUS_DB_PATH", "/app/web-server/backup_status.db")
PORT            = int(os.environ.get("WEB_PORT", "22587"))
FACILITY        = os.environ.get("FACILITY_CODE", os.environ.get("HOSTNAME", "unknown"))
BORG_MODE       = os.environ.get("BORG_MODE", "central")
RETENTION       = 60   # days
SENTINEL        = os.path.join(os.environ.get("WEB_SERVER_DIR", "/app/web-server"), "trigger_backup")
LOG_DIR         = os.environ.get("LOG_DIR", "/app/logs")
STALE_HOURS     = 4    # backup_running staleness threshold
STALE_SENTINEL_MINS = 10  # sentinel auto-cleanup threshold


def _open_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS backup_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task TEXT NOT NULL, status TEXT NOT NULL,
            start_time TEXT, end_time TEXT,
            duration_seconds INTEGER,
            recorded_at TEXT DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
        )
    """)
    conn.commit()
    return conn


def _purge_old():
    if not os.path.exists(DB_PATH):
        return
    try:
        cutoff = (datetime.utcnow() - timedelta(days=RETENTION)).strftime("%Y-%m-%d %H:%M:%S")
        conn = _open_db()
        conn.execute("DELETE FROM backup_events WHERE recorded_at < ?", (cutoff,))
        conn.commit()
        conn.close()
    except Exception:
        pass


def _get_events():
    if not os.path.exists(DB_PATH):
        return []
    try:
        conn = _open_db()
        rows = conn.execute(
            "SELECT task, status, start_time, end_time, duration_seconds "
            "FROM backup_events ORDER BY id DESC LIMIT 200"
        ).fetchall()
        conn.close()
        return rows
    except Exception:
        return []


def _check_drive_status():
    """Returns (drive_mounted, repo_ok) for local mode; (None, None) for central."""
    if BORG_MODE != "local":
        return None, None
    drive = os.path.ismount("/mnt/external")
    if not drive:
        return False, None
    try:
        r = subprocess.run(
            ["borg", "info", "/mnt/external/repo"],
            capture_output=True, timeout=10, env=os.environ,
        )
        return True, r.returncode == 0
    except Exception:
        return True, False


def _get_status():
    """Build the /api/status JSON dict. Always live — no caching."""
    drive_mounted, repo_ok = _check_drive_status()

    # Stale sentinel cleanup
    backup_pending = False
    if os.path.exists(SENTINEL):
        age_mins = (datetime.utcnow() - datetime.utcfromtimestamp(
            os.path.getmtime(SENTINEL))).total_seconds() / 60
        if age_mins > STALE_SENTINEL_MINS:
            try:
                os.remove(SENTINEL)
            except OSError:
                pass
        else:
            backup_pending = True

    # backup_running: any unfinished row within last STALE_HOURS hours
    backup_running = False
    if os.path.exists(DB_PATH):
        try:
            cutoff = (datetime.utcnow() - timedelta(hours=STALE_HOURS)).strftime("%Y-%m-%d %H:%M:%S")
            conn = _open_db()
            row = conn.execute(
                "SELECT id FROM backup_events "
                "WHERE status='starting' AND end_time IS NULL AND start_time > ? LIMIT 1",
                (cutoff,),
            ).fetchone()
            conn.close()
            backup_running = row is not None
        except Exception:
            pass

    return {
        "facility": FACILITY,
        "borg_mode": BORG_MODE,
        "drive_mounted": drive_mounted,
        "repo_ok": repo_ok,
        "backup_running": backup_running,
        "backup_pending": backup_pending,
    }


def _serve_log(date_str):
    """Returns (http_status, content_type, body) for a log file request."""
    if not re.fullmatch(r"\d{8}", date_str):
        return 400, "text/plain", "Invalid date parameter — must be YYYYMMDD\n"
    log_path = os.path.join(LOG_DIR, f"{date_str}-{FACILITY}-backup.log")
    if not os.path.exists(log_path):
        return 404, "text/plain", f"Log not found: {date_str}-{FACILITY}-backup.log\n"
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        return 200, "text/plain; charset=utf-8", f.read()


def _handle_trigger():
    """Returns (http_status, body). Writes sentinel or 409 if already exists."""
    if os.path.exists(SENTINEL):
        return 409, "Backup already pending\n"
    try:
        os.makedirs(os.path.dirname(SENTINEL), exist_ok=True)
        with open(SENTINEL, "w") as f:
            f.write(datetime.utcnow().isoformat())
        return 200, "OK\n"
    except OSError as e:
        return 500, f"Error: {e}\n"


def _fmt_dur(secs):
    if secs is None:
        return "&mdash;"
    secs = int(secs)
    return f"{secs // 60}m {secs % 60}s" if secs >= 60 else f"{secs}s"


_STATUS_COLOR = {"completed": "#4CAF50", "failed": "#e74c3c", "starting": "#5dade2"}
_STATUS_ICON  = {"completed": "&#10003;", "failed": "&#10007;", "starting": "&#8635;"}


def _render(status, events):
    borg_mode       = status["borg_mode"]
    drive_mounted   = status["drive_mounted"]
    repo_ok         = status["repo_ok"]
    backup_running  = status["backup_running"]
    backup_pending  = status["backup_pending"]

    now_utc = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")

    # ── Drive/repo badges (local mode only) ──
    if borg_mode == "local":
        if drive_mounted:
            drive_badge = "<span class='badge ok' id='badge-drive'>&#128190; Drive: <span class='i' data-pt='Pronto' data-en='Ready'>Pronto</span></span>"
        else:
            drive_badge = "<span class='badge err' id='badge-drive'>&#128190; Drive: <span class='i' data-pt='Ausente' data-en='Missing'>Ausente</span></span>"
        if repo_ok:
            repo_badge = "<span class='badge ok' id='badge-repo'>&#128274; Repo: OK</span>"
        elif drive_mounted:
            repo_badge = "<span class='badge warn' id='badge-repo'>&#128274; Repo: <span class='i' data-pt='Erro' data-en='Error'>Erro</span></span>"
        else:
            repo_badge = "<span class='badge warn' id='badge-repo'>&#128274; Repo: &mdash;</span>"
        drive_section = f"{drive_badge} {repo_badge} <div class='divider'></div>"
    else:
        drive_section = ""  # central mode — no drive badges

    # ── Running badge ──
    if backup_running or backup_pending:
        running_badge = "<span class='badge info' id='badge-running'>&#8635; <span class='i' data-pt='Backup em curso&hellip;' data-en='Backup running&hellip;'>Backup em curso&hellip;</span></span>"
    else:
        running_badge = "<span class='badge info' id='badge-running'>&#9679; <span class='i' data-pt='Sem backup em curso' data-en='No backup running'>Sem backup em curso</span></span>"

    # ── Backup Now button enabled state ──
    can_backup = (not backup_running) and (not backup_pending)
    if borg_mode == "local":
        can_backup = can_backup and bool(drive_mounted) and bool(repo_ok)
    btn_backup_disabled = "" if can_backup else "disabled"

    # ── Mode badge ──
    if borg_mode == "local":
        mode_badge = "<span class='badge warn'>&#128190; Local</span>"
    else:
        mode_badge = "<span class='badge info'>&#127760; Central</span>"

    # ── Table rows ──
    rows_html = ""
    for task, st, start_time, end_time, dur_secs in events:
        color = _STATUS_COLOR.get(st, "#888")
        icon  = _STATUS_ICON.get(st, "?")
        date_key = (start_time or "")[:10].replace("-", "")  # "2026-03-24" → "20260324"
        log_btn = (
            f"<button class='btn-row-log' onclick=\"showLog('{date_key}')\">"
            f"&#128196; <span class='i' data-pt='Ver Log' data-en='View Log'>Ver Log</span></button>"
        ) if date_key and task == "backup" else "&mdash;"
        rows_html += (
            f"<tr>"
            f"<td>{task}</td>"
            f"<td style='color:{color};font-weight:bold'>{icon} {st}</td>"
            f"<td>{start_time or '&mdash;'}</td>"
            f"<td>{end_time or '&mdash;'}</td>"
            f"<td>{_fmt_dur(dur_secs)}</td>"
            f"<td>{log_btn}</td>"
            f"</tr>\n"
        )
    if not rows_html:
        rows_html = "<tr><td colspan='6' style='text-align:center;color:#555'><span class='i' data-pt='Sem eventos registados.' data-en='No events recorded yet.'>Sem eventos registados.</span></td></tr>"

    return f"""<!DOCTYPE html>
<html lang="pt">
<head>
  <meta charset="utf-8">
  <title>Backup &mdash; {FACILITY}</title>
  <style>
    *{{box-sizing:border-box;margin:0;padding:0}}
    html,body{{height:100%}}
    body{{font-family:monospace;font-size:14px;background:#0f0f1a;color:#e0e0e0;padding:24px;display:flex;flex-direction:column;overflow:hidden}}
    h1{{color:#4CAF50;font-size:1.3rem;margin-bottom:2px}}
    .sub{{color:#666;font-size:.82em;margin-bottom:14px}}
    .bar{{background:#161626;border:1px solid #2a2a44;border-radius:6px;padding:10px 14px;margin-bottom:16px}}
    .bar-row{{display:flex;align-items:center;gap:10px;flex-wrap:wrap}}
    .bar-row+.bar-row{{margin-top:8px;padding-top:8px;border-top:1px solid #1e1e30}}
    .spacer{{flex:1}}
    .badge{{display:inline-flex;align-items:center;gap:5px;padding:4px 11px;border-radius:4px;font-size:.78em;font-weight:bold;white-space:nowrap}}
    .badge.ok{{background:#1a3d28;color:#4CAF50;border:1px solid #2d6a40}}
    .badge.warn{{background:#3d2a1a;color:#e67e22;border:1px solid #6a4020}}
    .badge.info{{background:#1a2a3d;color:#5dade2;border:1px solid #1f4068}}
    .badge.err{{background:#3d1a1a;color:#e74c3c;border:1px solid #6a2020}}
    .divider{{width:1px;height:24px;background:#2a2a44;flex-shrink:0}}
    .btn{{padding:5px 14px;border-radius:4px;font-size:.8em;font-family:monospace;cursor:pointer;border:none;font-weight:bold;white-space:nowrap}}
    .btn-backup{{background:#922b21;color:#fff}}
    .btn-backup:hover{{background:#c0392b}}
    .btn-backup:disabled{{background:#3a2020;color:#555;cursor:not-allowed}}
    .btn-confirm-yes{{background:#1a3d28;color:#4CAF50;border:1px solid #2d6a40}}
    .btn-confirm-yes:hover{{background:#1f4d30}}
    .btn-confirm-no{{background:#3d1a1a;color:#e74c3c;border:1px solid #6a2020}}
    .btn-confirm-no:hover{{background:#4d2020}}
    .btn-recheck{{background:#1e1e3a;color:#7ecfff;border:1px solid #2a3a5a}}
    .btn-recheck:hover{{background:#252545}}
    .btn-lang{{background:#1e1e3a;color:#7ecfff;border:1px solid #2a3a5a;min-width:44px;text-align:center}}
    .btn-lang:hover{{background:#252545}}
    .refresh-wrap{{font-size:.78em;color:#666;display:flex;align-items:center;gap:6px;white-space:nowrap}}
    .refresh-wrap select{{background:#1a1a2e;color:#aaa;border:1px solid #333;padding:3px 6px;font-size:.9em;font-family:monospace;border-radius:3px}}
    .meta-info{{font-size:.75em;color:#555;display:flex;align-items:center;gap:16px;flex-wrap:wrap}}
    .meta-info strong{{color:#666}}
    #tbl{{flex:1;overflow-y:auto;min-height:0}}
    #log-sec{{flex:1;min-height:0}}
    table{{width:100%;border-collapse:collapse;font-size:.85em}}
    th{{background:#1e1e3a;padding:8px 14px;text-align:left;border-bottom:2px solid #2a2a4a;color:#888;font-weight:normal;position:sticky;top:0;z-index:1}}
    td{{padding:8px 14px;border-bottom:1px solid #1e1e2e;vertical-align:middle}}
    tr:hover td{{background:#16162a}}
    .btn-row-log{{background:none;border:1px solid #2a2a44;color:#666;font-family:monospace;font-size:.75em;padding:2px 8px;border-radius:3px;cursor:pointer}}
    .btn-row-log:hover{{border-color:#5dade2;color:#5dade2}}
    .log-panel{{background:#0a0a18;border:1px solid #2a2a4a;border-radius:6px;padding:14px;font-size:.82em;line-height:1.8;height:100%;display:flex;flex-direction:column;box-sizing:border-box}}
    #log-body{{overflow-y:auto;flex:1}}
    .log-hdr{{color:#5dade2;margin-bottom:10px;padding-bottom:6px;border-bottom:1px solid #1e1e3a;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:6px}}
    .log-back{{color:#888;cursor:pointer;font-size:.9em}}
    .log-back:hover{{color:#ccc}}
    .ll-ok{{color:#4CAF50}}.ll-warn{{color:#e67e22}}.ll-info{{color:#666}}
    .spin{{display:inline-block;animation:spin 1s linear infinite}}
    @keyframes spin{{to{{transform:rotate(360deg)}}}}
  </style>
</head>
<body>
  <h1>&#128202; <span class="i" data-pt="Estado do Backup" data-en="Backup Status">Estado do Backup</span></h1>
  <p class="sub"><span class="i" data-pt="Unidade Sanit&#225;ria" data-en="Health Facility">Unidade Sanit&#225;ria</span>: <strong style="text-transform:uppercase">{FACILITY}</strong></p>

  <div class="bar">
    <div class="bar-row">
      {drive_section}
      {running_badge}
      <div class="divider"></div>
      <button class="btn btn-backup" id="btn-backup" {btn_backup_disabled} onclick="askBackup()">
        &#9654; <span class="i" data-pt="Backup Agora" data-en="Backup Now">Backup Agora</span>
      </button>
      <span id="backup-confirm" style="display:none;align-items:center;gap:6px">
        <span style="font-size:.82em;color:#aaa"><span class="i" data-pt="Confirmar?" data-en="Confirm?">Confirmar?</span></span>
        <button class="btn btn-confirm-yes" onclick="triggerBackup()">&#10003; <span class="i" data-pt="Sim" data-en="Yes">Sim</span></button>
        <button class="btn btn-confirm-no" onclick="cancelBackup()">&#10007; <span class="i" data-pt="N&#227;o" data-en="No">N&#227;o</span></button>
      </span>
      <button class="btn btn-recheck" id="btn-recheck" onclick="doRecheck()">
        &#8635; <span class="i" data-pt="Re-verificar" data-en="Re-check">Re-verificar</span>
      </button>
      <div class="spacer"></div>
      <button class="btn btn-lang" id="btn-lang" onclick="toggleLang()">PT</button>
      <div class="divider"></div>
      <div class="refresh-wrap">
        <span class="i" data-pt="Auto-refresh" data-en="Auto-refresh">Auto-refresh</span>:
        <select id="refresh-sel" onchange="setRefresh(this.value)">
          <option value="0" class="i" data-pt="Nunca" data-en="Never">Nunca</option>
          <option value="5">5s</option>
          <option value="10">10s</option>
          <option value="15">15s</option>
          <option value="30" selected>30s</option>
          <option value="60">60s</option>
        </select>
      </div>
    </div>
    <div class="bar-row">
      {mode_badge}
      <div class="spacer"></div>
      <div class="meta-info">
        <span><span class="i" data-pt="&#218;ltima verifica&#231;&#227;o" data-en="Last checked">&#218;ltima verifica&#231;&#227;o</span>: <strong id="last-checked">{now_utc}</strong></span>
        <span><span class="i" data-pt="Hist&#243;rico" data-en="History">Hist&#243;rico</span>: <strong>{RETENTION} <span class="i" data-pt="dias" data-en="days">dias</span></strong></span>
      </div>
    </div>
  </div>

  <div id="tbl">
    <table>
      <thead><tr>
        <th class="i" data-pt="Task" data-en="Task">Task</th>
        <th class="i" data-pt="Status" data-en="Status">Status</th>
        <th class="i" data-pt="In&#237;cio (UTC)" data-en="Start (UTC)">In&#237;cio (UTC)</th>
        <th class="i" data-pt="Fim (UTC)" data-en="End (UTC)">Fim (UTC)</th>
        <th class="i" data-pt="Dura&#231;&#227;o" data-en="Duration">Dura&#231;&#227;o</th>
        <th class="i" data-pt="Log" data-en="Log">Log</th>
      </tr></thead>
      <tbody>{rows_html}</tbody>
    </table>
  </div>

  <div id="log-sec" style="display:none">
    <div class="log-panel">
      <div class="log-hdr">
        <span id="log-title"></span>
        <span class="log-back" onclick="showTable()">&#8592; <span class="i" data-pt="Voltar &#224; tabela" data-en="Back to table">Voltar &#224; tabela</span></span>
      </div>
      <div id="log-body"></div>
    </div>
  </div>

  <script>
  var LANG='pt', refreshTimer=null;
  var FACILITY='{FACILITY}';

  // ── i18n ──
  function applyLang(){{
    document.querySelectorAll('.i[data-'+LANG+']').forEach(function(el){{
      el.textContent=el.getAttribute('data-'+LANG);
    }});
    document.querySelectorAll('select option.i[data-'+LANG+']').forEach(function(opt){{
      opt.textContent=opt.getAttribute('data-'+LANG);
    }});
    document.getElementById('btn-lang').textContent=LANG.toUpperCase();
    document.documentElement.lang=LANG;
  }}
  function toggleLang(){{
    LANG=LANG==='pt'?'en':'pt';
    try{{localStorage.setItem('hf_backup_lang',LANG);}}catch(e){{}}
    applyLang();
  }}

  // ── Auto-refresh ──
  function setRefresh(val){{
    clearTimeout(refreshTimer);
    var secs=parseInt(val,10);
    if(secs>0){{
      refreshTimer=setTimeout(function(){{
        if(document.getElementById('log-sec').style.display==='none') location.reload();
        else setRefresh(val); // defer while log open
      }},secs*1000);
    }}
  }}

  // ── Log panel ──
  function showLog(dateKey){{
    document.getElementById('tbl').style.display='none';
    document.getElementById('log-sec').style.display='';
    clearTimeout(refreshTimer);
    var title=dateKey+'-'+FACILITY+'-backup.log';
    document.getElementById('log-title').textContent='\U0001F4C4 '+title;
    document.getElementById('log-body').innerHTML='<span style="color:#666">A carregar\u2026</span>';
    fetch('/api/log?date='+dateKey)
      .then(function(r){{return r.text();}} )
      .then(function(txt){{
        var html=txt.split('\\n').map(function(line){{
          if(!line) return '';
          var cls='ll-info';
          if(/state=(completed|starting)/.test(line)||/\u2713/.test(line)) cls='ll-ok';
          if(/state=failed|ERROR|WARN/.test(line)) cls='ll-warn';
          return '<div class="'+cls+'">'+line.replace(/&/g,'&amp;').replace(/</g,'&lt;')+'</div>';
        }}).join('');
        document.getElementById('log-body').innerHTML=html||'<span style="color:#666">(empty)</span>';
      }})
      .catch(function(){{
        document.getElementById('log-body').innerHTML='<span style="color:#e74c3c">Erro ao carregar log.</span>';
      }});
  }}
  function showTable(){{
    document.getElementById('log-sec').style.display='none';
    document.getElementById('tbl').style.display='';
    var sel=document.getElementById('refresh-sel');
    setRefresh(sel?sel.value:'30');
  }}

  // ── Re-check (cache-busting reload) ──
  function doRecheck(){{
    var btn=document.getElementById('btn-recheck');
    btn.innerHTML='<span class="spin">&#8635;</span> '+(LANG==='pt'?'A verificar\u2026':'Checking\u2026');
    btn.disabled=true;
    location.href=location.pathname+'?_='+Date.now();
  }}

  // ── Backup Now ──
  function askBackup(){{
    document.getElementById('btn-backup').style.display='none';
    var c=document.getElementById('backup-confirm');
    c.style.display='inline-flex';
    applyLang();
  }}
  function cancelBackup(){{
    document.getElementById('btn-backup').style.display='';
    document.getElementById('backup-confirm').style.display='none';
  }}
  function triggerBackup(){{
    cancelBackup();
    var btn=document.getElementById('btn-backup');
    btn.disabled=true;
    btn.innerHTML='&#9654; '+(LANG==='pt'?'A iniciar\u2026':'Starting\u2026');
    fetch('/api/trigger-backup',{{method:'POST'}})
      .then(function(r){{
        if(r.status===409){{btn.innerHTML='&#9654; '+(LANG==='pt'?'Backup Agora':'Backup Now');btn.disabled=true;return;}}
        if(!r.ok) throw new Error(r.status);
        // Force 5s refresh so running status appears quickly
        clearTimeout(refreshTimer);
        refreshTimer=setTimeout(function(){{location.reload();}},5000);
      }})
      .catch(function(){{btn.disabled=false;btn.innerHTML='&#9654; '+(LANG==='pt'?'Backup Agora':'Backup Now');}});
  }}

  // ── Init ──
  (function(){{
    try{{
      var savedLang=localStorage.getItem('hf_backup_lang');
      if(savedLang==='en') LANG='en';
    }}catch(e){{}}
    setRefresh('30');
    applyLang();
  }})();
  </script>
</body>
</html>"""


# ── HTTP handler ───────────────────────────────────────────────────────────────

class _Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress per-request noise

    def _send(self, status, content_type, body, extra_headers=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/api/status":
            _purge_old()
            data = _get_status()
            self._send(200, "application/json", json.dumps(data))
        elif path == "/api/log":
            qs = parse_qs(parsed.query)
            date_param = qs.get("date", [None])[0]
            if not date_param:
                self._send(400, "text/plain", "Missing date parameter\n")
                return
            st, ct, body = _serve_log(date_param)
            self._send(st, ct, body)
        elif path == "/" or path == "":
            _purge_old()
            status = _get_status()
            events = _get_events()
            html = _render(status, events)
            self._send(200, "text/html; charset=utf-8", html,
                       {"Cache-Control": "no-store, no-cache, must-revalidate",
                        "Pragma": "no-cache", "Expires": "0"})
        else:
            self._send(404, "text/plain", "Not found\n")

    def do_POST(self):
        if self.path == "/api/trigger-backup":
            st, body = _handle_trigger()
            self._send(st, "text/plain", body)
        else:
            self._send(404, "text/plain", "Not found\n")


if __name__ == "__main__":
    print(f"[web-server] facility={FACILITY}  port={PORT}", flush=True)
    HTTPServer(("0.0.0.0", PORT), _Handler).serve_forever()
PYEOF

  chmod +x "${dir}/update_db.py" "${dir}/server.py"
  log "Web server files written to ${dir}"
}

_fix_permissions() {
  # Enforce correct permissions on all files written by the installer.
  # Safe to call on every run (idempotent).
  : "${BASE_DIR:=$(pwd)}"

  # Sensitive directories
  [[ -d "${BASE_DIR}/ssh" ]]              && chmod 700 "${BASE_DIR}/ssh"
  [[ -d "${BASE_DIR}/ssh/tls" ]]          && chmod 700 "${BASE_DIR}/ssh/tls"
  [[ -d "${BASE_DIR}/runtime/dbconf" ]]   && chmod 700 "${BASE_DIR}/runtime/dbconf"
  [[ -d "${BASE_DIR}/runtime/backups" ]]  && chmod 750 "${BASE_DIR}/runtime/backups"
  [[ -d "${BASE_DIR}/runtime/logs" ]]     && chmod 750 "${BASE_DIR}/runtime/logs"

  # Private SSH / TLS keys — owner read-only
  find "${BASE_DIR}/ssh" -maxdepth 2 \( -name "id_rsa" -o -name "id_kek" -o -name "*.key" \) \
    -exec chmod 600 {} \; 2>/dev/null || true

  # Public keys / known_hosts
  find "${BASE_DIR}/ssh" -maxdepth 2 \( -name "*.pub" -o -name "known_hosts" \) \
    -exec chmod 644 {} \; 2>/dev/null || true

  # .env — must be root-readable only (contains BORG_PASSPHRASE etc.)
  [[ -f "${BASE_DIR}/.env" ]] && chmod 600 "${BASE_DIR}/.env"

  # Executable scripts
  for _s in hf-tool.sh runtime/backup.sh runtime/pushgw-event.sh; do
    [[ -f "${BASE_DIR}/${_s}" ]] && chmod 750 "${BASE_DIR}/${_s}"
  done

  # Borgmatic config — sensitive (contains passphrases / DB credentials)
  find "${BASE_DIR}/config" -name "*.yaml" -exec chmod 600 {} \; 2>/dev/null || true

  # DB config files
  find "${BASE_DIR}/runtime/dbconf" -type f -exec chmod 600 {} \; 2>/dev/null || true

  log "File permissions verified."
}

main() {
  BASE_DIR=$(pwd)
  facility_code=$(pwd | xargs basename)
  if [[ "$BASE_DIR" == *" "* ]]; then
      die "The working directory path contains spaces: ${BASE_DIR}\nRename the directory (or any parent) so that no path component has a space."
  fi
  IMAGE="hub.csaude.org.mz/backup/hf_backup:1.0"
  CENTRAL_HOST="hf-backup.csaude.org.mz"
  show_welcome_message

  # Detect or prompt for backup mode (only asked on first run; re-runs read from .env)
  local _borg_mode
  if [[ -f ".env" ]]; then
    _borg_mode=$(_read_ini_value ".env" "BORG_MODE" 2>/dev/null || echo "")
    _borg_mode="${_borg_mode:-central}"
  else
    echo
    echo "Select backup mode:"
    echo "  central — backup sent over SSH to the central backup server (default)"
    echo "  local   — backup stored on a local external device (USB, HDD, NAS)"
    echo
    read -rp "Mode [central/local, default: central]: " _borg_mode
    _borg_mode="${_borg_mode,,}"
    [[ "$_borg_mode" == "local" ]] || _borg_mode="central"
    echo
  fi

  write_env_file
  prompt_borg_passphrase
  load_ini ".env"
  require_docker
  write_dirs
  gen_ssh_keys
  write_backup_script
  write_pushgw_event_script
  write_web_server_files
  write_borgmatic_config
  write_hf_tool
  write_compose
  write_trigger_units

  ensure_image_available "$(grep -m1 'image:' compose.yml | sed 's/.*image://;s/ //g')"
  
  local _cur_status _already_run
  _cur_status=$(_read_status "_status")
  _already_run=$(_read_status "_hf_backup_executed")

  # On upgrades, refresh the .service file (ExecStart may have changed).
  # Skipped on first run — --init is responsible for the initial installation.
  local _svc="/etc/systemd/system/hf-backup-${facility_code}.service"
  if [[ "${_already_run}" == "yes" && -f "${_svc}" ]]; then
    log "Updating systemd service: ${_svc}"
    cat > "${_svc}" <<EOF
[Unit]
Description=Health Facility Backup (${facility_code^^})
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${BASE_DIR}
ExecStart=${DOCKER_COMPOSE_CMD} -f ${BASE_DIR}/compose.yml run --rm hf-backup-${facility_code} run
TimeoutStartSec=0

EOF
    systemctl daemon-reload
    log "systemd service updated."
  fi

  _fix_permissions

  echo
  if [[ "${_already_run}" == "yes" ]]; then
    log "Upgrade/patch completed."
  else
    log "Installer complete."
  fi
  echo
  _write_status "_hf_backup_executed" "yes"
  if [[ "${_cur_status}" != "complete" && "${_already_run}" != "yes" ]]; then
    echo "NEXT STEPS:"
    echo
    if [[ "${_borg_mode:-central}" == "central" ]]; then
      echo "  1) Share the SSH key bundle with the central backup team:"
      echo "     ${BASE_DIR}/hf-${facility_code}-keys.tar.gz"
      echo
      echo "  2) While waiting for the account to be created, add your databases:"
      echo "     sudo ./hf-tool.sh --db-add"
      echo "     sudo ./hf-tool.sh --db-list"
      echo "     sudo ./hf-tool.sh --db-remove <name>"
      echo
      echo "  Once the central team confirms the account is ready, run:"
      echo "     sudo ./hf-tool.sh --init"
    else
      echo "  1) Add your databases to be backed up:"
      echo "     sudo ./hf-tool.sh --db-add"
      echo "     sudo ./hf-tool.sh --db-list"
      echo "     sudo ./hf-tool.sh --db-remove <name>"
      echo
      echo "  2) Connect the external storage device, then run:"
      echo "     sudo ./hf-tool.sh --init"
    fi
    echo
  fi
}

main "$@"
