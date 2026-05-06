"""
report_formatters.py — форматирование отчётов в Telegram Markdown.

Каждая функция принимает список словарей (результат SQL-запроса из s5b_reports.sql)
и возвращает готовый текст сообщения в Telegram MarkdownV2.
"""

from datetime import date, datetime
from typing import Any


def _escape(text: str | None) -> str:
    """Escape специальных символов Telegram MarkdownV2."""
    if text is None:
        return ""
    for ch in r"_*[]()~`>#+-=|{}.!":
        text = str(text).replace(ch, f"\\{ch}")
    return text


def _fmt_num(val: Any) -> str:
    """Форматирование числа."""
    if val is None:
        return "—"
    return _escape(f"{int(val):,}" if isinstance(val, (int, float)) and val == int(val) else f"{val}")


def _fmt_pct(val: Any) -> str:
    """Форматирование процента."""
    if val is None:
        return "—"
    return _escape(f"{val:.1f}%") if isinstance(val, (int, float)) else str(val)


def _fmt_date(d: Any) -> str:
    """Форматирование даты."""
    if d is None:
        return "—"
    if isinstance(d, str):
        d = d[:10]
    return _escape(str(d))


# ============================================================
# Ежедневный отчёт (22:30)
# ============================================================
def daily_report(
    summary_rows: list[dict[str, Any]],
    alert_rows: list[dict[str, Any]],
    studio_name: str = "",
) -> str:
    """Форматировать ежедневный отчёт.

    Args:
        summary_rows: строки из daily_summary
        alert_rows: строки из active_alerts
        studio_name: название студии

    Returns:
        Текст сообщения в Telegram MarkdownV2.
    """
    if not summary_rows:
        summary_rows = [{"date": date.today().isoformat(), "leads_count": 0, "bookings_count": 0,
                         "visits_count": 0, "revenue": 0, "conversion_lead_to_booking": None,
                         "conversion_booking_to_visit": None, "no_show_rate": None,
                         "first_visit_count": 0, "repeat_visit_count": 0}]

    r = summary_rows[0]
    lines = [
        f"*Ежедневный отчёт*{_escape(' — ' + studio_name) if studio_name else ''}",
        f"📅 {_escape(r.get('date', ''))}",
        "",
        "*📊 Показатели за сегодня:*",
        f"▫️ Лиды: `{_fmt_num(r.get('leads_count'))}` → Записи: `{_fmt_num(r.get('bookings_count'))}` → Визиты: `{_fmt_num(r.get('visits_count'))}`",
        f"▫️ Конверсия лид→запись: `{_fmt_pct(r.get('conversion_lead_to_booking'))}`",
        f"▫️ Конверсия запись→визит: `{_fmt_pct(r.get('conversion_booking_to_visit'))}`",
        f"▫️ Выручка: `{_fmt_num(r.get('revenue'))}₽`",
        f"▫️ Новых клиентов: `{_fmt_num(r.get('first_visit_count'))}` | Повторных: `{_fmt_num(r.get('repeat_visit_count'))}`",
        f"▫️ Неявки: `{_fmt_pct(r.get('no_show_rate'))}`",
    ]

    if alert_rows:
        lines += [
            "",
            "*🚨 Активные алерты:*",
        ]
        for a in alert_rows:
            severity_icon = {"critical": "🔴", "warning": "⚠️", "info": "ℹ️"}.get(
                a.get("severity", ""), "•"
            )
            lines.append(
                f"{severity_icon} *{_escape(str(a.get('alert_type', '')))}*: "
                f"{_escape(str(a.get('recommendation', '')))}"
            )

    lines.append("")
    lines.append(f"🕐 {_escape(datetime.now().strftime('%H:%M'))}")
    return "\n".join(lines)


