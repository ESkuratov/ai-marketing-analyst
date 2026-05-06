# TOOLS.md — marketing-analyst

## 1. Database (PostgreSQL)
Подключение через `DB_CONNECTION_STRING`.

**Схемы и таблицы:**
| Schema | Назначение | Таблицы |
|--------|-----------|---------|
| `raw` | Сырые данные от коннекторов | `amo_leads`, `yc_visits`, `gs_expenses`, `gsheets_leads` |
| `staging` | Нормализованные, дедуплицированные, профили клиентов | `leads_normalized`, `client_profiles`, `channels` |
| `metrics` | Рассчитанные метрики | `daily_summary`, `weekly_funnel`, `monthly_cohorts`, `channel_roi` |
| `ops` | Конфиги, алерты, gates | `studios`, `active_alerts`, `gates`, `config` |

Все таблицы содержат `studio_id` (partition key). Метрики: per-studio + consolidated (`studio_id = 'all'`).

## 2. Python Connectors (S1 Collect)
| Скрипт | Назначение |
|--------|-----------|
| `skills/marketing-pipeline/connectors/run_all.py` | Оркестратор: итерация по студиям, запуск коннекторов |
| `skills/marketing-pipeline/connectors/amo_connector.py` | Загрузка лидов из AMO CRM → `raw.amo_leads` |
| `skills/marketing-pipeline/connectors/yc_connector.py` | Загрузка визитов из YClients → `raw.yc_visits` |
| `skills/marketing-pipeline/connectors/gsheets_connector.py` | Загрузка расходов из Google Sheets (per-studio) → `raw.gs_expenses` |
| `skills/marketing-pipeline/connectors/gsheets_leads_connector.py` | Загрузка лидов из рекламных каналов (центральная таблица) → `raw.gsheets_leads` |

Запуск: `python skills/marketing-pipeline/connectors/run_all.py`

## 3. Pipeline SQL (S2→S5b)
| Файл | Шаг | Назначение |
|------|-----|-----------|
| `skills/marketing-pipeline/pipeline/run_pipeline.py` | — | Оркестратор: S2→S2b→S3→S4→S5a→S5b |
| `skills/marketing-pipeline/pipeline/s2_normalize.sql` | S2 | Нормализация + дедупликация → `staging.leads_normalized` |
| `skills/marketing-pipeline/pipeline/s2b_client_profiles.sql` | S2b | Профили клиентов по телефону → `staging.client_profiles` |
| `skills/marketing-pipeline/pipeline/s3_reconcile.sql` | S3 | Сверка AMO↔YC, AMO↔GS с порогами |
| `skills/marketing-pipeline/pipeline/s4_metrics.sql` | S4 | Конверсии, CAC, LTV, ROMI → `metrics.*` |
| `skills/marketing-pipeline/pipeline/s5a_alerts.sql` | S5a | Алерты A01-A04 → `ops.active_alerts` |
| `skills/marketing-pipeline/pipeline/s5b_reports.sql` | S5b | SELECT для отчётов |

Запуск: `python skills/marketing-pipeline/pipeline/run_pipeline.py --studio_id=studio_a`

## 4. Telegram (OpenCLAW)
| Файл | Назначение |
|------|-----------|
| `skills/marketing-pipeline/telegram/report_formatters.py` | Форматирование отчётов в MarkdownV2 |
| `skills/marketing-pipeline/telegram/message_builder.py` | Сборка сообщений с inline-кнопками для OpenCLAW |
| `skills/marketing-pipeline/telegram/callback_handler.py` | Обработка callback от кнопок (acknowledge/dismiss) |

## 5. Config
| Файл | Назначение |
|------|-----------|
| `skills/marketing-pipeline/connectors/config.py` | `DATABASE_URL`, `get_studios()`, StudioConfig |
| `skills/marketing-pipeline/migrations/init_db.sh` | Запуск миграций |
