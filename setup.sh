#!/usr/bin/env bash
# ============================================================
#  Marketing Agent — One-Command Setup for OpenCLAW
# ============================================================
#  Usage:
#    ./setup.sh                        # Full setup (interactive)
#    ./setup.sh --auto                 # Non-interactive, env-based
#    ./setup.sh --dry-run              # Preview only
#    ./setup.sh --db-only              # Database migrations only
#    ./setup.sh --cron-only            # Setup cron jobs only
#
#  This script will:
#    1. Check preconditions (openclaw CLI, PostgreSQL, env)
#    2. Create marketing-analyst agent in OpenCLAW
#    3. Deploy workspace files + pipeline skill со скриптами
#    4. Configure database connection (DATABASE_URL) и проверит доступность
#    5. Run PostgreSQL migrations (4 schemas: raw, staging, metrics, ops)
#    6. Install Python dependencies
#    7. Configure YClients API tokens (YC_BEARER_TOKEN + YC_USER_TOKEN)
#    8. Configure Google Sheets Leads Sheet ID
#    9. Initial data load (optional, interactive)
#    10. Setup 6 cron-задач (daily/weekly/monthly/alert scanner) через openclaw-cli
#    11. Setup studio (интерактивное добавление)
#    12. Setup Telegram-бота для маркетингового агента
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}"

# ── Colors ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC}  $*"; }
success() { echo -e "${GREEN}✔${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "${RED}✖${NC}  $*" >&2; }
step()    { echo -e "\n${MAGENTA}▸${NC} ${BOLD}$*${NC}"; }

# ── Paths ──────────────────────────────────────────────────────
AGENT_ID="marketing-analyst"
AGENT_SOURCE_DIR="${PROJECT_DIR}/.agent/${AGENT_ID}"
SKILL_DIR="${AGENT_SOURCE_DIR}/.skills/marketing-pipeline"

OPENCLAW_HOME="${HOME}/.openclaw"
OPENCLAW_CONFIG="${OPENCLAW_HOME}/openclaw.json"
WORKSPACE_DIR="${OPENCLAW_HOME}/workspace-${AGENT_ID}"
SKILL_DEST="${WORKSPACE_DIR}/.skills/marketing-pipeline"
VENV_DIR="${WORKSPACE_DIR}/.venv"
PY_CMD="${VENV_DIR}/bin/python"

# Cross-platform sed in-place (BSD sed -i '', GNU sed -i)
if [[ "$OSTYPE" == "darwin"* ]]; then
  SED_INPLACE=(sed -i '')
else
  SED_INPLACE=(sed -i)
fi

DB_URL="${DATABASE_URL:-postgresql://localhost:5432/massage_studio}"
MODEL="${MODEL:-claude-sonnet-4-20250514}"
AUTO=false
DRY_RUN=false
DB_ONLY=false
CRON_ONLY=false

# ── Args ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --auto)        AUTO=true;        shift ;;
    --dry-run)     DRY_RUN=true;     shift ;;
    --db-only)     DB_ONLY=true;     shift ;;
    --cron-only)   CRON_ONLY=true;   shift ;;
    --model)       MODEL="$2";       shift 2 ;;
    -h|--help)
      echo "Usage: ./setup.sh [OPTIONS]"
      echo "  --auto          Non-interactive (env-based)"
      echo "  --dry-run       Preview only"
      echo "  --db-only       Run DB migrations only"
      echo "  --cron-only     Setup cron jobs only"
      echo "  --model MODEL   Model for OpenCLAW agent"
      exit 0 ;;
    *) error "Unknown: $1"; exit 1 ;;
  esac
done

run() {
  if [[ "${DRY_RUN}" == true ]]; then echo -e "  ${DIM}\$ $*${NC}"; else eval "$@"; fi
}

# ── 0. Install psql if needed ───────────────────────────────────
install_psql_if_needed() {
  if command -v psql &>/dev/null; then
    return 0
  fi

  step "PostgreSQL client not found"

  if [[ "${AUTO}" == true ]]; then
    info "AUTO mode: attempting automatic installation..."
  else
    echo "  PostgreSQL client (psql) is required for database migrations."
    read -p "  Install automatically? [Y/n]: " -n 1 -r
    echo
    if [[ "${REPLY}" =~ ^[Nn]$ ]]; then
      # Show manual install command and give one more chance
      local os_hint=""
      if [[ "$OSTYPE" == "darwin"* ]]; then
        os_hint="brew install postgresql"
      elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt-get &>/dev/null; then
          os_hint="sudo apt-get install -y postgresql-client"
        elif command -v yum &>/dev/null; then
          os_hint="sudo yum install -y postgresql"
        elif command -v dnf &>/dev/null; then
          os_hint="sudo dnf install -y postgresql"
        fi
      fi
      echo ""
      if [[ -n "${os_hint}" ]]; then
        info "Install manually: ${os_hint}"
      else
        info "Download: https://www.postgresql.org/download/"
      fi
      echo ""
      read -p "  Установили? Проверить снова? [y/N]: " -n 1 -r
      echo
      if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
        if command -v psql &>/dev/null; then
          success "psql now available"
          return 0
        else
          warn "psql still not found."
        fi
      fi
      PSQL_RETRY_DECLINED=true
      return 1
    fi
  fi

  if [[ "$OSTYPE" == "darwin"* ]]; then
    if command -v brew &>/dev/null; then
      info "Installing PostgreSQL client via Homebrew..."
      brew install postgresql || brew install libpq
    else
      error "Homebrew not found. Please install PostgreSQL manually."
      return 1
    fi
  elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if command -v apt-get &>/dev/null; then
      info "Installing PostgreSQL client via apt..."
      sudo apt-get update -qq
      sudo apt-get install -y -qq postgresql-client
    elif command -v yum &>/dev/null; then
      info "Installing PostgreSQL client via yum..."
      sudo yum install -y postgresql
    elif command -v dnf &>/dev/null; then
      info "Installing PostgreSQL client via dnf..."
      sudo dnf install -y postgresql
    else
      error "Package manager not found. Please install PostgreSQL client manually."
      return 1
    fi
  else
    error "Unsupported OS: $OSTYPE"
    return 1
  fi

  if command -v psql &>/dev/null; then
    success "PostgreSQL client installed successfully"
    return 0
  else
    error "Installation failed. Please install manually."
    return 1
  fi
}

