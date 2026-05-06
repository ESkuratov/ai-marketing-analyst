"""
config.py — настройки подключения к БД и конфигурация коннекторов.

DATABASE_URL берётся из переменной окружения.
Список студий загружается из БД (ops.studios) при вызове get_studios().
"""

import os
from dataclasses import dataclass, field
from typing import Optional

from dotenv import load_dotenv

load_dotenv()


# ============================================================
# Settings
# ============================================================
@dataclass
class Settings:
    # DB
    database_url: str = field(
        default_factory=lambda: os.getenv(
            "DATABASE_URL",
            "postgresql://localhost:5432/massage_studio",
        )
    )

    # Retry / backoff
    max_retries: int = int(os.getenv("CONNECTOR_MAX_RETRIES", "3"))
    backoff_base: float = float(os.getenv("CONNECTOR_BACKOFF_BASE", "2.0"))
    request_timeout: int = int(os.getenv("CONNECTOR_TIMEOUT", "30"))

    # AMO CRM
    amo_client_id: Optional[str] = os.getenv("AMO_CLIENT_ID")
    amo_client_secret: Optional[str] = os.getenv("AMO_CLIENT_SECRET")
    amo_redirect_uri: Optional[str] = os.getenv("AMO_REDIRECT_URI")

    # YClients
    yc_bearer_token: Optional[str] = os.getenv("YC_BEARER_TOKEN")
    yc_user_token: Optional[str] = os.getenv("YC_USER_TOKEN")

    # Google Sheets
    gs_credentials_file: Optional[str] = os.getenv(
        "GS_CREDENTIALS_FILE", "credentials/google-sheets.json"
    )
    gs_leads_sheet_id: Optional[str] = os.getenv("GS_LEADS_SHEET_ID")


settings = Settings()


# ============================================================
# Studio config (загружается из БД)
# ============================================================
@dataclass
class StudioConfig:
    studio_id: str
    name: str
    yc_company_id: Optional[int]
    amo_domain: Optional[str]
    amo_pipeline_id: Optional[int]
    gs_sheet_id: Optional[str]
    timezone: str


def get_studios(db_url: str) -> list[StudioConfig]:
    """Загружает список активных студий из ops.studios."""
    import psycopg2.extras

    conn = psycopg2.connect(db_url)
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT studio_id, name, yc_company_id, amo_domain,
                       amo_pipeline_id, gs_sheet_id, timezone
                FROM ops.studios
                WHERE is_active = TRUE
                ORDER BY studio_id
                """
            )
            rows = cur.fetchall()
        return [StudioConfig(**row) for row in rows]
    finally:
        conn.close()
