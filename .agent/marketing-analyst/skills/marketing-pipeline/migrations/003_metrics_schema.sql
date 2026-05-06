-- Migration 003: Metrics schema — рассчитанные метрики per-studio + consolidated
-- Зависит от: 002_staging_schema.sql (читает из staging.*, пишет в metrics.*)
-- consolidated: studio_id = 'all' означает сумму/среднее по всем студиям

CREATE SCHEMA IF NOT EXISTS metrics;

-- ============================================================
-- Table: metrics.daily_summary — конверсии по дням per-studio
-- ============================================================
CREATE TABLE IF NOT EXISTS metrics.daily_summary (
    studio_id                   VARCHAR(50) NOT NULL,   -- studio_id или 'all'
    date                        DATE NOT NULL,
    channel                     VARCHAR(255) DEFAULT 'all',

    -- Абсолютные значения
    leads_count                 INTEGER DEFAULT 0,
    bookings_count              INTEGER DEFAULT 0,
    visits_count                INTEGER DEFAULT 0,
    abonements_sold             INTEGER DEFAULT 0,
    revenue                     NUMERIC(12, 2) DEFAULT 0,

    -- Конверсии
    conversion_lead_to_booking  NUMERIC(5, 2),          -- % лид → запись
    conversion_booking_to_visit NUMERIC(5, 2),          -- % запись → визит
    conversion_visit_to_abon    NUMERIC(5, 2),          -- % визит → покупка

    -- Качество
    no_show_count               INTEGER DEFAULT 0,
    no_show_rate                NUMERIC(5, 2),          -- % неявок
    canceled_count              INTEGER DEFAULT 0,
    canceled_rate               NUMERIC(5, 2),          -- % отмен

    first_visit_count           INTEGER DEFAULT 0,      -- новых клиентов
    repeat_visit_count          INTEGER DEFAULT 0,      -- повторных

    loaded_at                   TIMESTAMPTZ DEFAULT NOW(),

    PRIMARY KEY (studio_id, date, channel)
);

CREATE INDEX IF NOT EXISTS idx_daily_summary_studio_date
    ON metrics.daily_summary (studio_id, date DESC);

-- ============================================================
-- Table: metrics.weekly_funnel — воронка по неделям
-- ============================================================
CREATE TABLE IF NOT EXISTS metrics.weekly_funnel (
    studio_id       VARCHAR(50) NOT NULL,
    week_start      DATE NOT NULL,                  -- понедельник недели
    stage_name      VARCHAR(100) NOT NULL,           -- этап воронки
    lead_count      INTEGER DEFAULT 0,
    conversion      NUMERIC(5, 2),                   -- % конверсии на этот этап
    avg_duration    INTEGER,                         -- среднее время на этапе (часы)
    loaded_at       TIMESTAMPTZ DEFAULT NOW(),

    PRIMARY KEY (studio_id, week_start, stage_name)
);

CREATE INDEX IF NOT EXISTS idx_weekly_funnel_studio_week
    ON metrics.weekly_funnel (studio_id, week_start DESC);

-- ============================================================
-- Table: metrics.monthly_cohorts — когортный анализ per-studio
-- ============================================================
CREATE TABLE IF NOT EXISTS metrics.monthly_cohorts (
    studio_id       VARCHAR(50) NOT NULL,
    month           DATE NOT NULL,                  -- отчётный месяц
    cohort_month    DATE NOT NULL,                  -- месяц первой покупки
    client_count    INTEGER DEFAULT 0,
    active_clients  INTEGER DEFAULT 0,
    lost_clients    INTEGER DEFAULT 0,
    returned_clients INTEGER DEFAULT 0,
    revenue         NUMERIC(12, 2) DEFAULT 0,
    cac             NUMERIC(12, 2),                 -- стоимость привлечения
    ltv             NUMERIC(12, 2),                 -- пожизненная ценность
    romi            NUMERIC(5, 2),                  -- ROI маркетинга
    loaded_at       TIMESTAMPTZ DEFAULT NOW(),

    PRIMARY KEY (studio_id, month, cohort_month)
);

CREATE INDEX IF NOT EXISTS idx_monthly_cohorts_studio_month
    ON metrics.monthly_cohorts (studio_id, month DESC);

-- ============================================================
-- Table: metrics.channel_roi — ROI по каналам трафика per-studio
-- ============================================================
CREATE TABLE IF NOT EXISTS metrics.channel_roi (
    studio_id       VARCHAR(50) NOT NULL,
    month           DATE NOT NULL,
    channel         VARCHAR(255) NOT NULL,
    channel_type    VARCHAR(50),                    -- organic / paid / social / referral
    cost            NUMERIC(12, 2) DEFAULT 0,       -- затраты на канал
    revenue         NUMERIC(12, 2) DEFAULT 0,       -- выручка с канала
    leads_count     INTEGER DEFAULT 0,
    bookings_count  INTEGER DEFAULT 0,
    visits_count    INTEGER DEFAULT 0,              -- кол-во визитов
    cac             NUMERIC(12, 2),                 -- стоимость лида
    ltv             NUMERIC(12, 2),                 -- ltv по каналу
    romi            NUMERIC(5, 2),                  -- romi по каналу
    loaded_at       TIMESTAMPTZ DEFAULT NOW(),

    PRIMARY KEY (studio_id, month, channel)
);

CREATE INDEX IF NOT EXISTS idx_channel_roi_studio_month
    ON metrics.channel_roi (studio_id, month DESC);