# ── Retry psql with recommendation ────────────────────────────
retry_psql() {
  if [[ "${PSQL_RETRY_DECLINED}" == true ]]; then
    return 1
  fi

  local os_hint=""
  if [[ "$OSTYPE" == "darwin"* ]]; then
    os_hint="brew install postgresql"
  elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if command -v apt-get &>/dev/null; then
      os_hint="sudo apt-get install -y postgresql-client"
    elif command -v yum &>/dev/null; then
      os_hint="sudo yum install -y postgresql"
    elif command -v dnf &>/dev/null; then
      os_hint="sudo dnf install -y postgresql"
    fi
  fi

  echo ""
  warn "PostgreSQL client (psql) is required for this step."
  if [[ -n "${os_hint}" ]]; then
    info "Install it: ${os_hint}"
  else
    info "Download: https://www.postgresql.org/download/"
  fi
  echo ""
  read -p "  Установили? Проверить снова? [y/N]: " -n 1 -r
  echo
  if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
    if command -v psql &>/dev/null; then
      PSQL_AVAILABLE=true
      success "psql now available"
      return 0
    else
      warn "psql still not found. Try installing manually, then re-run the script."
      PSQL_RETRY_DECLINED=true
      return 1
    fi
  fi
  PSQL_RETRY_DECLINED=true
  return 1
}

# ── 1. Preflight ────────────────────────────────────────────────
preflight() {
  step "Preflight checks"

  if ! command -v openclaw &>/dev/null; then
    warn "openclaw CLI not found (npm install -g openclaw). Continuing without agent creation..."
    OPENCLAW_AVAILABLE=false
  else
    OPENCLAW_AVAILABLE=true
    success "openclaw CLI found"
  fi

  if ! command -v psql &>/dev/null; then
    if install_psql_if_needed; then
      PSQL_AVAILABLE=true
    else
      warn "psql not available. Migrations will be skipped."
      PSQL_AVAILABLE=false
    fi
  else
    PSQL_AVAILABLE=true
    success "PostgreSQL client found"
  fi

  local required=(
    "${AGENT_SOURCE_DIR}/SOUL.md"
    "${AGENT_SOURCE_DIR}/AGENTS.md"
    "${AGENT_SOURCE_DIR}/TOOLS.md"
    "${SKILL_DIR}/SKILL.md"
    "${SKILL_DIR}/connectors/run_all.py"
    "${SKILL_DIR}/pipeline/run_pipeline.py"
    "${SKILL_DIR}/telegram/message_builder.py"
    "${SKILL_DIR}/migrations/init_db.sh"
  )
  for f in "${required[@]}"; do
    if [[ ! -f "$f" ]]; then error "Missing: $f"; exit 1; fi
  done
  success "Source structure: ${AGENT_SOURCE_DIR}"
}

# ── 2. Deploy agent workspace ──────────────────────────────────
deploy_workspace() {
  step "Deploy agent workspace → ${WORKSPACE_DIR}"

  if [[ "${OPENCLAW_AVAILABLE}" != true ]]; then
    warn "Skipping (openclaw not available)"
    return
  fi

  run mkdir -p "${WORKSPACE_DIR}"

  # === Root workspace files ===
  run cp "${AGENT_SOURCE_DIR}/SOUL.md"   "${WORKSPACE_DIR}/SOUL.md"
  run cp "${AGENT_SOURCE_DIR}/TOOLS.md"  "${WORKSPACE_DIR}/TOOLS.md"
  run cp "${AGENT_SOURCE_DIR}/AGENTS.md" "${WORKSPACE_DIR}/AGENTS.md"
  success "Workspace root files deployed"

  # === Pipeline skill (self-contained, со всеми скриптами) ===
  run mkdir -p "${SKILL_DEST}"
  run cp -r "${SKILL_DIR}/." "${SKILL_DEST}/"
  success "Pipeline skill deployed → .skills/marketing-pipeline/ (connectors, pipeline, telegram, migrations)"

  # === .env ===
  run cp "${AGENT_SOURCE_DIR}/.env.example" "${WORKSPACE_DIR}/.env.example"
  success ".env.example deployed"

  # Register agent in OpenCLAW
  if [[ "${DRY_RUN}" != true ]]; then
    if openclaw agents add "${AGENT_ID}" \
      --model "anthropic/${MODEL}" \
      --workspace "${WORKSPACE_DIR}" \
      2>/dev/null; then
      success "Agent '${AGENT_ID}' created"
    else
      info "Agent '${AGENT_ID}' already exists, skipping"
    fi

    openclaw agents set-identity \
      --agent "${AGENT_ID}" \
      --name "Маркетолог" \
      2>/dev/null || true
  fi
}

