-- S2b: Client profiles — создание/обновление профилей клиентов
-- Читает: staging.leads_normalized, raw.amo_leads, raw.yc_visits, raw.gsheets_leads
-- Пишет:  staging.client_profiles
--         обновляет staging.leads_normalized.client_id
-- Параметр: %(studio_id)s

-- ============================================================
-- 1. Создание профилей для клиентов с телефоном
--    Матчинг по номеру телефона (нормализованному)
-- ============================================================

-- 1a. Из AMO
INSERT INTO staging.client_profiles (studio_id, client_phone, client_name, first_source)
SELECT
    amo.studio_id,
    amo.client_phone,
    MIN(amo.client_name) AS client_name,
    'amo' AS first_source
FROM raw.amo_leads amo
WHERE amo.studio_id = %(studio_id)s
  AND amo.client_phone IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM staging.client_profiles cp
      WHERE cp.studio_id = amo.studio_id AND cp.client_phone = amo.client_phone
  )
GROUP BY amo.studio_id, amo.client_phone;

-- 1b. Из YClients
INSERT INTO staging.client_profiles (studio_id, client_phone, client_name, first_source)
SELECT
    yv.studio_id,
    yv.client_phone,
    MIN(yv.client_name) AS client_name,
    'yclients' AS first_source
FROM raw.yc_visits yv
WHERE yv.studio_id = %(studio_id)s
  AND yv.client_phone IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM staging.client_profiles cp
      WHERE cp.studio_id = yv.studio_id AND cp.client_phone = yv.client_phone
  )
GROUP BY yv.studio_id, yv.client_phone;

-- 1c. Из Google Sheets (лиды)
INSERT INTO staging.client_profiles (studio_id, client_phone, client_name, first_source)
SELECT
    gs.studio_id,
    gs.client_phone,
    MIN(gs.client_name) AS client_name,
    'gsheets' AS first_source
FROM raw.gsheets_leads gs
WHERE gs.studio_id = %(studio_id)s
  AND gs.client_phone IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM staging.client_profiles cp
      WHERE cp.studio_id = gs.studio_id AND cp.client_phone = gs.client_phone
  )
GROUP BY gs.studio_id, gs.client_phone;

-- ============================================================
-- 2. Обновление client_id в leads_normalized
-- ============================================================

-- 2a. AMO-лиды с телефоном
UPDATE staging.leads_normalized ln
SET client_id = cp.client_id
FROM raw.amo_leads amo
JOIN staging.client_profiles cp ON cp.studio_id = amo.studio_id AND cp.client_phone = amo.client_phone
WHERE ln.studio_id = %(studio_id)s
  AND ln.raw_amo_id = amo.id
  AND ln.source = 'amo'
  AND ln.client_id IS NULL;

-- 2b. YClients-визиты с телефоном
UPDATE staging.leads_normalized ln
SET client_id = cp.client_id
FROM raw.yc_visits yv
JOIN staging.client_profiles cp ON cp.studio_id = yv.studio_id AND cp.client_phone = yv.client_phone
WHERE ln.studio_id = %(studio_id)s
  AND ln.raw_yc_id = yv.id
  AND ln.source = 'yclients'
  AND ln.client_id IS NULL;

-- 2c. GSheets-лиды с телефоном
UPDATE staging.leads_normalized ln
SET client_id = cp.client_id
FROM raw.gsheets_leads gs
JOIN staging.client_profiles cp ON cp.studio_id = gs.studio_id AND cp.client_phone = gs.client_phone
WHERE ln.studio_id = %(studio_id)s
  AND ln.raw_amo_id = gs.id
  AND ln.source = 'gsheets'
  AND ln.client_id IS NULL;

-- ============================================================
-- 3. Агрегация: обновление профилей из leads_normalized
-- ============================================================
UPDATE staging.client_profiles cp
SET
    first_seen_at  = sub.first_seen,
    last_seen_at   = sub.last_seen,
    total_visits   = sub.total_visits,
    total_revenue  = sub.total_revenue,
    updated_at     = NOW()
FROM (
    SELECT
        ln.client_id,
        MIN(ln.created_at) AS first_seen,
        MAX(ln.created_at) AS last_seen,
        COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.visit_status = 'visited') AS total_visits,
        COALESCE(SUM(ln.amount) FILTER (WHERE ln.visit_status = 'visited'), 0) AS total_revenue
    FROM staging.leads_normalized ln
    WHERE ln.studio_id = %(studio_id)s
      AND ln.client_id IS NOT NULL
    GROUP BY ln.client_id
) sub
WHERE cp.client_id = sub.client_id;

-- Обновляем funnel_stage с приоритетом:
-- success > deposit > completed > appointment > occasional > negotiation > no_answer > new > pending > closed > not_bought > lapsed > no_show > canceled > unknown
UPDATE staging.client_profiles cp
SET funnel_stage = sub.best_stage
FROM (
    SELECT
        ln.client_id,
        CASE
            WHEN bool_or(ln.funnel_stage = 'success')     THEN 'success'
            WHEN bool_or(ln.funnel_stage = 'deposit')     THEN 'deposit'
            WHEN bool_or(ln.funnel_stage = 'completed')   THEN 'completed'
            WHEN bool_or(ln.funnel_stage = 'appointment') THEN 'appointment'
            WHEN bool_or(ln.funnel_stage = 'occasional')  THEN 'occasional'
            WHEN bool_or(ln.funnel_stage = 'negotiation') THEN 'negotiation'
            WHEN bool_or(ln.funnel_stage = 'no_answer')   THEN 'no_answer'
            WHEN bool_or(ln.funnel_stage = 'new')         THEN 'new'
            WHEN bool_or(ln.funnel_stage = 'pending')     THEN 'pending'
            WHEN bool_or(ln.funnel_stage = 'closed')      THEN 'closed'
            WHEN bool_or(ln.funnel_stage = 'not_bought')  THEN 'not_bought'
            WHEN bool_or(ln.funnel_stage = 'lapsed')      THEN 'lapsed'
            WHEN bool_or(ln.funnel_stage = 'no_show')     THEN 'no_show'
            WHEN bool_or(ln.funnel_stage = 'canceled')    THEN 'canceled'
            ELSE MAX(ln.funnel_stage)
        END AS best_stage
    FROM staging.leads_normalized ln
    WHERE ln.studio_id = %(studio_id)s
      AND ln.client_id IS NOT NULL
    GROUP BY ln.client_id
) sub
WHERE cp.client_id = sub.client_id;
