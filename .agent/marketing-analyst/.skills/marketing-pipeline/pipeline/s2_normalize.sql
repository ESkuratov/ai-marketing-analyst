-- S2: Normalize — нормализация и дедупликация лидов
-- Читает: raw.amo_leads, raw.yc_visits, raw.gs_expenses
-- Пишет:  staging.leads_normalized
-- Параметр: %(studio_id)s (подставляется в run_pipeline.py)

-- ============================================================
-- 1. Нормализация лидов из AMO CRM
-- ============================================================
INSERT INTO staging.leads_normalized (
    studio_id, lead_id, source, status, funnel_stage,
    utm_source, utm_campaign, utm_medium, utm_content, utm_term,
    created_at, updated_at, closed_at,
    amount, raw_amo_id,
    pipeline_id, stage_id,
    phone_valid, ad_channel_unknown
)
SELECT
    %(studio_id)s,
    amo.id,
    'amo',
    amo.status,
    CASE amo.stage_id
        WHEN 74087430 THEN 'new'          -- Неразобранное
        WHEN 74087434 THEN 'new'          -- НОВАЯ ЗАЯВКА
        WHEN 74087582 THEN 'no_answer'    -- НЕ ВЗЯЛИ ТРУБКУ Рязанский
        WHEN 84866066 THEN 'no_answer'    -- не взяли трубку люблино
        WHEN 84866070 THEN 'negotiation'  -- ПЕРЕГОВОРЫ Люблино
        WHEN 74087586 THEN 'negotiation'  -- ПЕРЕГОВОРЫ Рязанский
        WHEN 74087590 THEN 'appointment'  -- НАЗНАЧЕН ВИЗИТ
        WHEN 74087594 THEN 'no_show'      -- НЕ ПРИШЛА НА СЕАНС
        WHEN 84237074 THEN 'deposit'      -- внесла залог
        WHEN 74087598 THEN 'not_bought'   -- НЕ КУПИЛА
        WHEN 83303646 THEN 'lapsed'       -- НЕ ПРОДЛИЛА
        WHEN 84237070 THEN 'occasional'   -- Ходит разово
        WHEN 142      THEN 'success'      -- Успешно реализовано
        WHEN 143      THEN 'closed'       -- Закрыто и не реализовано
        ELSE 'unknown'
    END AS funnel_stage,

    COALESCE(NULLIF(amo.utm_source, ''), 'direct'),
    amo.utm_campaign,
    amo.utm_medium,
    amo.utm_content,
    amo.utm_term,

    amo.created_at,
    amo.updated_at,
    amo.closed_at,

    amo.price,
    amo.id,

    amo.pipeline_id,
    amo.stage_id,

    CASE
        WHEN amo.client_phone IS NULL THEN FALSE
        WHEN length(regexp_replace(amo.client_phone, '\D', '', 'g')) < 10 THEN FALSE
        WHEN regexp_replace(amo.client_phone, '\D', '', 'g') ~ '^7?0{10}$' THEN FALSE
        WHEN regexp_replace(amo.client_phone, '\D', '', 'g') ~ '^7?(\d)\1{9}$' THEN FALSE
        ELSE TRUE
    END AS phone_valid,

    CASE
        WHEN COALESCE(NULLIF(amo.utm_source, ''), 'direct') = 'direct'
             AND amo.stage_id IN (74087434, 74087430) THEN TRUE
        ELSE FALSE
    END AS ad_channel_unknown

FROM raw.amo_leads amo
WHERE amo.studio_id = %(studio_id)s
  AND (%(period_start)s::timestamptz IS NULL OR amo.created_at >= %(period_start)s::timestamptz)
  AND (%(period_end)s::timestamptz IS NULL OR amo.created_at < %(period_end)s::timestamptz)
ON CONFLICT (studio_id, lead_id, source) DO NOTHING;

-- ============================================================
-- 2. Нормализация визитов из YClients
-- ============================================================
INSERT INTO staging.leads_normalized (
    studio_id, lead_id, source, status, funnel_stage,
    utm_source,
    created_at, updated_at,
    yc_booking_id, booking_date, visit_date, visit_status,
    amount, is_first_visit,
    raw_yc_id,
    phone_valid, ad_channel_unknown
)
SELECT
    %(studio_id)s,
    yv.id,
    'yclients',
    yv.status,
    CASE yv.status
        WHEN 'visited' THEN 'completed'
        WHEN 'not_visited' THEN 'no_show'
        WHEN 'canceled' THEN 'canceled'
        ELSE 'unknown'
    END,

    'direct',  -- YClients не хранит UTM

    yv.date + COALESCE(yv.time, '00:00'::time),
    yv.date + COALESCE(yv.time, '00:00'::time),

    yv.id,
    yv.date,
    CASE WHEN yv.status = 'visited' THEN yv.date END,
    yv.status,

    yv.sum,
    yv.is_first_visit,

    yv.id,

    TRUE AS phone_valid,
    FALSE AS ad_channel_unknown
