# marketing-analyst — AI-агент маркетингового анализа

**Stateless pipeline-агент для сбора лидов, расчёта конверсий, CAC, LTV, ROMI и управления алертами в сети массажных студий.**

## Концепция

### Stateless

Агент не хранит состояние между запусками. Каждый запуск pipeline — независимый цикл:

```mermaid
flowchart LR
    TRIGGER["Триггер<br/>(cron / NL-запрос)"] --> READ["Прочитать<br/>(SELECT из PostgreSQL)"]
    READ --> PROCESS["Обработать<br/>(Pipeline S1–S5)"]
    PROCESS --> WRITE["Записать<br/>(INSERT в PostgreSQL)"]
    WRITE --> DONE["Завершить"]
    DONE -.->|"следующий запуск"| TRIGGER
```

- Всё состояние вынесено в PostgreSQL (4 схемы: `raw`, `staging`, `metrics`, `ops`)
- Нет in-memory кэша, нет долгоживущих процессов, нет сессий между запусками
- Любой запуск можно повторить — результат будет идентичным при тех же входных данных
- Масштабирование — pipeline для N студий запускается одним и тем же кодом, параметризованным `studio_id`

#### Shared Memory как способ взаимодействия

Агенты stateless по отдельности, но координируются через **общую базу данных (shared memory)**:

```mermaid
flowchart TB
    subgraph AGENTS["Stateless AI-агенты"]
        MKT["marketing-analyst<br/>пишет metrics.*"]
        OPS["ops-analyst<br/>читает metrics.*"]
        CHIEF["chief-operator<br/>читает сводки"]
        QUAL["quality-manager<br/>пишет оценки"]
    end

    subgraph DB["PostgreSQL — Shared Memory"]
        SHARED[("единое состояние<br/>для всех агентов")]
    end

    MKT -->|"INSERT metrics.*"| SHARED
    OPS -->|"SELECT metrics.*"| SHARED
    CHIEF -->|"SELECT из всех схем"| SHARED
    QUAL -->|"INSERT оценки"| SHARED
```

- Агент **пишет** результаты своей работы в PostgreSQL (`metrics.*`, `ops.*`)
- Другие агенты **читают** эти данные при следующем запуске — без прямых вызовов между собой
- `chief-operator` агрегирует данные из всех схем для утренних/вечерних сводок
- Такой обмен через shared memory — неотъемлемая черта stateless-архитектуры: агенты не владеют данными, они их производят и потребляют через единое хранилище

### Event-Based Architecture

Переход от snapshot-based к event-based подходу:

- **Event Sourcing**: Каждое изменение лида = отдельная строка в `staging.lead_events`
- **SCD Type 2**: `staging.lead_snapshots` хранит историю состояний с `valid_from`/`valid_to`
- **Historical Funnel**: Можно восстановить воронку на любую дату в прошлом (`metrics.historical_funnel`)
- **Stage Validation**: Бизнес-правила проверки между системами (AMO ↔ YClients ↔ GSheets)

### Детерминированный pipeline

Pipeline состоит из последовательных шагов. Каждый шаг — pure transformation: на входе данные из предыдущего шага, на выходе — запись в БД.

```mermaid
flowchart LR
    S1["S1: Collect<br/>Сбор данных"] --> S2["S2: Normalize<br/>Нормализация"]
    S2 --> S2b["S2b: Profiles<br/>Профили клиентов"]
    S2b --> S2c["S2c: Events<br/>Event-based"]
    S2c --> S3["S3: Reconcile<br/>Сверка"]
    S3 --> S4["S4: Metrics<br/>Snapshot метрики"]
    S3 --> S4b["S4b: Event Metrics<br/>Event-based метрики"]
    S4 --> S5a["S5a: Alerts<br/>Алерты"]
    S4b --> S5a
    S4 --> S5b["S5b: Reports<br/>Отчёты"]
```

- **Idempotent**: повторный запуск за тот же период не создаёт дубликатов (UPSERT по `studio_id + id`)
- **Перезапускаем**: если шаг упал, pipeline перезапускается с него же
- **Предсказуем**: при одинаковых входных данных — одинаковый результат

