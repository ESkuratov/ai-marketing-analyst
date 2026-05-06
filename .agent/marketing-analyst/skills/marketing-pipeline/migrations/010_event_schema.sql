-- Migration 004: Event-Based Schema — событийная архитектура для исторического анализа
-- Зависит от: 001_raw_schema.sql, 002_staging_schema.sql
-- Создает: staging.lead_events, staging.lead_snapshots
--          metrics.funnel_transitions, metrics.lead_stage_durations, metrics.historical_funnel

-- ============================================================
-- Table: staging.lead_events — ядро event-based архитектуры
-- Каждое изменение = отдельная строка (created, status_changed, merged)
-- ============================================================
CREATE TABLE IF NOT EXISTS staging.lead_events (
    event_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    studio_id           VARCHAR(50) NOT NULL,
    lead_id             BIGINT NOT NULL,              -- ID из источника
    source              VARCHAR(50) NOT NULL,       -- amo / yclients / gsheets

    -- Идентификация клиента
    client_phone        VARCHAR(50),                -- нормализованный телефон для matching

    -- Тип события
    event_type          VARCHAR(50) NOT NULL,       -- created / status_changed / merged / deleted
    stage_from          VARCHAR(100),               -- предыдущий статус (NULL для created)
    stage_to            VARCHAR(100),               -- новый статус

    -- UTM-метки на момент события
    utm_source          VARCHAR(255),
    utm_campaign        VARCHAR(255),
    utm_medium          VARCHAR(255),
    utm_content         VARCHAR(255),
    utm_term            VARCHAR(255),

    -- Метаданные события
    event_timestamp     TIMESTAMPTZ NOT NULL,     -- когда произошло в источнике
    processed_at        TIMESTAMPTZ DEFAULT NOW(), -- когда записали у нас

    -- Полные данные события для replay/debug
    raw_data            JSONB,

    -- Оптимизация: составной индекс для распространенных запросов
    CONSTRAINT chk_event_type CHECK (event_type IN ('created', 'status_changed', 'merged', 'deleted'))
);

-- Индексы для event-based queries
CREATE INDEX IF NOT EXISTS idx_lead_events_studio_lead
    ON staging.lead_events (studio_id, lead_id, source);

