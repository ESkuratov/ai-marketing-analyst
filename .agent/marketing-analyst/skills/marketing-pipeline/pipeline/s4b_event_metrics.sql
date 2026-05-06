-- S4b: Event-Based Metrics — расчет метрик из событий
-- Читает: staging.lead_events, staging.lead_snapshots
-- Пишет:  metrics.funnel_transitions, metrics.lead_stage_durations, metrics.historical_funnel
-- Параметр: %(studio_id)s, %(period_start)s, %(period_end)s

-- ============================================================
-- 1. funnel_transitions — подсчет переходов между статусами
-- ============================================================
INSERT INTO metrics.funnel_transitions (
    studio_id,
    transition_date,
    stage_from,
    stage_to,
    lead_count,
    avg_duration_hours
)
SELECT
    %(studio_id)s,
    e.event_timestamp::date AS transition_date,
    COALESCE(e.stage_from, 'new') AS stage_from,
    e.stage_to,
    COUNT(*) AS lead_count,
    AVG(
        CASE
            WHEN e.stage_from IS NOT NULL THEN
                EXTRACT(EPOCH FROM (e.event_timestamp - prev.event_timestamp)) / 3600
        END
    )::numeric(12,2) AS avg_duration_hours
FROM staging.lead_events e
LEFT JOIN staging.lead_events prev
    ON prev.studio_id = e.studio_id
    AND prev.lead_id = e.lead_id
    AND prev.source = e.source
    AND prev.event_type = 'created'
    AND e.stage_from IS NOT NULL
WHERE e.studio_id = %(studio_id)s
  AND e.event_type IN ('status_changed', 'created')
  AND (%(period_start)s::timestamptz IS NULL OR e.event_timestamp >= %(period_start)s::timestamptz)
  AND (%(period_end)s::timestamptz IS NULL OR e.event_timestamp < %(period_end)s::timestamptz)
GROUP BY e.event_timestamp::date, COALESCE(e.stage_from, 'new'), e.stage_to
ON CONFLICT (studio_id, transition_date, stage_from, stage_to) DO UPDATE SET
    lead_count = EXCLUDED.lead_count,
    avg_duration_hours = EXCLUDED.avg_duration_hours,
    loaded_at = NOW();

-- ============================================================
-- 2. lead_stage_durations — статистика времени на этапах
-- ============================================================
INSERT INTO metrics.lead_stage_durations (
    studio_id,
    week_start,
    stage_name,
    avg_duration_hours,
    median_duration_hours,
    p95_duration_hours,
    leads_count
)
WITH stage_durations AS (
    SELECT
        s.stage_name,
        date_trunc('week', s.valid_from)::date AS week_start,
        EXTRACT(EPOCH FROM (s.valid_to - s.valid_from)) / 3600 AS duration_hours
    FROM staging.lead_snapshots s
    WHERE s.studio_id = %(studio_id)s
      AND s.valid_to IS NOT NULL  -- Только закрытые интервалы
      AND (%(period_start)s::timestamptz IS NULL OR s.valid_from >= %(period_start)s::timestamptz)
      AND (%(period_end)s::timestamptz IS NULL OR s.valid_from < %(period_end)s::timestamptz)
),
duration_stats AS (
    SELECT
        stage_name,
        week_start,
        AVG(duration_hours) AS avg_duration,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY duration_hours) AS median_duration,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_hours) AS p95_duration,
        COUNT(*) AS cnt
    FROM stage_durations
    WHERE duration_hours > 0  -- Исключаем мгновенные переходы
    GROUP BY stage_name, week_start
)
SELECT
    %(studio_id)s,
    week_start,
    stage_name,
    ROUND(avg_duration::numeric, 2),
    ROUND(median_duration::numeric, 2),
    ROUND(p95_duration::numeric, 2),
    cnt
FROM duration_stats
ON CONFLICT (studio_id, week_start, stage_name) DO UPDATE SET
    avg_duration_hours = EXCLUDED.avg_duration_hours,
    median_duration_hours = EXCLUDED.median_duration_hours,
    p95_duration_hours = EXCLUDED.p95_duration_hours,
    leads_count = EXCLUDED.leads_count,
    loaded_at = NOW();

