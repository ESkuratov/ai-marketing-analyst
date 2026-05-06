"""
callback_handler.py — обработка callback-запросов от inline-кнопок в Telegram.

OpenCLAW Gateway направляет callback от нажатия кнопки этому обработчику.
Обработчик выполняет действие (подтверждение алерта, закрытие gate) и возвращает
ответное сообщение.
"""

import json
import logging
from datetime import datetime, timezone
from typing import Any

import psycopg2

from connectors.config import settings

log = logging.getLogger("callback_handler")


class CallbackError(Exception):
    """Ошибка обработки callback."""


def handle_callback(
    callback_data: str,
    user_id: str | None = None,
    db_url: str | None = None,
) -> dict[str, Any]:
    """Обработать callback от inline-кнопки.

    Args:
        callback_data: строка callback_data из нажатой кнопки (JSON).
        user_id: ID пользователя, нажавшего кнопку (из OpenCLAW).
        db_url: строка подключения к БД (из settings если не указана).

    Returns:
        Ответное сообщение (dict для OpenCLAW Gateway).

    Raises:
        CallbackError: если callback_data невалидна или действие не найдено.
    """
    db_url = db_url or settings.database_url

    try:
        payload = json.loads(callback_data)
    except json.JSONDecodeError as e:
        raise CallbackError(f"Невалидный callback_data: {e}")

    action = payload.get("action", "")
    alert_id = payload.get("alert_id")
    studio_id = payload.get("studio_id")
    alert_type = payload.get("alert_type")

    log.info(
        "Callback: action=%s alert_id=%s studio_id=%s user=%s",
        action, alert_id, studio_id, user_id,
    )

    if action == "acknowledge_alert":
        return _acknowledge_alert(db_url, alert_id, studio_id, alert_type, user_id)
    elif action == "dismiss_alert":
        return _dismiss_alert(db_url, alert_id, studio_id, alert_type, user_id)
    else:
        raise CallbackError(f"Неизвестное действие: {action}")


# ============================================================
# acknowledge: ✅ Разобрался (A04 — HITL)
# ============================================================
def _acknowledge_alert(
    db_url: str,
    alert_id: int | None,
    studio_id: str | None,
    alert_type: str | None,
    user_id: str | None,
) -> dict[str, Any]:
    """Подтвердить алерт (закрыть gate, разблокировать pipeline)."""
    if not alert_id or not studio_id:
        raise CallbackError("alert_id и studio_id обязательны для acknowledge")

    now = datetime.now(timezone.utc)

    conn = psycopg2.connect(db_url)
    try:
        with conn.cursor() as cur:
            # Закрыть gate
            cur.execute(
                """
                UPDATE ops.gates
                SET status = 'acknowledged',
                    resolved_at = %s,
                    ack_by = %s
                WHERE alert_id = %s
                  AND studio_id = %s
                  AND status = 'open'
                """,
                (now, user_id or "unknown", alert_id, studio_id),
            )
            updated_gates = cur.rowcount

            # Закрыть алерт
            cur.execute(
                """
                UPDATE ops.active_alerts
                SET resolved_at = %s
                WHERE id = %s
                  AND studio_id = %s
                  AND resolved_at IS NULL
                """,
                (now, alert_id, studio_id),
            )
            updated_alerts = cur.rowcount

        conn.commit()
    except Exception as e:
        conn.rollback()
        raise CallbackError(f"Ошибка БД: {e}")
    finally:
        conn.close()

    if updated_gates == 0 and updated_alerts == 0:
        return {
            "text": "⚠️ Алерт уже был обработан.",
            "parse_mode": "MarkdownV2",
        }

    log.info(
        "Алерт %s подтверждён: gates=%s alerts=%s",
        alert_id, updated_gates, updated_alerts,
    )

    return {
        "text": (
            f"✅ *Алерт {alert_type}* подтверждён\\.\n"
            f"Pipeline для студии *{studio_id}* разблокирован\\."
        ),
        "parse_mode": "MarkdownV2",
    }


# ============================================================
# dismiss: ✅ Принял к сведению (A01-A03 — HOTL)
# ============================================================
def _dismiss_alert(
    db_url: str,
    alert_id: int | None,
    studio_id: str | None,
    alert_type: str | None,
    user_id: str | None,
) -> dict[str, Any]:
    """Закрыть HOTL-алерт без блокировки pipeline."""
    if not alert_id:
        raise CallbackError("alert_id обязателен для dismiss")

    now = datetime.now(timezone.utc)

    conn = psycopg2.connect(db_url)
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE ops.active_alerts
                SET resolved_at = %s
                WHERE id = %s
                  AND resolved_at IS NULL
                """,
                (now, alert_id),
            )
            updated = cur.rowcount
        conn.commit()
    except Exception as e:
        conn.rollback()
        raise CallbackError(f"Ошибка БД: {e}")
    finally:
        conn.close()

    if updated == 0:
        return {
            "text": "⚠️ Алерт уже был обработан.",
            "parse_mode": "MarkdownV2",
        }

    log.info("Алерт %s закрыт (dismiss)", alert_id)

    return {
        "text": f"✅ *{alert_type}* принят к сведению\\.",
        "parse_mode": "MarkdownV2",
    }