# ── 3. Database setup ────────────────────────────────────────────
setup_db() {
  step "Database connection"

  if [[ "${PSQL_AVAILABLE}" != true ]]; then
    retry_psql || { warn "Skipping database setup"; return; }
  fi

  local current_url="${DATABASE_URL:-${DB_URL}}"
  local env_file="${WORKSPACE_DIR}/.env"

  if [[ -f "${env_file}" ]]; then
    local saved_url
    saved_url=$(grep -oP 'DATABASE_URL=\K.*' "${env_file}" 2>/dev/null || true)
    if [[ -n "${saved_url}" ]]; then
      current_url="${saved_url}"
    fi
  fi

  if [[ "${AUTO}" == true ]]; then
    DB_URL="${current_url}"
    info "Using: ${DB_URL}"
    info "Testing connection..."
    if ! psql "${DB_URL}" -c "SELECT 1 AS ok;" -t -q 2>/dev/null; then
      warn "Cannot connect to PostgreSQL. Migrations will be skipped."
      PSQL_AVAILABLE=false
      return
    fi
    success "Connection OK: ${DB_URL}"
  else
    while true; do
      echo "  Current: ${current_url}"
      read -p "  Connection string [${current_url}]: " input
      DB_URL="${input:-${current_url}}"

      info "Testing connection..."
      local psql_err
      psql_err=$(psql "${DB_URL}" -c "SELECT 1 AS ok;" -t -q 2>&1) && rc=0 || rc=$?
      if [[ "${rc}" == 0 ]]; then
        success "Connection OK: ${DB_URL}"
        break
      else
        warn "Cannot connect to PostgreSQL with: ${DB_URL}"
        echo -e "  ${DIM}${psql_err}${NC}"
        read -p "  Try again? [Y/n]: " -n 1 -r
        echo
        if [[ "${REPLY}" =~ ^[Nn]$ ]]; then
          warn "Migrations will be skipped."
          PSQL_AVAILABLE=false
          return
        fi
        current_url="${DB_URL}"
      fi
    done
  fi

  if [[ "${DRY_RUN}" != true ]]; then
    if [[ -f "${env_file}" ]] && grep -q "DATABASE_URL" "${env_file}" 2>/dev/null; then
      "${SED_INPLACE[@]}" "s|DATABASE_URL=.*|DATABASE_URL=${DB_URL}|" "${env_file}" 2>/dev/null || true
    else
      mkdir -p "$(dirname "${env_file}")"
      echo "DATABASE_URL=${DB_URL}" >> "${env_file}"
    fi
    success "DATABASE_URL saved to ${env_file}"
  fi
}

# ── 4. Database migrations ─────────────────────────────────────
run_migrations() {
  step "Database migrations"

  if [[ "${PSQL_AVAILABLE}" != true ]]; then
    retry_psql || { warn "Skipping migrations"; return; }
  fi

  local init="${SKILL_DIR}/migrations/init_db.sh"
  if [[ "${DRY_RUN}" == true ]]; then
    info "Would run: DATABASE_URL='${DB_URL}' ${init}"
    return
  fi
  DATABASE_URL="${DB_URL}" bash "${init}"
  success "All schemas migrated (raw, staging, metrics, ops)"
}

# ── 5. Python dependencies ─────────────────────────────────────
install_deps() {
  step "Python dependencies"
  if [[ "${DRY_RUN}" == true ]]; then
    info "Would create venv & pip install -r ${SKILL_DIR}/requirements.txt"
    return
  fi

  local pip_cmd pip_flags
  if [[ ! -d "${VENV_DIR}" ]]; then
    info "Creating virtual environment..."
    if python3 -m venv "${VENV_DIR}" 2>/dev/null; then
      pip_cmd="${VENV_DIR}/bin/pip"
      pip_flags=""
    else
      warn "python3-venv not available — installing without virtual environment"
      PY_CMD="python3"
      pip_cmd="pip3"
      pip_flags="--break-system-packages --user"
    fi
  else
    pip_cmd="${VENV_DIR}/bin/pip"
    pip_flags=""
  fi

  ${pip_cmd} install ${pip_flags} -r "${SKILL_DIR}/requirements.txt" -q \
    && success "Packages installed" \
    || warn "pip failed — run manually: ${pip_cmd} install ${pip_flags} -r .agent/marketing-analyst/.skills/marketing-pipeline/requirements.txt"
}