-- ============================================================
-- 3. historical_funnel — срез воронки на каждую дату
-- Позволяет ответить: "сколько лидов было в статусе X на дату Y"
-- ============================================================
INSERT INTO metrics.historical_funnel (
    studio_id,
    snapshot_date,
    stage_name,
    lead_count
)
WITH date_range AS (
    SELECT generate_series(
        COALESCE(%(period_start)s::date, NOW()::date - '30 days'::interval),
        COALESCE(%(period_end)s::date, NOW()::date),
        '1 day'::interval
    )::date AS snapshot_date
),
-- Для каждой даты считаем сколько лидов было в каждом статусе
funnel_per_day AS (
    SELECT
        d.snapshot_date,
        s.stage_name,
        COUNT(*) AS lead_count
    FROM date_range d
    JOIN staging.lead_snapshots s
        ON s.valid_from <= d.snapshot_date
        AND (s.valid_to IS NULL OR s.valid_to > d.snapshot_date)
        AND s.studio_id = %(studio_id)s
    GROUP BY d.snapshot_date, s.stage_name
)
SELECT
    %(studio_id)s,
    snapshot_date,
    stage_name,
    lead_count
FROM funnel_per_day
ON CONFLICT (studio_id, snapshot_date, stage_name) DO UPDATE SET
    lead_count = EXCLUDED.lead_count,
    loaded_at = NOW();

-- ============================================================
-- 4. Обновление consolidated метрик (studio_id = 'all')
-- Суммируем по всем студиям
-- ============================================================

-- 4.1 funnel_transitions consolidated
INSERT INTO metrics.funnel_transitions (
    studio_id,
    transition_date,
    stage_from,
    stage_to,
    lead_count,
    avg_duration_hours
)
SELECT
    'all',
    transition_date,
    stage_from,
    stage_to,
    SUM(lead_count),
    AVG(avg_duration_hours)
FROM metrics.funnel_transitions
WHERE studio_id != 'all'
  AND (%(period_start)s::timestamptz IS NULL OR transition_date >= %(period_start)s::date)
  AND (%(period_end)s::timestamptz IS NULL OR transition_date <= %(period_end)s::date)
GROUP BY transition_date, stage_from, stage_to
ON CONFLICT (studio_id, transition_date, stage_from, stage_to) DO UPDATE SET
    lead_count = EXCLUDED.lead_count,
    avg_duration_hours = EXCLUDED.avg_duration_hours,
    loaded_at = NOW();

-- 4.2 lead_stage_durations consolidated
INSERT INTO metrics.lead_stage_durations (
    studio_id,
    week_start,
    stage_name,
    avg_duration_hours,
    median_duration_hours,
    p95_duration_hours,
    leads_count
)
SELECT
    'all',
    week_start,
    stage_name,
    AVG(avg_duration_hours),
    AVG(median_duration_hours),
    AVG(p95_duration_hours),
    SUM(leads_count)
FROM metrics.lead_stage_durations
WHERE studio_id != 'all'
  AND (%(period_start)s::timestamptz IS NULL OR week_start >= %(period_start)s::date)
  AND (%(period_end)s::timestamptz IS NULL OR week_start <= %(period_end)s::date)
GROUP BY week_start, stage_name
ON CONFLICT (studio_id, week_start, stage_name) DO UPDATE SET
    avg_duration_hours = EXCLUDED.avg_duration_hours,
    median_duration_hours = EXCLUDED.median_duration_hours,
    p95_duration_hours = EXCLUDED.p95_duration_hours,
    leads_count = EXCLUDED.leads_count,
    loaded_at = NOW();

-- 4.3 historical_funnel consolidated
INSERT INTO metrics.historical_funnel (
    studio_id,
    snapshot_date,
    stage_name,
    lead_count
)
SELECT
    'all',
    snapshot_date,
    stage_name,
    SUM(lead_count)
FROM metrics.historical_funnel
WHERE studio_id != 'all'
  AND (%(period_start)s::timestamptz IS NULL OR snapshot_date >= %(period_start)s::date)
  AND (%(period_end)s::timestamptz IS NULL OR snapshot_date <= %(period_end)s::date)
GROUP BY snapshot_date, stage_name
ON CONFLICT (studio_id, snapshot_date, stage_name) DO UPDATE SET
    lead_count = EXCLUDED.lead_count,
    loaded_at = NOW();
