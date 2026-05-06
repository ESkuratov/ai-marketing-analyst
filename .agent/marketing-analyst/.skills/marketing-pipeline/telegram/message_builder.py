"""
message_builder.py — формирование сообщений с inline-кнопками для OpenCLAW.

OpenCLAW Gateway принимает структурированные сообщения, которые доставляет
в Telegram. Inline-кнопки передаются как массив callback-действий.
"""

from typing import Any

from telegram.report_formatters import (
    closed_lost_analytics_report,
    daily_report,
    deposit_clients_report,
    lapsed_clients_report,
    monthly_report,
    network_summary_report,
    weekly_report,
)


# ============================================================
# Структура сообщения для OpenCLAW
# ============================================================
def build_message(
    text: str,
    buttons: list[dict[str, str]] | None = None,
    parse_mode: str = "MarkdownV2",
) -> dict[str, Any]:
    """Собрать структуру сообщения для OpenCLAW Gateway.

    Args:
        text: Текст сообщения (MarkdownV2).
        buttons: Список кнопок [{"label": "✅ Разобрался", "action": "acknowledge_alert", "data": {...}}].
        parse_mode: Режим парсинга (MarkdownV2 / HTML).

    Returns:
        Dict для OpenCLAW Gateway.
    """
    msg: dict[str, Any] = {
        "text": text,
        "parse_mode": parse_mode,
    }
    if buttons:
        msg["inline_keyboard"] = [
            [
                {
                    "text": b["label"],
                    "callback_data": _build_callback_data(b),
                }
            ]
            for b in buttons
        ]
    return msg


def _build_callback_data(button: dict[str, str]) -> str:
    """Упаковать callback_data в строку для inline-кнопки."""
    import json

    payload = {
        "action": button.get("action", ""),
    }
    extra_data = button.get("data", {})
    if extra_data and isinstance(extra_data, dict):
        payload.update(extra_data)
    return json.dumps(payload, separators=(",", ":"))


# ============================================================
# Сообщения с кнопками
# ============================================================
def alert_message(
    alert_type: str,
    severity: str,
    metric_name: str,
    metric_value: float | None,
    recommendation: str,
    alert_id: int,
    studio_id: str,
) -> dict[str, Any]:
    """Сформировать сообщение-алерт с inline-кнопкой.

    Args:
        alert_type: A01 / A02 / A03 / A04
        severity: warning / critical
        metric_name: название метрики
        metric_value: значение метрики
        recommendation: текст рекомендации
        alert_id: ID алерта из ops.active_alerts
        studio_id: ID студии

    Returns:
        Dict для OpenCLAW Gateway.
    """
    severity_icon = {"critical": "🔴", "warning": "⚠️", "info": "ℹ️"}.get(severity, "•")
    text = (
        f"{severity_icon} *{alert_type}* \\- {severity.upper()}\n"
        f"📊 {metric_name}: `{metric_value}`\n"
        f"💡 {recommendation}"
    )

    buttons = []
    if alert_type == "A04":
        buttons.append({
            "label": "✅ Разобрался",
            "action": "acknowledge_alert",
            "data": {
                "alert_id": alert_id,
                "studio_id": studio_id,
                "alert_type": alert_type,
            },
        })
    elif severity in ("warning", "critical"):
        buttons.append({
            "label": "✅ Принял к сведению",
            "action": "dismiss_alert",
            "data": {
                "alert_id": alert_id,
                "studio_id": studio_id,
                "alert_type": alert_type,
            },
        })

    return build_message(text, buttons if buttons else None)


# ============================================================
# Отчёты (без кнопок)
# ============================================================
def daily_report_message(
    summary_rows: list[dict[str, Any]],
    alert_rows: list[dict[str, Any]],
    studio_name: str = "",
) -> dict[str, Any]:
    """Ежедневный отчёт."""
    text = daily_report(summary_rows, alert_rows, studio_name)
    return build_message(text)


def weekly_report_message(
    funnel_rows: list[dict[str, Any]],
    channel_rows: list[dict[str, Any]],
    studio_name: str = "",
) -> dict[str, Any]:
    """Еженедельный отчёт."""
    text = weekly_report(funnel_rows, channel_rows, studio_name)
    return build_message(text)


def monthly_report_message(
    client_rows: list[dict[str, Any]],
    channel_rows: list[dict[str, Any]],
    studio_name: str = "",
) -> dict[str, Any]:
    """Ежемесячный отчёт."""
    text = monthly_report(client_rows, channel_rows, studio_name)
    return build_message(text)


def network_summary_message(network_rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Сводка по сети."""
    text = network_summary_report(network_rows)
    return build_message(text)


# ============================================================
# Per-stage отчёты (funnel-flow.md stages 8, 10, 12)
# ============================================================
def deposit_clients_message(
    rows: list[dict[str, Any]],
    studio_name: str = "",
) -> dict[str, Any]:
    """Список клиентов с залогом (Stage 8)."""
    text = deposit_clients_report(rows, studio_name)
    return build_message(text)


def lapsed_clients_message(
    rows: list[dict[str, Any]],
    studio_name: str = "",
) -> dict[str, Any]:
    """Список непродлившихся клиентов (Stage 10)."""
    text = lapsed_clients_report(rows, studio_name)
    return build_message(text)


def closed_lost_analytics_message(
    rows: list[dict[str, Any]],
    studio_name: str = "",
) -> dict[str, Any]:
    """Аналитика закрытых без продажи (Stage 12)."""
    text = closed_lost_analytics_report(rows, studio_name)
    return build_message(text)