FROM raw.yc_visits yv
WHERE yv.studio_id = %(studio_id)s
  AND (%(period_start)s::date IS NULL OR yv.date >= %(period_start)s::date)
  AND (%(period_end)s::date IS NULL OR yv.date < %(period_end)s::date)
ON CONFLICT (studio_id, lead_id, source) DO NOTHING;

-- ============================================================
-- 2b. Нормализация лидов из Google Sheets (рекламные каналы)
-- ============================================================
INSERT INTO staging.leads_normalized (
    studio_id, lead_id, source, status, funnel_stage,
    utm_source, utm_campaign, utm_medium,
    created_at, updated_at,
    raw_amo_id,
    phone_valid, ad_channel_unknown
)
SELECT
    %(studio_id)s,
    gs.id,
    'gsheets',
    'new',
    CASE WHEN gs.created_at >= NOW() - interval '1 day' THEN 'new' ELSE 'pending' END,

    COALESCE(NULLIF(gs.utm_source, ''), 'direct'),
    gs.utm_campaign,
    'social',

    gs.created_at,
    gs.created_at,

    gs.id,

    TRUE AS phone_valid,
    FALSE AS ad_channel_unknown
FROM raw.gsheets_leads gs
WHERE gs.studio_id = %(studio_id)s
  AND (%(period_start)s::timestamptz IS NULL OR gs.created_at >= %(period_start)s::timestamptz)
  AND (%(period_end)s::timestamptz IS NULL OR gs.created_at < %(period_end)s::timestamptz)
ON CONFLICT (studio_id, lead_id, source) DO NOTHING;

-- ============================================================
-- 3. Обогащение: связь AMO-лидов с YClients-записями
--    (по телефону клиента — самый надёжный кросс-источник)
--    Берёт последний визит из YClients по номеру телефона.
-- ============================================================
UPDATE staging.leads_normalized ln
SET
    yc_booking_id = yv.id,
    booking_date  = yv.date,
    visit_date    = CASE WHEN yv.status = 'visited' THEN yv.date END,
    visit_status  = yv.status,
    amount        = COALESCE(ln.amount, yv.sum),
    is_first_visit = yv.is_first_visit,
    is_repeat     = NOT yv.is_first_visit
FROM raw.amo_leads amo
JOIN (
    SELECT DISTINCT ON (yv.client_phone) yv.*
    FROM raw.yc_visits yv
    WHERE yv.studio_id = %(studio_id)s
    ORDER BY yv.client_phone, yv.date DESC NULLS LAST, yv.time DESC NULLS LAST
) yv ON yv.client_phone = amo.client_phone
WHERE ln.studio_id = %(studio_id)s
  AND ln.raw_amo_id = amo.id
  AND ln.source = 'amo'
  AND ln.yc_booking_id IS NULL;

-- ============================================================
-- 3b. Обогащение: связь AMO-лидов с Google Sheets (рекламные каналы)
--     Если телефон найден в GS — записать utm_source/utm_campaign в лид.
--     Снимает флаг ad_channel_unknown.
-- ============================================================
UPDATE staging.leads_normalized ln
SET
    utm_source   = COALESCE(NULLIF(gs.utm_source, ''), ln.utm_source),
    utm_campaign = COALESCE(NULLIF(gs.utm_campaign, ''), ln.utm_campaign),
    ad_channel_unknown = FALSE
FROM raw.amo_leads amo
JOIN raw.gsheets_leads gs
    ON gs.studio_id = amo.studio_id
   AND regexp_replace(gs.client_phone, '\D', '', 'g')
     = regexp_replace(amo.client_phone, '\D', '', 'g')
WHERE ln.studio_id = %(studio_id)s
  AND ln.raw_amo_id = amo.id
  AND ln.source = 'amo'
  AND ln.funnel_stage = 'new'
  AND ln.ad_channel_unknown = TRUE;

-- ============================================================
-- 4. Дедупликация: удаление дублей по lead_id в пределах студии
--    (оставляем самую свежую запись)
-- ============================================================
WITH dedup AS (
    DELETE FROM staging.leads_normalized ln
    USING (
        SELECT lead_id, source, MAX(created_at) as max_created
        FROM staging.leads_normalized
        WHERE studio_id = %(studio_id)s
        GROUP BY lead_id, source
        HAVING COUNT(*) > 1
    ) dup
    WHERE ln.studio_id = %(studio_id)s
      AND ln.lead_id = dup.lead_id
      AND ln.source = dup.source
      AND ln.created_at < dup.max_created
    RETURNING 1
)
SELECT COUNT(*) AS deleted_duplicates FROM dedup;
