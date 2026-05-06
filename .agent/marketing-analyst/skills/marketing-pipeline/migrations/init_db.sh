#!/usr/bin/env bash
set -euo pipefail

# init_db.sh — запуск всех миграций PostgreSQL для marketing-agent
# Использование:
#   ./init_db.sh                              # локальная БД
#   DATABASE_URL=postgresql://... ./init_db.sh  # удалённая БД

DB_URL="${DATABASE_URL:-postgresql://localhost:5432/massage_studio}"
MIGRATIONS_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Initializing database: ${DB_URL} ==="

# Массив миграций в порядке выполнения
MIGRATIONS=(
    "001_raw_schema.sql"
    "002_staging_schema.sql"
    "003_metrics_schema.sql"
    "004_ops_schema.sql"
    "005_gsheets_leads_schema.sql"
    "006_pipeline_stage.sql"
    "007_normalize_phones.sql"
    "008_client_profiles.sql"
    "009_drop_staging_channels.sql"
    "010_event_schema.sql"
    "011_add_client_id_to_events.sql"
    "012_funnel_stages.sql"
    "013_add_lead_flags.sql"
)

for migration in "${MIGRATIONS[@]}"; do
    file="${MIGRATIONS_DIR}/${migration}"
    if [[ ! -f "$file" ]]; then
        echo "ERROR: Migration file not found: ${file}"
        exit 1
    fi
    echo "  Running: ${migration}..."
    psql "${DB_URL}" -f "${file}" -q
    echo "  Done: ${migration}"
done

echo "=== All migrations completed successfully ==="

# Проверка: схемы созданы
psql "${DB_URL}" -c "
    SELECT schema_name
    FROM information_schema.schemata
    WHERE schema_name IN ('raw', 'staging', 'metrics', 'ops')
    ORDER BY schema_name;
" -t