### HITL / HOTL (точки контроля)

| Тип | Алерты | Действие |
|-----|--------|----------|
| **HOTL** (Human-On-The-Loop) | A01–A03: конверсия, неявки, CAC | Уведомление в Telegram. Pipeline продолжается. |
| **HITL** (Human-In-The-Loop) | A04: расхождение AMO↔YC >10% | Блокировка pipeline для студии до кнопки ✅ |

HITL gate:

```mermaid
flowchart LR
    A04["A04: Расхождение AMO↔YC >10%"] -->|"🔴 HITL"| TG["Telegram + кнопка ✅"]
    TG -->|"Георгий нажимает ✅"| GATE["ops.gates: resolved"]
    GATE -.->|"разблокировать"| PIPELINE["Pipeline для студии"]
    PIPELINE -->|"следующий cron"| A04
```

## Архитектура

```mermaid
flowchart TB
    subgraph PLATFORM["OpenCLAW Platform"]
        TG["Telegram / Slack"] --> GW["Gateway"]
        GW --> ROUTER["Multi-Agent Router"]
    end

    subgraph MARKETING["🤖 marketing-analyst (stateless)"]
        PIPELINE["Pipeline<br/>S1→S2→S2b→S2c→S3→S4→S4b→S5"]
        CONN_AMO["AMO CRM Connector"]
        CONN_YC["YClients Connector"]
        CONN_GS["Google Sheets Connector"]
    end

    subgraph DB["PostgreSQL"]
        SHARED[("raw → staging → metrics → ops<br/>studio_id partition key")]
    end

    ROUTER -->|"NL-запросы / команды"| MARKETING
    CONN_AMO -->|"REST API"| AMO[AMO CRM]
    CONN_YC -->|"REST API"| YC[YClients]
    CONN_GS -->|"API/Browser"| GS[Google Sheets]
    MARKETING -->|"чтение/запись"| SHARED
    MARKETING -->|"отчёты / алерты"| TG
```

## Pipeline (8 шагов)

### S1: Collect — сбор данных

Для каждой активной студии из `ops.studios`:
- **AMO CRM** — лиды за период, воронка, UTM-метки
- **YClients** — записи, визиты, суммы, статусы
- **Google Sheets** — расходы по статьям, лиды из рекламы

Параметризация: `studio_id → amo_domain, yc_company_id, gs_sheet_id`

### S2: Normalize — нормализация и дедупликация

- Унификация статусов лидов через `ops.funnel_stages`
- Категоризация источников трафика
- Дедупликация по `id` (UPSERT: `ON CONFLICT (studio_id, id) DO UPDATE`)

### S2b: Client Profiles — профили клиентов

- Matching по `client_phone` (нормализованный: `7XXXXXXXXXX`)
- Агрегация: `total_visits`, `total_revenue`, `first_source`
- Связь всех источников через `client_id` UUID

### S2c: Process Events — event-based ядро

- Генерация событий: `created`, `status_changed`, `merged`
- Stage mapping: AMO `stage_id` → `ops.funnel_stages.stage_code`
- Client ID resolution: телефон → `client_id`
- Создание snapshots: SCD Type 2 с `valid_from`/`valid_to`

### S3: Reconcile — сверка источников

| Сверка | Пороги | Правила валидации |
|--------|--------|-------------------|
| AMO ↔ YClients (записи) | <5% INFO, 5–10% WARNING, >10% **HITL** | `ops.stage_validation_rules` |
| AMO ↔ Google Sheets (лиды) | <5% INFO, 5–10% WARNING | Проверка `phone` + обогащение UTM |
| YClients ↔ Google Sheets (суммы) | <5% INFO, 5–10% WARNING | Сверка расходов |

### S4: Metrics — snapshot метрики

Per-studio и consolidated (`studio_id = 'all'`):

- **Конверсии**: `lead_to_booking`, `booking_to_visit`, `lead_to_abonement`
- **CAC** — стоимость привлечения клиента по каналу
- **LTV** — средняя выручка с клиента за 6 месяцев
- **ROMI** — возврат маркетинговых инвестиций
- **No-show rate**, cancellation rate

