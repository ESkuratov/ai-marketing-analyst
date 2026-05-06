# ER Диаграмма базы данных massage_studio

## Схема базы данных (PostgreSQL)

```mermaid
erDiagram
    %% ========== RAW LAYER (Источники данных) ==========
    RAW_AMO_LEADS {
        bigint id PK
        varchar studio_id
        varchar source
        varchar status
        varchar status_name
        varchar utm_source
        varchar utm_campaign
        varchar utm_medium
        varchar utm_content
        varchar utm_term
        bigint pipeline_id
        bigint stage_id
        bigint responsible_id
        timestamptz created_at
        timestamptz updated_at
        timestamptz closed_at
        numeric price
        varchar name
        varchar client_name
        varchar client_phone
        bigint client_id
        varchar client_first_name
        varchar client_last_name
        varchar client_email
        bigint client_responsible_id
        jsonb raw_data
        timestamptz loaded_at
    }

    RAW_YC_VISITS {
        bigint id PK
        varchar studio_id
        bigint client_id
        varchar client_name
        varchar client_phone
        bigint service_id
        varchar service_name
        bigint master_id
        varchar master_name
        date date
        time time
        numeric sum
        numeric discount
        varchar status
        boolean is_first_visit
        text comment
        jsonb raw_data
        timestamptz loaded_at
    }

    RAW_GS_EXPENSES {
        integer id PK
        varchar studio_id
        date date
        varchar article
        numeric amount
        varchar channel
        text description
        jsonb raw_data
        timestamptz loaded_at
    }

    RAW_GSHEETS_LEADS {
        integer id PK
        varchar studio_id
        bigint deal_id
        varchar source_name
        varchar utm_source
        varchar utm_campaign
        varchar client_name
        varchar client_phone
        varchar studio_name
        timestamptz created_at
        jsonb raw_data
        timestamptz loaded_at
    }

    %% ========== STAGING LAYER (Нормализация) ==========
    STAGING_LEADS_NORMALIZED {
        varchar studio_id
        bigint lead_id PK
        varchar source
        varchar status
        varchar funnel_stage
        varchar utm_source
        varchar utm_campaign
        varchar utm_medium
        varchar utm_content
        varchar utm_term
        timestamptz created_at
        timestamptz updated_at
        timestamptz closed_at
        bigint yc_booking_id
        date booking_date
        date visit_date
        varchar visit_status
        numeric amount
        varchar abonement_type
        boolean is_repeat
        boolean is_first_visit
        boolean created_by_admin
        bigint raw_amo_id FK
        bigint raw_yc_id FK
        uuid client_id FK
        bigint pipeline_id
        bigint stage_id
        timestamptz loaded_at
    }

    STAGING_CLIENT_PROFILES {
        uuid client_id PK
        varchar studio_id
        varchar client_phone
        varchar client_name
        varchar first_source
        timestamptz first_seen_at
        timestamptz last_seen_at
        varchar funnel_stage
        integer total_visits
        numeric total_revenue
        timestamptz created_at
        timestamptz updated_at
    }

    STAGING_CHANNELS {
        varchar studio_id
        varchar channel_name PK
        varchar channel_type
        date period_start PK
        date period_end PK
        numeric cost
        integer leads_count
        integer bookings_count
        integer visits_count
        numeric revenue
        timestamptz loaded_at
    }

    %% ========== METRICS LAYER (Агрегаты) ==========
    METRICS_DAILY_SUMMARY {
        varchar studio_id PK
        date date PK
        varchar channel PK
        integer leads_count
        integer bookings_count
        integer visits_count
        integer abonements_sold
        numeric revenue
        numeric conversion_lead_to_booking
        numeric conversion_booking_to_visit
        numeric conversion_visit_to_abon
        integer no_show_count
        numeric no_show_rate
        integer canceled_count
        numeric canceled_rate
        integer first_visit_count
        integer repeat_visit_count
        timestamptz loaded_at
    }

    METRICS_WEEKLY_FUNNEL {
        varchar studio_id PK
        date week_start PK
        varchar stage_name PK
        integer lead_count
        numeric conversion
        integer avg_duration
        timestamptz loaded_at
    }

    METRICS_MONTHLY_COHORTS {
        varchar studio_id PK
        date month PK
        date cohort_month PK
        integer client_count
        integer active_clients
        integer lost_clients
        integer returned_clients
        numeric revenue
        numeric cac
        numeric ltv
        numeric romi
        timestamptz loaded_at
    }

    METRICS_CHANNEL_ROI {
        varchar studio_id PK
        date month PK
        varchar channel PK
        numeric cost
        numeric revenue
        integer leads_count
        integer bookings_count
        numeric cac
        numeric ltv
        numeric romi
        timestamptz loaded_at
    }

    %% ========== OPS LAYER (Операционные) ==========
    OPS_STUDIOS {
        varchar studio_id PK
        varchar name
        bigint yc_company_id
        varchar amo_domain
        bigint amo_pipeline_id
        varchar gs_sheet_id
        varchar timezone
        boolean is_active
        timestamptz created_at
        timestamptz updated_at
    }

    OPS_ACTIVE_ALERTS {
        integer id PK
        varchar studio_id
        varchar alert_type
        varchar severity
        varchar metric_name
        numeric metric_value
        numeric threshold
        text recommendation
        timestamptz created_at
        timestamptz resolved_at
    }

    OPS_GATES {
        integer id PK
        integer alert_id FK
        varchar studio_id
        varchar alert_type
        varchar status
        varchar ack_by
        timestamptz created_at
        timestamptz resolved_at
    }

    OPS_CONFIG {
        varchar key PK
        varchar studio_id PK
        jsonb value
        text description
        timestamptz updated_at
    }

    %% ========== RELATIONSHIPS ==========
    RAW_AMO_LEADS ||--o{ STAGING_LEADS_NORMALIZED : "нормализация"
    RAW_YC_VISITS ||--o{ STAGING_LEADS_NORMALIZED : "нормализация"
    RAW_GSHEETS_LEADS ||--o{ STAGING_LEADS_NORMALIZED : "нормализация"

    STAGING_LEADS_NORMALIZED ||--o{ STAGING_CLIENT_PROFILES : "профили клиентов"
    STAGING_CHANNELS ||--o{ METRICS_CHANNEL_ROI : "агрегация"

    OPS_STUDIOS ||--o{ RAW_AMO_LEADS : "владелец"
    OPS_STUDIOS ||--o{ RAW_YC_VISITS : "владелец"
    OPS_STUDIOS ||--o{ RAW_GS_EXPENSES : "владелец"
    OPS_STUDIOS ||--o{ STAGING_LEADS_NORMALIZED : "владелец"
    OPS_STUDIOS ||--o{ METRICS_DAILY_SUMMARY : "владелец"
    OPS_STUDIOS ||--o{ OPS_ACTIVE_ALERTS : "генерация"
    OPS_STUDIOS ||--o{ OPS_GATES : "контроль"

    OPS_ACTIVE_ALERTS ||--o| OPS_GATES : "создаёт"
```