CREATE INDEX IF NOT EXISTS idx_lead_events_timestamp
    ON staging.lead_events (event_timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_lead_events_type
    ON staging.lead_events (event_type);

CREATE INDEX IF NOT EXISTS idx_lead_events_client_phone
    ON staging.lead_events (client_phone)
    WHERE client_phone IS NOT NULL;

-- Индекс для поиска событий по диапазону времени (для backfill и реплея)
CREATE INDEX IF NOT EXISTS idx_lead_events_studio_time
    ON staging.lead_events (studio_id, event_timestamp DESC);

-- ============================================================
-- Table: staging.lead_snapshots — версионированные состояния
-- Позволяет запросить "сколько лидов было в статусе X на дату Y"
-- ============================================================
CREATE TABLE IF NOT EXISTS staging.lead_snapshots (
    snapshot_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    studio_id           VARCHAR(50) NOT NULL,
    lead_id             BIGINT NOT NULL,
    source              VARCHAR(50) NOT NULL,       -- amo / yclients / gsheets

    -- Период действия snapshot (SCD Type 2)
    valid_from          TIMESTAMPTZ NOT NULL,         -- начало действия состояния
    valid_to            TIMESTAMPTZ,                -- конец действия (NULL = текущее)

    -- Состояние на момент valid_from
    stage_name          VARCHAR(100),               -- текущий статус
    utm_source          VARCHAR(255),
    utm_campaign        VARCHAR(255),
    utm_medium          VARCHAR(255),
    utm_content         VARCHAR(255),
    utm_term            VARCHAR(255),
    amount              NUMERIC(12, 2),
    is_first_visit      BOOLEAN DEFAULT FALSE,
    client_phone        VARCHAR(50),

    -- Ссылка на породившее событие
    event_id            UUID REFERENCES staging.lead_events(event_id),

    created_at          TIMESTAMPTZ DEFAULT NOW()
);

-- Индексы для point-in-time queries
CREATE INDEX IF NOT EXISTS idx_lead_snapshots_studio_lead
    ON staging.lead_snapshots (studio_id, lead_id, source);

-- Критический индекс для AS OF запросов (исторические срезы)
CREATE INDEX IF NOT EXISTS idx_lead_snapshots_validity
    ON staging.lead_snapshots (studio_id, stage_name, valid_from, valid_to);

CREATE INDEX IF NOT EXISTS idx_lead_snapshots_current
    ON staging.lead_snapshots (studio_id, lead_id)
    WHERE valid_to IS NULL;

-- ============================================================
-- Table: metrics.funnel_transitions — агрегат переходов между статусами
-- ============================================================
CREATE TABLE IF NOT EXISTS metrics.funnel_transitions (
    studio_id           VARCHAR(50) NOT NULL,
    transition_date     DATE NOT NULL,              -- дата перехода
    stage_from          VARCHAR(100) NOT NULL,       -- с какого статуса
    stage_to            VARCHAR(100) NOT NULL,      -- на какой статус
    lead_count          INTEGER DEFAULT 0,          -- кол-во переходов
    avg_duration_hours  NUMERIC(12, 2),             -- среднее время на предыдущем этапе
    loaded_at           TIMESTAMPTZ DEFAULT NOW(),

    PRIMARY KEY (studio_id, transition_date, stage_from, stage_to)
);

CREATE INDEX IF NOT EXISTS idx_funnel_transitions_studio_date
    ON metrics.funnel_transitions (studio_id, transition_date DESC);

-- ============================================================
-- Table: metrics.lead_stage_durations — статистика по времени на этапах
-- ============================================================
CREATE TABLE IF NOT EXISTS metrics.lead_stage_durations (
    studio_id               VARCHAR(50) NOT NULL,
    week_start              DATE NOT NULL,          -- понедельник недели
    stage_name              VARCHAR(100) NOT NULL,   -- этап воронки
    avg_duration_hours      NUMERIC(12, 2),         -- среднее время
    median_duration_hours   NUMERIC(12, 2),         -- медианное время
    p95_duration_hours      NUMERIC(12, 2),         -- 95-й перцентиль
    leads_count             INTEGER DEFAULT 0,      -- кол-во лидов
    loaded_at               TIMESTAMPTZ DEFAULT NOW(),

    PRIMARY KEY (studio_id, week_start, stage_name)
);

CREATE INDEX IF NOT EXISTS idx_stage_durations_studio_week
    ON metrics.lead_stage_durations (studio_id, week_start DESC);

-- ============================================================
-- Table: metrics.historical_funnel — срез воронки на любую дату
-- Позволяет ответить: "сколько лидов было в статусе X на дату Y"
-- ============================================================
CREATE TABLE IF NOT EXISTS metrics.historical_funnel (
    studio_id           VARCHAR(50) NOT NULL,
    snapshot_date       DATE NOT NULL,              -- дата среза
    stage_name          VARCHAR(100) NOT NULL,       -- этап воронки
    lead_count          INTEGER DEFAULT 0,          -- кол-во на этапе
    loaded_at           TIMESTAMPTZ DEFAULT NOW(),

    PRIMARY KEY (studio_id, snapshot_date, stage_name)
);

CREATE INDEX IF NOT EXISTS idx_historical_funnel_studio_date
    ON metrics.historical_funnel (studio_id, snapshot_date DESC);

-- ============================================================
-- Comments: документация для понимания event-based подхода
-- ============================================================
COMMENT ON TABLE staging.lead_events IS
    'Event-sourcing core: каждое изменение лида = отдельная строка. Позволяет replay и historical analysis.';

COMMENT ON TABLE staging.lead_snapshots IS
    'SCD Type 2 snapshots: позволяет запросить состояние на любую дату (AS OF запросы).';

COMMENT ON TABLE metrics.funnel_transitions IS
    'Event-based metric: анализирует переходы между статусами из lead_events.';

COMMENT ON TABLE metrics.lead_stage_durations IS
    'Event-based metric: статистика времени на этапах (avg, median, p95).';

COMMENT ON TABLE metrics.historical_funnel IS
    'Event-based metric: позволяет смотреть воронку на любую дату в прошлом.';