# ── 6. YClients API tokens ────────────────────────────────────
setup_yc_tokens() {
  step "YClients API tokens"

  local env_file="${WORKSPACE_DIR}/.env"
  if [[ ! -f "${env_file}" ]]; then
    if [[ -f "${WORKSPACE_DIR}/.env.example" ]]; then
      cp "${WORKSPACE_DIR}/.env.example" "${env_file}"
    fi
  fi

  local existing_bearer="" existing_user=""
  if [[ -f "${env_file}" ]]; then
    existing_bearer=$(grep -E '^YC_BEARER_TOKEN=' "${env_file}" 2>/dev/null | cut -d'=' -f2- || true)
    existing_user=$(grep -E '^YC_USER_TOKEN=' "${env_file}" 2>/dev/null | cut -d'=' -f2- || true)
  fi

  if [[ "${AUTO}" == true ]]; then
    if [[ -n "${existing_bearer}" ]] && [[ -n "${existing_user}" ]]; then
      info "YC tokens already set in .env"
    else
      info "Skipping (use --auto, set YC_BEARER_TOKEN and YC_USER_TOKEN in .env)"
    fi
    return
  fi

  echo ""
  echo "  YClients API v1 (с заголовками v2)."
  echo "  Оба токена передаются в одном заголовке:"
  echo "    Authorization: Bearer <partner>, User <user>"
  echo ""
  echo "  Partner token — ключ API из Настройки → API → Ключи доступа"
  echo "  User token    — токен администратора из того же раздела"
  echo ""

  if [[ -n "${existing_bearer}" ]]; then
    info "YC_BEARER_TOKEN already set (${existing_bearer:0:10}...)"
    read -p "  Change? [y/N]: " -n 1 -r; echo
    if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
      read -p "  Partner token: " YC_BEARER
      YC_BEARER="${YC_BEARER:-${existing_bearer}}"
    else
      YC_BEARER="${existing_bearer}"
    fi
  else
    read -p "  Partner token: " YC_BEARER
  fi

  if [[ -n "${existing_user}" ]]; then
    info "YC_USER_TOKEN already set (${existing_user:0:10}...)"
    read -p "  Change? [y/N]: " -n 1 -r; echo
    if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
      read -p "  User token: " YC_USER
      YC_USER="${YC_USER:-${existing_user}}"
    else
      YC_USER="${existing_user}"
    fi
  else
    read -p "  User token: " YC_USER
  fi

  if [[ -z "${YC_BEARER}" ]] || [[ -z "${YC_USER}" ]]; then
    warn "YC tokens not provided — set manually in ${env_file}"
    return
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    info "Would save YC_BEARER_TOKEN and YC_USER_TOKEN to ${env_file}"
    return
  fi

  mkdir -p "${WORKSPACE_DIR}"

  if [[ ! -f "${env_file}" ]]; then
    echo "YC_BEARER_TOKEN=${YC_BEARER}" > "${env_file}"
    echo "YC_USER_TOKEN=${YC_USER}" >> "${env_file}"
  else
    if grep -q '^YC_BEARER_TOKEN=' "${env_file}" 2>/dev/null; then
      "${SED_INPLACE[@]}" "s|^YC_BEARER_TOKEN=.*|YC_BEARER_TOKEN=${YC_BEARER}|" "${env_file}"
    else
      echo "YC_BEARER_TOKEN=${YC_BEARER}" >> "${env_file}"
    fi
    if grep -q '^YC_USER_TOKEN=' "${env_file}" 2>/dev/null; then
      "${SED_INPLACE[@]}" "s|^YC_USER_TOKEN=.*|YC_USER_TOKEN=${YC_USER}|" "${env_file}"
    else
      echo "YC_USER_TOKEN=${YC_USER}" >> "${env_file}"
    fi
  fi
  success "YC tokens saved to ${env_file}"
}

