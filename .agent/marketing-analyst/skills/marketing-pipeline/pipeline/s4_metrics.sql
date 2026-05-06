-- S4: Metrics — расчёт конверсий, CAC, LTV, ROMI
-- Читает: staging.leads_normalized, raw.gs_expenses
-- Пишет:  metrics.daily_summary, metrics.weekly_funnel,
--          metrics.monthly_cohorts, metrics.channel_roi
-- Параметр: %(studio_id)s

-- ============================================================
-- 1. daily_summary — конверсии по дням
-- ============================================================
INSERT INTO metrics.daily_summary (
    studio_id, date, channel,
    leads_count, bookings_count, visits_count,
    abonements_sold, revenue,
    conversion_lead_to_booking, conversion_booking_to_visit,
    conversion_visit_to_abon,
    no_show_count, no_show_rate,
    canceled_count, canceled_rate,
    first_visit_count, repeat_visit_count
)
SELECT
    %(studio_id)s,
    d.date,
    COALESCE(ln.utm_source, 'all') AS channel,

    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.source = 'amo') AS leads_count,
    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.yc_booking_id IS NOT NULL) AS bookings_count,
    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.visit_status = 'visited') AS visits_count,
    0 AS abonements_sold,  -- требует данных из кассы
    COALESCE(SUM(ln.amount) FILTER (WHERE ln.visit_status = 'visited'), 0) AS revenue,

    -- Конверсии
    CASE
        WHEN COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.source = 'amo') > 0
        THEN ROUND(
            COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.yc_booking_id IS NOT NULL)::numeric
            / COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.source = 'amo') * 100, 2
        )
    END AS conversion_lead_to_booking,

    CASE
        WHEN COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.yc_booking_id IS NOT NULL) > 0
        THEN ROUND(
            COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.visit_status = 'visited')::numeric
            / COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.yc_booking_id IS NOT NULL) * 100, 2
        )
    END AS conversion_booking_to_visit,

    NULL AS conversion_visit_to_abon,  -- требует данных о продажах

    -- Качество
    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.visit_status = 'no_show') AS no_show_count,
    CASE
        WHEN COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.yc_booking_id IS NOT NULL) > 0
        THEN ROUND(
            COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.visit_status = 'no_show')::numeric
            / COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.yc_booking_id IS NOT NULL) * 100, 2
        )
    END AS no_show_rate,

    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.visit_status = 'canceled') AS canceled_count,
    NULL AS canceled_rate,

    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.is_first_visit) AS first_visit_count,
    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.is_repeat) AS repeat_visit_count

FROM (
    SELECT generate_series(
        COALESCE(%(period_start)s::date, NOW() - '30 days'::interval),
        COALESCE(%(period_end)s::date, NOW()::date),
        '1 day'::interval
    )::date AS date
) d
LEFT JOIN staging.leads_normalized ln
    ON ln.studio_id = %(studio_id)s
    AND ln.created_at::date = d.date
GROUP BY d.date, COALESCE(ln.utm_source, 'all')
ORDER BY d.date DESC
ON CONFLICT (studio_id, date, channel) DO NOTHING;

-- ============================================================
-- 2. weekly_funnel — воронка по неделям
-- ============================================================
INSERT INTO metrics.weekly_funnel (
    studio_id, week_start, stage_name, lead_count, conversion, avg_duration
)
SELECT
    %(studio_id)s,
    date_trunc('week', ln.created_at)::date AS week_start,
    ln.funnel_stage,
    COUNT(DISTINCT ln.lead_id) AS lead_count,
    NULL AS conversion,  -- считается после заполнения всех этапов
    NULL AS avg_duration
FROM staging.leads_normalized ln
WHERE ln.studio_id = %(studio_id)s
  AND (%(period_start)s::timestamptz IS NULL OR ln.created_at >= %(period_start)s::timestamptz)
  AND (%(period_end)s::timestamptz IS NULL OR ln.created_at < %(period_end)s::timestamptz)
GROUP BY date_trunc('week', ln.created_at), ln.funnel_stage
ORDER BY week_start DESC
ON CONFLICT (studio_id, week_start, stage_name) DO NOTHING;