# ============================================================
# Еженедельная воронка (Пн 14:00)
# ============================================================
def weekly_report(
    funnel_rows: list[dict[str, Any]],
    channel_rows: list[dict[str, Any]],
    studio_name: str = "",
) -> str:
    """Форматировать еженедельный отчёт."""
    lines = [
        f"*Еженедельная воронка*{_escape(' — ' + studio_name) if studio_name else ''}",
        f"📅 Неделя {_fmt_date(funnel_rows[0].get('week_start')) if funnel_rows else ''}",
        "",
        "*📊 Воронка продаж:*",
    ]

    # Группировка по week_start
    weeks: dict[str, list[dict]] = {}
    for row in funnel_rows:
        ws = str(row.get("week_start", ""))[:10]
        weeks.setdefault(ws, []).append(row)

    for ws, stages in weeks.items():
        lines.append(f"  *{_escape(ws)}*:")
        for s in stages:
            lines.append(
                f"    ▫️ {_escape(str(s.get('stage_name', '')))}: "
                f"`{_fmt_num(s.get('lead_count'))}` "
                f"({_fmt_pct(s.get('conversion'))})"
            )

    if channel_rows:
        lines += ["", "*📈 Топ каналов:*"]
        for ch in channel_rows:
            lines.append(
                f"  ▫️ *{_escape(str(ch.get('channel', '')))}*: "
                f"{_fmt_num(ch.get('leads'))} лидов → "
                f"{_fmt_num(ch.get('bookings'))} записей → "
                f"{_fmt_num(ch.get('visits'))} визитов"
            )

    lines.append("")
    lines.append(f"🕐 {_escape(datetime.now().strftime('%H:%M'))}")
    return "\n".join(lines)


# ============================================================
# Ежемесячный отчёт (1 число)
# ============================================================
def monthly_report(
    client_rows: list[dict[str, Any]],
    channel_rows: list[dict[str, Any]],
    studio_name: str = "",
) -> str:
    """Форматировать ежемесячный отчёт."""
    lines = [
        f"*Ежемесячный отчёт*{_escape(' — ' + studio_name) if studio_name else ''}",
        f"📅 {_escape(datetime.now().strftime('%B %Y'))}",
        "",
    ]

    if client_rows:
        cr = client_rows[0]
        lines += [
            "*👥 Клиентская база:*",
            f"▫️ Всего клиентов: `{_fmt_num(cr.get('total_clients'))}`",
            f"▫️ Новых: `{_fmt_num(cr.get('new_clients'))}`",
            f"▫️ Вернулись: `{_fmt_num(cr.get('returning_clients'))}`",
            f"▫️ Неявки: `{_fmt_num(cr.get('no_show_clients'))}`",
        ]

    if channel_rows:
        lines += ["", "*📊 ROI по каналам:*"]
        for ch in channel_rows:
            lines += [
                f"  *{_escape(str(ch.get('channel', '')))}*:",
                f"    Затраты: `{_fmt_num(ch.get('cost'))}₽` → Выручка: `{_fmt_num(ch.get('revenue'))}₽`",
                f"    CAC: `{_fmt_num(ch.get('cac'))}₽` | ROMI: `{_fmt_pct(ch.get('romi'))}`",
            ]

    lines.append("")
    lines.append(f"🕐 {_escape(datetime.now().strftime('%H:%M'))}")
    return "\n".join(lines)


# ============================================================
# Сводка по сети (consolidated)
# ============================================================
# ============================================================
# Список клиентов с залогом (Stage 8)
# ============================================================
def deposit_clients_report(rows: list[dict[str, Any]], studio_name: str = "") -> str:
    """Форматировать список клиентов с залогом и суммой долга."""
    lines = [
        f"*Клиенты с залогом*{_escape(' — ' + studio_name) if studio_name else ''}",
        "",
    ]

    if not rows:
        lines.append("Нет клиентов с залогом.")
        return "\n".join(lines)

    total_deposit = 0
    total_debt = 0
    for r in rows:
        deposit = float(r.get("deposit_sum") or 0)
        debt = float(r.get("debt_sum") or 0)
        total_deposit += deposit
        total_debt += debt
        lines.append(
            f"▫️ *{_escape(str(r.get('client_name', '—')))}* "
            f"`{_escape(str(r.get('client_phone', '—')))}`\n"
            f"    Залог: `{_fmt_num(deposit)}₽` | "
            f"Оплачено: `{_fmt_num(r.get('paid_sum'))}₽` | "
            f"Долг: `{_fmt_num(debt)}₽`"
        )

    lines += [
        "",
        f"*Итого:* залогов `{_fmt_num(total_deposit)}₽`, долгов `{_fmt_num(total_debt)}₽`",
    ]
    return "\n".join(lines)