# ── 7. AMO CRM credentials ──────────────────────────────────
setup_amo_crm() {
  step "AMO CRM credentials"

  local env_file="${WORKSPACE_DIR}/.env"
  if [[ ! -f "${env_file}" ]]; then
    if [[ -f "${WORKSPACE_DIR}/.env.example" ]]; then
      cp "${WORKSPACE_DIR}/.env.example" "${env_file}"
    fi
  fi

  local existing_base_url="" existing_id="" existing_secret=""
  if [[ -f "${env_file}" ]]; then
    existing_base_url=$(grep -E '^AMO_BASE_URL=' "${env_file}" 2>/dev/null | cut -d'=' -f2- || true)
    existing_id=$(grep -E '^AMO_INTEGRATION_ID=' "${env_file}" 2>/dev/null | cut -d'=' -f2- || true)
    existing_secret=$(grep -E '^AMO_SECRET_KEY=' "${env_file}" 2>/dev/null | cut -d'=' -f2- || true)
  fi

  if [[ "${AUTO}" == true ]]; then
    if [[ -n "${existing_id}" ]] && [[ -n "${existing_secret}" ]]; then
      info "AMO CRM credentials already set in .env"
    else
      info "Skipping (use --auto, set AMO_INTEGRATION_ID and AMO_SECRET_KEY in .env)"
    fi
    return
  fi

  echo ""
  echo "  AMO CRM — интеграция через OAuth2 Client."
  echo "  Данные берутся из настроек интеграции:"
  echo "    https://{domain}.amocrm.ru/settings/widgets/"
  echo ""

  if [[ -n "${existing_base_url}" ]]; then
    info "AMO_BASE_URL: ${existing_base_url}"
    read -p "  Change? [y/N]: " -n 1 -r; echo
    if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
      read -p "  AMO CRM URL (https://{subdomain}.amocrm.ru): " AMO_URL
      AMO_URL="${AMO_URL:-${existing_base_url}}"
    else
      AMO_URL="${existing_base_url}"
    fi
  else
    read -p "  AMO CRM URL (https://{subdomain}.amocrm.ru): " AMO_URL
  fi

  if [[ -n "${existing_id}" ]]; then
    info "AMO_INTEGRATION_ID already set (${existing_id:0:10}...)"
    read -p "  Change? [y/N]: " -n 1 -r; echo
    if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
      read -p "  Integration ID (Client ID): " AMO_ID
      AMO_ID="${AMO_ID:-${existing_id}}"
    else
      AMO_ID="${existing_id}"
    fi
  else
    read -p "  Integration ID (Client ID): " AMO_ID
  fi

  if [[ -n "${existing_secret}" ]]; then
    info "AMO_SECRET_KEY already set (${existing_secret:0:10}...)"
    read -p "  Change? [y/N]: " -n 1 -r; echo
    if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
      read -p "  Secret Key (Client Secret): " AMO_SECRET
      AMO_SECRET="${AMO_SECRET:-${existing_secret}}"
    else
      AMO_SECRET="${existing_secret}"
    fi
  else
    read -p "  Secret Key (Client Secret): " AMO_SECRET
  fi

  if [[ -z "${AMO_ID}" ]] || [[ -z "${AMO_SECRET}" ]]; then
    warn "AMO CRM credentials not provided — set manually in ${env_file}"
    return
  fi

  echo ""
  echo "  После получения Authorization Code через OAuth, укажите:"
  echo "  (можно оставить пустым и заполнить позже в .env)"
  read -p "  Token: " AMO_TOKEN
  read -p "  Refresh Token: " AMO_REFRESH_TOKEN

  if [[ "${DRY_RUN}" == true ]]; then
    info "Would save AMO CRM credentials to ${env_file}"
    return
  fi

  mkdir -p "${WORKSPACE_DIR}"

  local vars=(AMO_BASE_URL AMO_INTEGRATION_ID AMO_SECRET_KEY AMO_CLIENT_ID AMO_CLIENT_SECRET AMO_TOKEN AMO_REFRESH_TOKEN AMO_REDIRECT_URI)
  local vals=("${AMO_URL}" "${AMO_ID}" "${AMO_SECRET}" "${AMO_ID}" "${AMO_SECRET}" "${AMO_TOKEN}" "${AMO_REFRESH_TOKEN}" "https://example.com")

  for i in "${!vars[@]}"; do
    local var="${vars[$i]}"
    local val="${vals[$i]}"
    [[ -z "${val}" ]] && continue
    if ! grep -q "^${var}=" "${env_file}" 2>/dev/null; then
      echo "${var}=${val}" >> "${env_file}"
    else
      "${SED_INPLACE[@]}" "s|^${var}=.*|${var}=${val}|" "${env_file}"
    fi
  done
  success "AMO CRM credentials saved to ${env_file}"
}

# ── Test AMO CRM connection ────────────────────────────────
test_amo_connection() {
  local env_file="${WORKSPACE_DIR}/.env"
  local base_url token
  base_url=$(grep -E '^AMO_BASE_URL=' "${env_file}" 2>/dev/null | cut -d'=' -f2- || true)
  token=$(grep -E '^AMO_TOKEN=' "${env_file}" 2>/dev/null | cut -d'=' -f2- || true)

  if [[ -z "${base_url}" ]]; then
    info "AMO_BASE_URL not set — skipping connection test"
    return
  fi
  if [[ -z "${token}" ]]; then
    info "AMO_TOKEN not set — получен через OAuth позже, пропускаем проверку"
    return
  fi

  step "AMO CRM connection test"
  local rc
  rc=$(curl -s -o /dev/null -w "%{http_code}" "${base_url}/api/v4/account" \
    -H "Authorization: Bearer ${token}" 2>/dev/null) || rc=000

  if [[ "${rc}" == "200" ]]; then
    success "AMO CRM connection OK (${base_url})"
  else
    warn "AMO CRM connection failed (HTTP ${rc}) — проверьте AMO_BASE_URL и AMO_TOKEN"
  fi
}