### S4b: Event Metrics — event-based метрики

- **Funnel Transitions**: переходы между статусами с `avg_duration_hours`
- **Lead Stage Durations**: время на этапе (avg, median, p95)
- **Historical Funnel**: воронка на любую дату в прошлом
- **Cohort Analysis**: активные / пассивные / потерянные / возвращённые

### S5a: Alerts + S5b: Reports — алерты и отчёты

**Алерты:**

| ID | Условие | Severity | Тип |
|----|---------|----------|-----|
| A01 | Конверсия <30% 3 дня подряд | IMPORTANT | HOTL |
| A02 | Неявки > X% за 7 дней | IMPORTANT | HOTL |
| A03 | CAC > средний + 20% | IMPORTANT | HOTL |
| A04 | Расхождение AMO↔YC >10% | CRITICAL | HITL |
| Validation | Нарушение бизнес-правила из `funnel-flow.md` | WARNING/CRITICAL | HOTL |

**Отчёты** (Telegram Markdown):

| Отчёт | Расписание | Содержание |
|-------|-----------|------------|
| Ежедневный | 22:30 | Лиды за день, конверсии, сверка |
| Еженедельный | Пн 14:00 | Воронка, топ-5 каналов, неявки |
| Клиентская база | 1 число 11:00 | Активные/потерянные, LTV |
| Абонементы | Крайний день 21:00 | Рейтинг, средний чек |
| Каналы | 1 число 11:05 | CAC/LTV/ROMI, рекомендации |

## Storage (PostgreSQL)

```mermaid
flowchart TB
    subgraph RAW["schema: raw — сырые данные"]
        RAW_AMO["raw.amo_leads<br/>Лиды из AMO CRM"]
        RAW_YC["raw.yc_visits<br/>Записи из YClients"]
        RAW_GS["raw.gs_expenses<br/>Расходы из Google Sheets"]
        RAW_GSL["raw.gsheets_leads<br/>Лиды из Google Sheets"]
    end

    subgraph STAGING["schema: staging — нормализованные"]
        STG_EVENTS["staging.lead_events<br/>Event-based (SCD Type 2)"]
        STG_SNAP["staging.lead_snapshots<br/>Версии состояний"]
        STG_LEADS["staging.leads_normalized<br/>Snapshot лиды"]
        STG_PROF["staging.client_profiles<br/>Профили клиентов"]
    end

    subgraph METRICS["schema: metrics — метрики"]
        MET_D["metrics.daily_summary<br/>Конверсии по дням"]
        MET_W["metrics.weekly_funnel<br/>Воронка WoW"]
        MET_FT["metrics.funnel_transitions<br/>Переходы между статусами"]
        MET_LSD["metrics.lead_stage_durations<br/>Время на этапах"]
        MET_HF["metrics.historical_funnel<br/>Историческая воронка"]
        MET_M["metrics.monthly_cohorts<br/>CAC, LTV, ROMI"]
        MET_R["metrics.channel_roi<br/>ROI по каналам"]
    end

    subgraph OPS["schema: ops — алерты и конфиги"]
        OPS_S["ops.studios<br/>Регистр студий"]
        OPS_FS["ops.funnel_stages<br/>Справочник этапов воронки"]
        OPS_SVR["ops.stage_validation_rules<br/>Бизнес-правила проверки"]
        OPS_A["ops.active_alerts<br/>Текущие алерты"]
        OPS_G["ops.gates<br/>HITL gates"]
        OPS_C["ops.config<br/>Пороги, расписания"]
    end

    RAW --> STG_EVENTS
    STG_EVENTS --> STG_SNAP
    STG_SNAP --> STG_LEADS
    STG_LEADS --> METRICS
    RAW -.->|"сверка"| OPS
    METRICS -.->|"алерты"| OPS
    OPS_FS -.->|"маппинг"| STG_EVENTS
    OPS_SVR -.->|"валидация"| STG_EVENTS
```

Все таблицы содержат колонку `studio_id`. Метрики хранятся per-studio (`studio_id = 'studio_a'`) и consolidated (`studio_id = 'all'`).

