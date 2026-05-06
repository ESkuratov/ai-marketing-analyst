-- S5b: Reports — выборка данных для отчётов
-- Читает: metrics.daily_summary, metrics.weekly_funnel,
--          metrics.monthly_cohorts, metrics.channel_roi,
--          ops.active_alerts
-- Результат: SELECT (не пишет, используется генератором отчётов)
-- Параметр: %(studio_id)s

-- ============================================================
-- 1. Ежедневный отчёт (22:30)
-- ============================================================
-- 1a. Сводка за сегодня
SELECT
    'daily_summary' AS report_section,
    ds.date,
    ds.leads_count,
    ds.bookings_count,
    ds.visits_count,
    ds.revenue,
    ds.conversion_lead_to_booking,
    ds.conversion_booking_to_visit,
    ds.no_show_rate,
    ds.first_visit_count,
    ds.repeat_visit_count
FROM metrics.daily_summary ds
WHERE ds.studio_id = %(studio_id)s
  AND ds.channel = 'all'
  AND ds.date >= COALESCE(%(period_start)s::date, NOW()::date)
  AND ds.date <= COALESCE(%(period_end)s::date, NOW()::date)
ORDER BY ds.date DESC;

-- 1b. Активные алерты
SELECT
    'active_alerts' AS report_section,
    aa.alert_type,
    aa.severity,
    aa.metric_name,
    aa.metric_value,
    aa.threshold,
    aa.recommendation
FROM ops.active_alerts aa
WHERE aa.studio_id = %(studio_id)s
  AND aa.resolved_at IS NULL
ORDER BY aa.severity DESC, aa.created_at DESC;

-- ============================================================
-- 2. Еженедельная воронка (Пн 14:00)
-- ============================================================
-- 2a. Воронка per-studio
SELECT
    'weekly_funnel' AS report_section,
    wf.week_start,
    wf.stage_name,
    wf.lead_count,
    wf.conversion
FROM metrics.weekly_funnel wf
WHERE wf.studio_id = %(studio_id)s
  AND wf.week_start >= COALESCE(%(period_start)s::date, NOW() - '30 days'::interval)
ORDER BY wf.week_start DESC, wf.stage_name;

-- 2b. Топ-5 каналов по лидам
SELECT
    'top_channels' AS report_section,
    COALESCE(NULLIF(ln.utm_source, ''), 'direct') AS channel,
    COUNT(DISTINCT ln.lead_id) AS leads,
    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.yc_booking_id IS NOT NULL) AS bookings,
    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.visit_status = 'visited') AS visits
FROM staging.leads_normalized ln
WHERE ln.studio_id = %(studio_id)s
  AND ln.created_at >= COALESCE(%(period_start)s, NOW() - '7 days'::interval)
GROUP BY channel
ORDER BY leads DESC
LIMIT 5;

-- ============================================================
-- 3. Клиентская база (1 число)
-- ============================================================
-- 3a. Сводка по клиентам
SELECT
    'client_base' AS report_section,
    COUNT(DISTINCT ln.lead_id) AS total_clients,
    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.is_first_visit) AS new_clients,
    COUNT(DISTINCT ln.lead_id) FILTER (
        WHERE ln.is_repeat AND ln.visit_status = 'visited'
    ) AS returning_clients,
    COUNT(DISTINCT ln.lead_id) FILTER (
        WHERE ln.visit_status = 'no_show'
    ) AS no_show_clients
FROM staging.leads_normalized ln
WHERE ln.studio_id = %(studio_id)s
  AND ln.created_at >= COALESCE(
      %(period_start)s,
      date_trunc('month', NOW())::date
  );

-- ============================================================
-- 4. Рейтинг абонементов (крайний день)
-- ============================================================
-- 4a. Сводка по абонементам (заглушка — требует данных о продажах)
SELECT
    'abonement_ranking' AS report_section,
    'N/A' AS abonement_type,
    0 AS count
LIMIT 0;

-- ============================================================
-- 5. Каналы CAC/LTV/ROMI (1 число)
-- ============================================================
-- 5a. ROI по каналам
SELECT
    'channel_roi' AS report_section,
    cr.channel,
    cr.cost,
    cr.revenue,
    cr.leads_count,
    cr.bookings_count,
    cr.cac,
    cr.ltv,
    cr.romi