# ── 8. Google Sheets Leads Sheet ID ──────────────────────────
setup_gs_leads() {
  step "Google Sheets Leads Sheet ID"

  local env_file="${WORKSPACE_DIR}/.env"
  if [[ ! -f "${env_file}" ]]; then
    if [[ -f "${WORKSPACE_DIR}/.env.example" ]]; then
      cp "${WORKSPACE_DIR}/.env.example" "${env_file}"
    fi
  fi

  local existing_sheet_id=""
  if [[ -f "${env_file}" ]]; then
    existing_sheet_id=$(grep -E '^GS_LEADS_SHEET_ID=' "${env_file}" 2>/dev/null | cut -d'=' -f2- || true)
  fi

  if [[ "${AUTO}" == true ]]; then
    if [[ -n "${existing_sheet_id}" ]]; then
      info "GS_LEADS_SHEET_ID already set (${existing_sheet_id})"
    else
      warn "GS_LEADS_SHEET_ID not set — лиды из рекламных каналов не будут загружаться"
    fi
    return
  fi

  if [[ -n "${existing_sheet_id}" ]]; then
    info "GS_LEADS_SHEET_ID: ${existing_sheet_id}"
    read -p "  Change? [y/N]: " -n 1 -r; echo
    if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
      read -p "  Google Sheet ID (из URL /d/{ID}/edit): " GS_SHEET
      GS_SHEET="${GS_SHEET:-${existing_sheet_id}}"
    else
      GS_SHEET="${existing_sheet_id}"
    fi
  else
    echo "  Sheet ID можно найти в URL Google Таблицы:"
    echo "  https://docs.google.com/spreadsheets/d/{ID}/edit"
    read -p "  Sheet ID: " GS_SHEET
  fi

  if [[ -z "${GS_SHEET}" ]]; then
    warn "GS_LEADS_SHEET_ID не указан — можно задать позже в ${env_file}"
    return
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    info "Would save GS_LEADS_SHEET_ID=${GS_SHEET} to ${env_file}"
    return
  fi

  mkdir -p "${WORKSPACE_DIR}"

  if [[ ! -f "${env_file}" ]]; then
    echo "GS_LEADS_SHEET_ID=${GS_SHEET}" > "${env_file}"
  else
    if grep -q '^GS_LEADS_SHEET_ID=' "${env_file}" 2>/dev/null; then
      "${SED_INPLACE[@]}" "s|^GS_LEADS_SHEET_ID=.*|GS_LEADS_SHEET_ID=${GS_SHEET}|" "${env_file}"
    else
      echo "GS_LEADS_SHEET_ID=${GS_SHEET}" >> "${env_file}"
    fi
  fi
  success "GS_LEADS_SHEET_ID saved to ${env_file}"
}

# ── 9. Initial data load ─────────────────────────────────────
setup_initial_data() {
  step "Initial data load"

  if [[ "${PSQL_AVAILABLE}" != true ]]; then
    retry_psql || { warn "Skipping initial data load"; return; }
  fi

  if [[ "${AUTO}" == true ]]; then
    info "Skipping (use --auto, run connectors manually)"
    return
  fi

  echo ""
  echo "  Хотите загрузить реальные данные из AMO CRM, YClients и Google Sheets?"
  read -p "  Загрузить начальные данные? [y/N]: " -n 1 -r
  echo
  if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
    info "Initial data load skipped"
    return
  fi

  echo ""
  echo "  Выберите источники для загрузки (можно несколько через запятую):"
  echo "    1. AMO CRM (лиды)"
  echo "    2. YClients (визиты)"
  echo "    3. Google Sheets (расходы + лиды из рекламных каналов)"
  echo "    4. Все источники"
  read -p "  Номера [4]: " SOURCES
  SOURCES="${SOURCES:-4}"

  echo ""
  echo "  Укажите период для загрузки данных:"
  read -p "  Дата начала (YYYY-MM-DD) [2026-01-01]: " DATE_FROM
  DATE_FROM="${DATE_FROM:-2026-01-01}"
  read -p "  Дата окончания (YYYY-MM-DD) [$(date +%Y-%m-%d)]: " DATE_TO
  DATE_TO="${DATE_TO:-$(date +%Y-%m-%d)}"

  echo ""
  info "Период: ${DATE_FROM} → ${DATE_TO}"

  local run_all="${SKILL_DIR}/connectors/run_all.py"
  local py_cmd="PYTHONPATH=${SKILL_DIR} ${PY_CMD} ${run_all}"

  if [[ "${DRY_RUN}" == true ]]; then
    info "Would run: ${py_cmd} --date-from=${DATE_FROM} --date-to=${DATE_TO}"
    return
  fi

  success "Запуск загрузки данных..."
  PYTHONPATH="${SKILL_DIR}" DATABASE_URL="${DB_URL}" "${PY_CMD}" "${run_all}" --date-from="${DATE_FROM}" --date-to="${DATE_TO}" \
    && success "Данные загружены успешно" \
    || warn "Загрузка завершилась с ошибками — проверьте токены API и соединение"

  echo ""
  info "После загрузки данных запустите пайплайн для обработки:"
  info "  PYTHONPATH=${SKILL_DEST} ${PY_CMD} ${SKILL_DEST}/pipeline/run_pipeline.py --all-studios"
}