## Описание схем

### 1. raw — Сырые данные из источников

| Таблица | Источник | Описание |
|---------|----------|----------|
| `amo_leads` | AMO CRM | Лиды из CRM с полной инфой о клиенте |
| `yc_visits` | YClients | Записи на приём (визиты) |
| `gs_expenses` | Google Sheets | Расходы по статьям и каналам |
| `gsheets_leads` | Google Sheets | Лиды из рекламных каналов |

**Ключевые поля для матчинга:**
- `client_phone` — нормализованный телефон
- `studio_id` — идентификатор студии

### 2. staging — Нормализованные данные

| Таблица | Описание |
|---------|----------|
| `leads_normalized` | Единый формат лидов из всех источников |
| `client_profiles` | Профили клиентов с агрегированными метриками |
| `channels` | Нормализованные данные по каналам |

**Матчинг:**
- `raw_amo_id` → `raw.amo_leads.id`
- `raw_yc_id` → `raw.yc_visits.id`
- `client_id` → `staging.client_profiles.client_id`

### 3. metrics — Агрегированные метрики

| Таблица | Гранулярность | Метрики |
|---------|---------------|---------|
| `daily_summary` | День × Канал | Конверсии, no-show, выручка |
| `weekly_funnel` | Неделя × Этап | Воронка, время прохождения |
| `monthly_cohorts` | Месяц × Когорта | CAC, LTV, ROMI |
| `channel_roi` | Месяц × Канал | ROI по каналам |

### 4. ops — Операционные данные

| Таблица | Назначение |
|---------|------------|
| `studios` | Справочник студий с настройками интеграций |
| `active_alerts` | Активные алерты (A01-A04) |
| `gates` | HITL-gates для блокировки pipeline |
| `config` | Конфигурация и настройки |

**Внешние ключи:**
- `ops.gates.alert_id` → `ops.active_alerts.id`

## Поток данных (Pipeline S1→S5)

```
S1: Collect
  ├── AMO API → raw.amo_leads
  ├── YClients API → raw.yc_visits
  ├── Google Sheets → raw.gs_expenses
  └── Google Sheets → raw.gsheets_leads

S2: Normalize
  └── raw.* → staging.leads_normalized
      └── + staging.client_profiles

S3: Reconcile
  └── staging ↔ raw (проверка согласованности)
      └── ops.active_alerts (при расхождениях)

S4: Metrics
  └── staging → metrics.*

S5a: Alerts
  └── metrics → ops.active_alerts (A01-A04)
      └── ops.gates (при критических)

S5b: Reports
  └── metrics → Telegram-отчёты
```

## Индексы для производительности

```sql
-- raw слой (поиск по телефону и дате)
CREATE INDEX idx_amo_leads_phone ON raw.amo_leads(client_phone);
CREATE INDEX idx_amo_leads_created ON raw.amo_leads(created_at);
CREATE INDEX idx_yc_visits_phone ON raw.yc_visits(client_phone);
CREATE INDEX idx_yc_visits_date ON raw.yc_visits(date);

-- staging (матчинг)
CREATE INDEX idx_leads_norm_phone ON staging.leads_normalized(utm_source, created_at);
CREATE INDEX idx_client_profiles_phone ON staging.client_profiles(client_phone);

-- metrics (отчёты)
CREATE INDEX idx_daily_summary_date ON metrics.daily_summary(date, studio_id);
CREATE INDEX idx_channel_roi_month ON metrics.channel_roi(month, studio_id);
```