## NL-запросы (Natural Language)

Поддерживаемые интенты:

| Intent | Пример | Действие |
|--------|--------|----------|
| `get_leads_today` | "покажи отчёт по лидам за вчера" | S1 + S4 за период |
| `get_conversion` | "какая конверсия из в работу в запись" | S4 для lead_to_booking |
| `get_source_ranking` | "какой источник даёт больше всего лидов" | S4 + сортировка |
| `reconcile_amo_yc` | "сверь лиды AMO и таблицу" | S3 |
| `get_no_shows` | "сколько неявок за неделю" | S4 для no_show_rate |
| `get_historical_funnel` | "какая была воронка 1 марта" | S4b historical_funnel |

Фильтрация по `studio_id` если указана студия, иначе consolidated.

## Интеграции с другими агентами

| Кому | Что | Когда |
|------|-----|-------|
| **ops-analyst** | Лиды по каналам → загрузка студии | После daily |
| **finance-analyst** | CAC, ROMI, выручка по каналам | После monthly |
| **hr-manager** | Распределение клиентов по мастерам | После weekly |
| **quality-manager** | Оценка качества трафика | После monthly |

## Проект

```
.agent/marketing-analyst/
├── README.md                           ← этот файл
├── .skills/marketing-pipeline/
│   ├── SKILL.md                        # Промпт агента
│   ├── connectors/                     # Python-коннекторы
│   │   ├── base_connector.py
│   │   ├── amo_connector.py
│   │   ├── yc_connector.py
│   │   ├── gsheets_connector.py
│   │   └── config.py
│   ├── migrations/                     # PostgreSQL миграции
│   │   ├── 001_raw_schema.sql
│   │   ├── 002_staging_schema.sql
│   │   ├── 003_metrics_schema.sql
│   │   ├── 004_ops_schema.sql
│   │   ├── 005_gsheets_leads_schema.sql
│   │   ├── 006_pipeline_stage.sql
│   │   ├── 007_normalize_phones.sql
│   │   ├── 008_client_profiles.sql
│   │   ├── 009_drop_staging_channels.sql
│   │   ├── 010_event_schema.sql
│   │   ├── 011_add_client_id_to_events.sql
│   │   ├── 012_funnel_stages.sql
│   │   └── init_db.sh
│   ├── pipeline/                       # SQL-запросы pipeline
│   │   ├── s1_collect.sql
│   │   ├── s2_normalize.sql
│   │   ├── s2b_client_profiles.sql
│   │   ├── s2c_process_events.sql
│   │   ├── s3_reconcile.sql
│   │   ├── s4_metrics.sql
│   │   ├── s4b_event_metrics.sql
│   │   ├── s5a_alerts.sql
│   │   ├── s5b_reports.sql
│   │   └── run_pipeline.py
│   ├── docs/                           # Документация
│   │   ├── er-diagram-event-based.mmd  # ER-диаграмма
│   │   ├── event-based-architecture.md # Описание event-based
│   │   └── funnel-flow.md              # Бизнес-правила воронки
│   └── telegram/                       # Telegram интеграция
│       └── bot_handler.py
```

## Развёртывание на OpenCLAW

### Структура агента

```
repos/projects/massage_studio/
├── .agent/
│   └── marketing-analyst/              # Директория агента
│       ├── agent.yaml                  # Конфигурация агента OpenCLAW
│       ├── .skills/                    # Навыки агента
│       │   └── marketing-pipeline/
│       │       ├── SKILL.md            # Промпт агента
│       │       ├── handlers/           # Обработчики intent'ов
│       │       │   ├── __init__.py
│       │       │   ├── leads.py        # get_leads_today
│       │       │   ├── conversion.py   # get_conversion
│       │       │   ├── reconcile.py    # reconcile_amo_yc
│       │       │   └── reports.py      # S5b reports
│       │       ├── connectors/         # Python-коннекторы
│       │       │   ├── __init__.py
│       │       │   ├── base.py
│       │       │   ├── amo.py          # AMO CRM
│       │       │   ├── yclients.py     # YClients
│       │       │   └── gsheets.py      # Google Sheets
│       │       ├── migrations/         # SQL миграции
│       │       ├── pipeline/           # SQL pipeline
│       │       └── docs/               # Документация
│       └── .env                        # ENV переменные
├── memory/                             # Память агента (auto-memory)
│   └── MEMORY.md
└── plans/                              # Планы выполнения
```