-- ============================================================
-- 3. monthly_cohorts — когортный анализ
-- ============================================================
INSERT INTO metrics.monthly_cohorts (
    studio_id, month, cohort_month, client_count,
    active_clients, lost_clients, returned_clients,
    revenue, cac, ltv, romi
)
WITH monthly_leads AS (
    SELECT
        date_trunc('month', created_at)::date AS month,
        date_trunc('month', created_at - interval '1 month')::date AS prev_month,
        lead_id,
        source,
        visit_status,
        amount,
        is_first_visit
    FROM staging.leads_normalized
    WHERE studio_id = %(studio_id)s
),
cohorts AS (
    SELECT
        month,
        month AS cohort_month,
        COUNT(DISTINCT lead_id) AS client_count,
        COUNT(DISTINCT lead_id) FILTER (
            WHERE visit_status = 'visited' AND is_first_visit
        ) AS new_active,
        COUNT(DISTINCT lead_id) FILTER (
            WHERE visit_status = 'visited'
        ) AS active_clients,
        0 AS lost_clients,
        0 AS returned_clients,
        COALESCE(SUM(amount) FILTER (WHERE visit_status = 'visited'), 0) AS revenue
    FROM monthly_leads
    GROUP BY month
)
SELECT
    %(studio_id)s,
    cohort.month,
    cohort.cohort_month,
    cohort.client_count,
    cohort.active_clients,
    0 AS lost_clients,       -- требует сравнения с предыдущими месяцами
    0 AS returned_clients,   -- требует анализа перерывов > 60 дней
    cohort.revenue,
    NULL AS cac,    -- требует данных о расходах из raw.gs_expenses
    NULL AS ltv,    -- рассчитывается после 3+ месяцев данных
    NULL AS romi
FROM cohorts cohort
ON CONFLICT (studio_id, month, cohort_month) DO NOTHING;

-- ============================================================
-- 4. channel_roi — ROI по каналам
-- ============================================================
INSERT INTO metrics.channel_roi (
    studio_id, month, channel, channel_type,
    cost, revenue, leads_count, bookings_count, visits_count,
    cac, ltv, romi
)
SELECT
    %(studio_id)s,
    date_trunc('month', ln.created_at)::date AS month,
    COALESCE(NULLIF(ln.utm_source, ''), 'direct') AS channel,
    -- channel_type: маппинг на основе названия канала
    CASE
        WHEN ln.utm_source IN ('yandex_cpc', 'vk_ads', 'google_ads') THEN 'paid'
        WHEN ln.utm_source IN ('vk', 'instagram', 'telegram') THEN 'social'
        WHEN ln.utm_source IN ('seo', 'direct', 'organic') THEN 'organic'
        WHEN ln.utm_source IN ('referral', 'partner') THEN 'referral'
        ELSE 'unknown'
    END AS channel_type,

    -- cost: из raw.gs_expenses
    COALESCE(SUM(ge.amount), 0) AS cost,

    -- revenue: сумма визитов
    COALESCE(SUM(ln.amount) FILTER (WHERE ln.visit_status = 'visited'), 0) AS revenue,

    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.source = 'amo') AS leads_count,
    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.yc_booking_id IS NOT NULL) AS bookings_count,
    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.visit_status = 'visited') AS visits_count,

    -- CAC = cost / количество новых клиентов
    CASE
        WHEN COUNT(DISTINCT ln.lead_id) FILTER (
            WHERE ln.is_first_visit AND ln.visit_status = 'visited'
        ) > 0
        THEN ROUND(
            COALESCE(SUM(ge.amount), 0)
            / COUNT(DISTINCT ln.lead_id) FILTER (
                WHERE ln.is_first_visit AND ln.visit_status = 'visited'
            ), 2
        )
    END AS cac,

    NULL AS ltv,  -- требует истории > 3 месяцев

    -- ROMI = (revenue - cost) / cost * 100
    CASE
        WHEN COALESCE(SUM(ge.amount), 0) > 0
        THEN ROUND(
            (COALESCE(SUM(ln.amount) FILTER (WHERE ln.visit_status = 'visited'), 0)
             - COALESCE(SUM(ge.amount), 0))
            / COALESCE(SUM(ge.amount), 1) * 100, 2
        )
    END AS romi

FROM staging.leads_normalized ln
LEFT JOIN raw.gs_expenses ge
    ON ge.studio_id = %(studio_id)s
    AND ge.channel = ln.utm_source
    AND date_trunc('month', ge.date) = date_trunc('month', ln.created_at)
WHERE ln.studio_id = %(studio_id)s
  AND (%(period_start)s::timestamptz IS NULL OR ln.created_at >= %(period_start)s::timestamptz)
  AND (%(period_end)s::timestamptz IS NULL OR ln.created_at < %(period_end)s::timestamptz)
GROUP BY date_trunc('month', ln.created_at), COALESCE(NULLIF(ln.utm_source, ''), 'direct'),
         CASE
             WHEN ln.utm_source IN ('yandex_cpc', 'vk_ads', 'google_ads') THEN 'paid'
             WHEN ln.utm_source IN ('vk', 'instagram', 'telegram') THEN 'social'
             WHEN ln.utm_source IN ('seo', 'direct', 'organic') THEN 'organic'
             WHEN ln.utm_source IN ('referral', 'partner') THEN 'referral'
             ELSE 'unknown'
         END
ON CONFLICT (studio_id, month, channel) DO UPDATE SET
    channel_type = EXCLUDED.channel_type,
    visits_count = EXCLUDED.visits_count,
    updated_at = NOW();