FROM metrics.channel_roi cr
WHERE cr.studio_id = %(studio_id)s
  AND cr.month >= COALESCE(
      (%(period_start)s)::date,
      date_trunc('month', NOW())::date
  )
ORDER BY cr.cost DESC;

-- ============================================================
-- 6. Consolidated (studio_id = 'all') — сводка по сети
-- ============================================================
SELECT
    'network_summary' AS report_section,
    COUNT(DISTINCT ln.lead_id) AS total_leads,
    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.yc_booking_id IS NOT NULL) AS total_bookings,
    COUNT(DISTINCT ln.lead_id) FILTER (WHERE ln.visit_status = 'visited') AS total_visits
FROM staging.leads_normalized ln
WHERE ln.studio_id IN (
    SELECT studio_id FROM ops.studios WHERE is_active = TRUE
)
  AND ln.created_at >= COALESCE(%(period_start)s, NOW() - '1 day'::interval);

-- ============================================================
-- 7. Список клиентов с залогом (Stage 8)
-- ============================================================
SELECT
    'deposit_clients' AS report_section,
    amo.client_name,
    amo.client_phone,
    amo.price AS deposit_sum,
    COALESCE(yc_pay.yc_sum, 0) AS paid_sum,
    (amo.price - COALESCE(yc_pay.yc_sum, 0)) AS debt_sum
FROM raw.amo_leads amo
LEFT JOIN (
    SELECT client_phone, studio_id, SUM(sum) AS yc_sum
    FROM raw.yc_visits
    WHERE studio_id = %(studio_id)s
    GROUP BY client_phone, studio_id
) yc_pay ON yc_pay.studio_id = amo.studio_id
    AND yc_pay.client_phone = amo.client_phone
WHERE amo.studio_id = %(studio_id)s
  AND amo.stage_id = 84237074
ORDER BY debt_sum DESC NULLS LAST;

-- ============================================================
-- 8. Список непродлившихся клиентов с историей услуг (Stage 10)
-- ============================================================
SELECT
    'lapsed_clients' AS report_section,
    amo.client_name,
    amo.client_phone,
    last_visit.last_date AS last_visit_date,
    last_visit.last_service_name,
    last_visit.last_master_name,
    last_visit.last_comment,
    visit_history.visit_count,
    visit_history.services_json
FROM raw.amo_leads amo
LEFT JOIN LATERAL (
    SELECT yv.date AS last_date,
           yv.service_name AS last_service_name,
           yv.master_name AS last_master_name,
           yv.comment AS last_comment
    FROM raw.yc_visits yv
    WHERE yv.studio_id = %(studio_id)s
      AND yv.client_phone = amo.client_phone
    ORDER BY yv.date DESC NULLS LAST
    LIMIT 1
) last_visit ON TRUE
LEFT JOIN LATERAL (
    SELECT COUNT(*) AS visit_count,
           jsonb_agg(jsonb_build_object(
               'date', yv.date,
               'service', yv.service_name,
               'master', yv.master_name,
               'comment', yv.comment
           ) ORDER BY yv.date DESC) AS services_json
    FROM raw.yc_visits yv
    WHERE yv.studio_id = %(studio_id)s
      AND yv.client_phone = amo.client_phone
) visit_history ON TRUE
WHERE amo.studio_id = %(studio_id)s
  AND amo.stage_id = 83303646
ORDER BY last_visit.last_date ASC NULLS LAST;

-- ============================================================
-- 9. Аналитика закрытых без продажи (Stage 12)
-- ============================================================
SELECT
    'closed_lost_analytics' AS report_section,
    COALESCE(NULLIF(amo.utm_source, ''), 'direct') AS channel,
    COALESCE(NULLIF(amo.utm_campaign, ''), 'none') AS campaign,
    COUNT(*) AS closed_count,
    ROUND(AVG(amo.price), 2) AS avg_price,
    ROUND(AVG(EXTRACT(EPOCH FROM (amo.closed_at - amo.created_at)) / 86400), 1) AS avg_duration_days,
    SUM(amo.price) AS total_lost_revenue
FROM raw.amo_leads amo
WHERE amo.studio_id = %(studio_id)s
  AND amo.stage_id = 143
  AND (%(period_start)s::timestamptz IS NULL OR amo.closed_at >= %(period_start)s::timestamptz)
  AND (%(period_end)s::timestamptz IS NULL OR amo.closed_at < %(period_end)s::timestamptz)
GROUP BY channel, campaign
ORDER BY closed_count DESC;