### Конфигурация agent.yaml

```yaml
name: marketing-analyst
description: AI-агент маркетингового анализа для массажных студий
version: 2.0.0

skills:
  - name: marketing-pipeline
    path: .skills/marketing-pipeline
    entry: handlers/

triggers:
  - type: cron
    schedule: "30 22 * * *"           # Ежедневный отчёт в 22:30
    intent: daily_report
  - type: cron
    schedule: "0 14 * * 1"            # Еженедельный в понедельник 14:00
    intent: weekly_report
  - type: cron
    schedule: "0 11 1 * *"            # Ежемесячный 1 числа в 11:00
    intent: monthly_report
  - type: webhook
    path: /telegram                    # Telegram webhook
    intent: telegram_command

intents:
  - name: get_leads_today
    description: Отчёт по лидам за период
    handler: leads.get_leads
  - name: get_conversion
    description: Конверсия по воронке
    handler: conversion.get_conversion
  - name: reconcile_amo_yc
    description: Сверка AMO ↔ YClients
    handler: reconcile.run_reconcile
  - name: daily_report
    description: Ежедневный отчёт
    handler: reports.daily
  - name: weekly_report
    description: Еженедельный отчёт
    handler: reports.weekly
  - name: monthly_report
    description: Ежемесячный отчёт
    handler: reports.monthly

env:
  required:
    - POSTGRES_DSN                    # PostgreSQL connection string
    - AMO_DOMAIN                      # xsizeryazp.amocrm.ru
    - AMO_CLIENT_ID                   # OAuth2
    - AMO_CLIENT_SECRET
    - AMO_REFRESH_TOKEN
    - YCLIENTS_PARTNER_TOKEN          # YClients API
    - YCLIENTS_USER_TOKEN
    - GSHEETS_CREDENTIALS             # Google Sheets (JSON)
    - TELEGRAM_BOT_TOKEN              # Telegram уведомления
    - TELEGRAM_CHAT_ID
  optional:
    - LOG_LEVEL=INFO
    - METRICS_RETENTION_DAYS=90

resources:
  cpu: 1
  memory: 512Mi
  storage: 10Gi
```

### Переменные окружения (.env)

```bash
# PostgreSQL
POSTGRES_DSN=postgresql://user:pass@localhost:5432/marketing

# AMO CRM OAuth2
AMO_DOMAIN=xsizeryazp.amocrm.ru
AMO_CLIENT_ID=xxx
AMO_CLIENT_SECRET=xxx
AMO_REFRESH_TOKEN=xxx

# YClients API
YCLIENTS_PARTNER_TOKEN=xxx
YCLIENTS_USER_TOKEN=xxx

# Google Sheets (Service Account JSON)
GSHEETS_CREDENTIALS={"type":"service_account",...}

# Telegram
TELEGRAM_BOT_TOKEN=xxx
TELEGRAM_CHAT_ID=-1001234567890

# Studio IDs (comma-separated)
STUDIOS=studio_a,studio_b
```

### Быстрый старт (setup.sh)

```bash
# 1. Клонировать репозиторий
git clone <repo> repos/projects/massage_studio
cd repos/projects/massage_studio

# 2. Запустить интерактивную установку
./setup.sh

# Или неинтерактивный режим (все параметры из ENV)
./setup.sh --auto

# Только миграции БД
./setup.sh --db-only

# Только cron-задачи
./setup.sh --cron-only

# Проверка без изменений (dry-run)
./setup.sh --dry-run
```

### Что делает setup.sh