# ── 10. Studio setup ────────────────────────────────────────────
setup_studio() {
  step "Studio setup"

  if [[ "${PSQL_AVAILABLE}" != true ]]; then retry_psql || { warn "Skipping studio setup"; return; }; fi

  local count
  count=$(psql "${DB_URL}" -t -c "SELECT COUNT(*) FROM ops.studios" 2>/dev/null | tr -d ' ' || echo "0")
  if [[ "${count}" -gt 0 ]]; then info "Studios exist (${count}), skipping"; return; fi

  if [[ "${AUTO}" == true ]]; then
    info "Skipping (use --auto, add studio later via add_studio.py)"
    return
  fi

  echo "  No studios found. Add one now?"
  read -p "  Studio ID [studio_a]: " STUDIO_ID; STUDIO_ID="${STUDIO_ID:-studio_a}"
  read -p "  Name [Моя студия]: " STUDIO_NAME; STUDIO_NAME="${STUDIO_NAME:-Моя студия}"
  read -p "  YClients company ID (optional): " YC_ID
  read -p "  AMO CRM domain (optional): " AMO_DOMAIN

  local PYTHONPATH="${PROJECT_DIR}/.agent/marketing-analyst/.skills/marketing-pipeline"
  local CMD="PYTHONPATH=${PYTHONPATH} DATABASE_URL=${DB_URL} ${PY_CMD} ${PROJECT_DIR}/add_studio.py"
  CMD="${CMD} --studio-id=${STUDIO_ID} --name=\"${STUDIO_NAME}\""
  [[ -n "${YC_ID}" ]]     && CMD="${CMD} --yc-company-id=${YC_ID}"
  [[ -n "${AMO_DOMAIN}" ]] && CMD="${CMD} --amo-domain=${AMO_DOMAIN}"

  if [[ "${DRY_RUN}" == true ]]; then
    info "Would run: ${CMD}"
    return
  fi

  eval "${CMD}" && success "Studio '${STUDIO_ID}' added" || warn "Studio setup failed — add later via add_studio.py"
}

# ── 11. Cron jobs ──────────────────────────────────────────────────
setup_cron() {
  step "Cron jobs"

  if [[ "${OPENCLAW_AVAILABLE}" != true ]]; then
    warn "Skipping (openclaw not available)"
    return
  fi

  local jobs=(
    "daily-digest|30 19 * * *|Запусти daily pipeline: S1 Collect → S2 Normalize → S3 Reconcile → S4 Metrics → S5a Alerts → S5b Reports. Отправь ежедневный отчёт в Telegram."
    "weekly-funnel|0 11 * * 1|Запусти weekly pipeline: S1-S4 за неделю, сформируй еженедельный отчёт по воронке и каналам."
    "monthly-retention|0 8 1 * *|Запусти monthly pipeline за прошлый месяц. Сформируй отчёт по клиентской базе: активные, пассивные, потерянные, возвращённые."
    "monthly-abonements|0 18 28-31 * *|Сформируй отчёт по рейтингу абонементов за месяц."
    "monthly-channels|5 8 1 * *|Сформируй отчёт по каналам: CAC, LTV, ROMI с рекомендациями."
    "alert-scanner|7 */4 * * *|Проверь условия алертов A01-A14 по свежим метрикам. При срабатывании отправь уведомление в Telegram."
  )

  local created=0 skipped=0
  for job in "${jobs[@]}"; do
    IFS='|' read -r name cron message <<< "${job}"

    local existing
    existing=$(openclaw cron list --json 2>/dev/null | python3 -c "import sys,json; data=json.load(sys.stdin); print([j['id'] for j in data if j.get('name')=='${name}'])" 2>/dev/null || true)

    if [[ -n "${existing}" ]] && [[ "${existing}" != "[]" ]]; then
      info "Cron job '${name}' already exists, skipping"
      ((skipped++))
      continue
    fi

    if [[ "${DRY_RUN}" == true ]]; then
      info "Would create: openclaw cron add --name ${name} --cron \"${cron}\" --agent ${AGENT_ID} --session isolated --message \"${message:0:50}...\""
      ((skipped++))
      continue
    fi

    openclaw cron add \
      --name "${name}" \
      --cron "${cron}" \
      --agent "${AGENT_ID}" \
      --session isolated \
      --message "${message}" \
      2>/dev/null && ((created++)) || {
        warn "Failed to create '${name}'"
        ((skipped++))
      }
  done

  echo ""
  if [[ "${created}" -gt 0 ]]; then
    success "${created} cron job(s) created"
  fi
  if [[ "${skipped}" -gt 0 ]]; then
    info "${skipped} job(s) skipped (already exist or dry-run)"
  fi

  if [[ "${DRY_RUN}" != true ]]; then
    echo ""
    info "Current cron jobs for ${AGENT_ID}:"
    openclaw cron list 2>/dev/null | grep -E "(name|cron|agent)" || warn "No jobs found"
  fi
}