# ============================================================
# Список непродлившихся клиентов (Stage 10)
# ============================================================
def lapsed_clients_report(rows: list[dict[str, Any]], studio_name: str = "") -> str:
    """Форматировать список непродлившихся клиентов с историей услуг."""
    lines = [
        f"*Непродлившиеся клиенты*{_escape(' — ' + studio_name) if studio_name else ''}",
        "",
    ]

    if not rows:
        lines.append("Нет непродлившихся клиентов.")
        return "\n".join(lines)

    for r in rows:
        services = r.get("services_json") or []
        if isinstance(services, str):
            import json
            try:
                services = json.loads(services)
            except (json.JSONDecodeError, TypeError):
                services = []

        visit_count = r.get("visit_count") or 0
        last_comment = r.get("last_comment")

        lines.append(
            f"*{_escape(str(r.get('client_name', '—')))}* "
            f"`{_escape(str(r.get('client_phone', '—')))}`\n"
            f"    Последний визит: {_fmt_date(r.get('last_visit_date'))} | "
            f"Визитов: `{_fmt_num(visit_count)}`"
        )

        if r.get("last_service_name"):
            lines.append(f"    Услуга: {_escape(str(r.get('last_service_name')))} | Мастер: {_escape(str(r.get('last_master_name', '—')))}")

        if last_comment:
            lines.append(f"    Комментарий: {_escape(str(last_comment))}")

        # Последние 3 услуги
        if services:
            recent = services[:3]
            svc_lines = []
            for s in recent:
                svc_lines.append(
                    f"{_fmt_date(s.get('date'))} — {_escape(str(s.get('service', '—')))} ({_escape(str(s.get('master', '—')))})"
                )
            lines.append(f"    История: {', '.join(svc_lines)}")

        lines.append("")

    lines.append(f"Всего: `{len(rows)}` клиентов")
    return "\n".join(lines)


# ============================================================
# Аналитика закрытых без продажи (Stage 12)
# ============================================================
def closed_lost_analytics_report(rows: list[dict[str, Any]], studio_name: str = "") -> str:
    """Форматировать аналитику по закрытым без продажи."""
    lines = [
        f"*Закрыто и не реализовано*{_escape(' — ' + studio_name) if studio_name else ''}",
        "",
    ]

    if not rows:
        lines.append("Нет данных.")
        return "\n".join(lines)

    total_closed = 0
    total_revenue = 0
    for r in rows:
        closed = int(r.get("closed_count") or 0)
        revenue = float(r.get("total_lost_revenue") or 0)
        total_closed += closed
        total_revenue += revenue
        lines.append(
            f"*{_escape(str(r.get('channel', '—')))}* / {_escape(str(r.get('campaign', '—')))}\n"
            f"    Закрыто: `{_fmt_num(closed)}` | "
            f"Средний чек: `{_fmt_num(r.get('avg_price'))}₽` | "
            f"Длительность: `{_fmt_num(r.get('avg_duration_days'))} дн.`\n"
            f"    Потеряно: `{_fmt_num(revenue)}₽`"
        )

    lines += [
        "",
        f"*Итого:* закрыто `{total_closed}`, потерянная выручка `{_fmt_num(total_revenue)}₽`",
    ]
    return "\n".join(lines)


def network_summary_report(network_rows: list[dict[str, Any]]) -> str:
    """Форматировать сводку по сети студий."""
    if not network_rows:
        return "*Сводка по сети*\nНет данных за период."

    nr = network_rows[0]
    return (
        f"*Сводка по сети*\n"
        f"▫️ Всего лидов: `{_fmt_num(nr.get('total_leads'))}`\n"
        f"▫️ Всего записей: `{_fmt_num(nr.get('total_bookings'))}`\n"
        f"▫️ Всего визитов: `{_fmt_num(nr.get('total_visits'))}`"
    )