1. **Preflight** — проверка наличия `openclaw`, `psql`, структуры проекта
2. **Deploy workspace** — копирование файлов агента в `~/.openclaw/workspace-marketing-analyst/`
3. **Database** — подключение к PostgreSQL, тест соединения
4. **Migrations** — выполнение всех SQL-миграций (4 схемы: raw, staging, metrics, ops)
5. **Dependencies** — `pip install` Python-пакетов
6. **YClients tokens** — интерактивный ввод Partner + User токенов
7. **Google Sheets** — ввод Sheet ID для лиды из рекламы
8. **Cron jobs** — создание 6 расписаний:
   - `daily-digest` — 22:30 ежедневно
   - `weekly-funnel` — понедельник 14:00
   - `monthly-retention` — 1-е число 11:00
   - `monthly-abonements` — последний день месяца 21:00
   - `monthly-channels` — 1-е число 11:05
   - `alert-scanner` — каждые 4 часа
9. **Studio setup** — интерактивное добавление первой студии
10. **Telegram bot** — настройка и pairing с Telegram

### Ручной деплой (если setup.sh не подходит)

```bash
# 1. Клонировать
# 2. Установить зависимости
pip install -r .agent/marketing-analyst/.skills/marketing-pipeline/requirements.txt

# 3. Применить миграции
psql $POSTGRES_DSN -f .agent/marketing-analyst/.skills/marketing-pipeline/migrations/init_db.sh

# 4. Создать .env
cp .agent/marketing-analyst/.env.example .agent/marketing-analyst/.env
# Редактировать .env

# 5. Запустить агента
openclaw agent deploy .agent/marketing-analyst/
openclaw agent status marketing-analyst
```

### Инициализация БД

```bash
# Выполнить все миграции
psql $POSTGRES_DSN << EOF
-- Schema: raw, staging, metrics, ops
\i .agent/marketing-analyst/.skills/marketing-pipeline/migrations/001_raw_schema.sql
\i .agent/marketing-analyst/.skills/marketing-pipeline/migrations/002_staging_schema.sql
\i .agent/marketing-analyst/.skills/marketing-pipeline/migrations/003_metrics_schema.sql
\i .agent/marketing-analyst/.skills/marketing-pipeline/migrations/004_ops_schema.sql
\i .agent/marketing-analyst/.skills/marketing-pipeline/migrations/005_gsheets_leads_schema.sql
\i .agent/marketing-analyst/.skills/marketing-pipeline/migrations/006_pipeline_stage.sql
\i .agent/marketing-analyst/.skills/marketing-pipeline/migrations/007_normalize_phones.sql
\i .agent/marketing-analyst/.skills/marketing-pipeline/migrations/008_client_profiles.sql
\i .agent/marketing-analyst/.skills/marketing-pipeline/migrations/009_drop_staging_channels.sql
\i .agent/marketing-analyst/.skills/marketing-pipeline/migrations/010_event_schema.sql
\i .agent/marketing-analyst/.skills/marketing-pipeline/migrations/011_add_client_id_to_events.sql
\i .agent/marketing-analyst/.skills/marketing-pipeline/migrations/012_funnel_stages.sql

-- Seed data: ops.studios
INSERT INTO ops.studios (studio_id, name, yc_company_id, amo_domain, amo_pipeline_id, gs_sheet_id, timezone, is_active)
VALUES ('studio_a', 'Студия А', 1234490, 'xsizeryazp.amocrm.ru', 9226358, 'sheet_id_1', 'Europe/Moscow', true),
       ('studio_b', 'Студия Б', 1234491, 'xsizeryazp.amocrm.ru', 9226358, 'sheet_id_2', 'Europe/Moscow', true);
EOF
```

### Проверка работоспособности

```bash
# Ручной запуск pipeline
openclaw agent run marketing-analyst --intent get_leads_today --params '{"studio_id": "studio_a", "date": "2026-05-06"}'

# Проверка логов
openclaw agent logs marketing-analyst --tail 100

# Проверка метрик
psql $POSTGRES_DSN -c "SELECT * FROM metrics.daily_summary WHERE studio_id = 'studio_a' ORDER BY date DESC LIMIT 5;"
```

## Ключевые документы

- `docs/er-diagram-event-based.mmd` — актуальная ER-диаграмма (25 таблиц)
- `docs/event-based-architecture.md` — описание event-based подхода
- `docs/funnel-flow.md` — 12 этапов воронки с бизнес-правилами проверки