# ── 12. Telegram bot setup ─────────────────────────────────────
setup_telegram() {
  step "Telegram bot"

  if [[ "${OPENCLAW_AVAILABLE}" != true ]]; then
    warn "Skipping (openclaw CLI not available)"
    return
  fi

  if [[ "${AUTO}" == true ]]; then
    info "Skipping (use --auto, configure Telegram bot manually)"
    info "  1. openclaw config set channels.telegram.accounts.<ID>.enabled true"
    info "  2. openclaw agents bind --agent ${AGENT_ID} --bind telegram"
    info "  3. openclaw pairing approve telegram <CODE>"
    return
  fi

  echo ""
  echo "  Marketing agent needs a Telegram bot to send reports."
  echo "  1. Open Telegram → search @BotFather → /newbot"
  echo "  2. Name it (e.g. \"Маркетолог Студии\") → get token (e.g. 123456:ABC-DEF...)"
  echo ""
  read -p "  Step 0 — Bot ID (numeric part before : in token): " BOT_ID
  read -sp "  Step 1 — Full bot token: " TOKEN
  echo ""

  if [[ -z "${BOT_ID}" ]] || [[ -z "${TOKEN}" ]]; then
    warn "Bot ID or token not provided — Telegram setup skipped"
    return
  fi

  info "Bot ID: ${BOT_ID}"

  if [[ "${DRY_RUN}" == true ]]; then
    info "Would configure: openclaw config set channels.telegram.accounts.${BOT_ID}.*"
    info "Would run: openclaw agents bind --agent ${AGENT_ID} --bind telegram"
    return
  fi

  openclaw config set "channels.telegram.accounts.${BOT_ID}.enabled" true
  openclaw config set "channels.telegram.accounts.${BOT_ID}.botToken" "${TOKEN}"
  openclaw config set "channels.telegram.accounts.${BOT_ID}.groups.*.requireMention" true
  success "Telegram bot account '${BOT_ID}' configured in OpenCLAW"

  if openclaw agents bind --agent "${AGENT_ID}" --bind telegram 2>/dev/null; then
    success "Agent '${AGENT_ID}' bound to Telegram"
  else
    info "Agent already bound or bind skipped"
  fi

  echo ""
  echo "  ── Pairing ──"
  echo "  1. Open Telegram → find your bot → send /start"
  echo "  2. Bot will reply with a pairing code (e.g. ABC123)"
  read -p "  3. Enter the code from Telegram: " CODE

  if [[ -n "${CODE}" ]]; then
    openclaw pairing approve telegram "${CODE}" \
      && success "Telegram pairing approved" \
      || warn "Pairing failed — run manually: openclaw pairing approve telegram <CODE>"
  else
    warn "No code entered — run manually: openclaw pairing approve telegram <CODE>"
  fi
}

# ── Summary ─────────────────────────────────────────────────────
summary() {
  echo ""
  printf "${GREEN}+----------------------------------------------+${NC}\n"
  printf "${GREEN}|${NC}  Setup Complete!${NC}\n"
  printf "${GREEN}+----------------------------------------------+${NC}\n"
  echo ""
  echo "  Agent:      ${AGENT_ID}"
  echo "  DB:         ${DB_URL}"
  echo "  Workspace:  ${WORKSPACE_DIR}"
  echo "  Skill:      .skills/marketing-pipeline/"
  echo "              ├── SKILL.md"
  echo "              ├── connectors/    (S1 Collect)"
  echo "              ├── pipeline/      (S2→S5b Normalize→Reports)"
  echo "              ├── telegram/      (Message builder + callbacks)"
  echo "              └── migrations/    (4 PostgreSQL schemas)"
  echo ""
  echo "  Cron jobs:"
  echo "    daily-digest      22:30 MSK   (cron: 30 19 * * *)"
  echo "    weekly-funnel     Mon 14:00   (cron: 0 11 * * 1)"
  echo "    monthly-retention  1st 11:00  (cron: 0 8 1 * *)"
  echo "    monthly-abonements last 21:00 (cron: 0 18 28-31 * *)"
  echo "    monthly-channels    1st 11:05 (cron: 5 8 1 * *)"
  echo "    alert-scanner     every 4h    (cron: 7 */4 * * *)"
  echo ""
  echo "  Dependencies:"
  echo "    PostgreSQL:     $(if command -v psql &>/dev/null; then echo '✅ psql available'; else echo '⚠️  psql not installed (migrations skipped)'; fi)"
  echo ""
  echo "  Next steps:"
  echo "    1. Fill ${WORKSPACE_DIR}/.env with remaining API keys (AMO CRM)"
  echo "    2. openclaw gateway"
  echo "    3. ${PY_CMD} ${SKILL_DEST}/connectors/run_all.py"
  echo "       — test connectors"
  echo "    4. ${PY_CMD} ${SKILL_DEST}/pipeline/run_pipeline.py --all-studios"
  echo "       — run full pipeline"
  echo ""
}

# ── Main ────────────────────────────────────────────────────────
main() {
  echo ""
  printf "${CYAN}+----------------------------------------------+${NC}\n"
  printf "${CYAN}|${NC}  Marketing Agent — OpenCLAW Setup${NC}\n"
  printf "${CYAN}+----------------------------------------------+${NC}\n"
  echo ""

  if [[ -f "${OPENCLAW_CONFIG}" ]] && [[ "${DRY_RUN}" != true ]]; then
    local backup="${OPENCLAW_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "${OPENCLAW_CONFIG}" "${backup}"
    success "OpenCLAW config backed up → ${backup}"
  fi

  if [[ "${DB_ONLY}" == true ]]; then
    preflight
    setup_db
    run_migrations
    echo -e "\n${GREEN}✔${NC}  Migrations done"
    exit 0
  fi

  if [[ "${CRON_ONLY}" == true ]]; then
    preflight
    setup_cron
    echo -e "\n${GREEN}✔${NC}  Cron setup done"
    exit 0
  fi

  preflight
  deploy_workspace
  setup_db
  run_migrations
  install_deps
  setup_yc_tokens
  setup_amo_crm
  test_amo_connection
  setup_gs_leads
  setup_initial_data
  setup_studio
  setup_cron
  setup_telegram
  summary
}

main "$@"
