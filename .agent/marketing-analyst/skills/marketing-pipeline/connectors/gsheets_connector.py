"""
gsheets_connector.py — коннектор к Google Sheets.

Загружает расходы из Google Sheets по указанному sheet_id.
Использует сервисный аккаунт Google (credentials file).
"""

from typing import Any

from google.auth import default as google_default
from googleapiclient.discovery import build

from connectors.base_connector import BaseConnector
from connectors.config import settings


class GsheetsConnector(BaseConnector):
    """Загрузка расходов из Google Sheets."""

    SCOPES = ["https://www.googleapis.com/auth/spreadsheets.readonly"]
    RANGE_NAME = "Расходы!A:F"  # ожидаемый диапазон

    def fetch(self) -> int:
        """Загрузить расходы из Google Sheets и сохранить в raw.gs_expenses."""
        sheet_id = self.studio.gs_sheet_id
        if not sheet_id:
            self.log.warning("gs_sheet_id не указан, пропускаем")
            return 0

        try:
            values = self._read_sheet(sheet_id)
        except Exception as e:
            self.log.error("Ошибка чтения Google Sheets: %s", e)
            return 0

        if not values:
            self.log.info("Студия %s | GS: пустой лист", self.studio.studio_id)
            return 0

        saved = self._save_expenses(values)
        self.log.info(
            "Студия %s | GS: сохранено %s записей",
            self.studio.studio_id, saved,
        )
        return saved

    # ----------------------------------------------------------
    # Чтение Google Sheets
    # ----------------------------------------------------------
    def _read_sheet(self, sheet_id: str) -> list[list[Any]]:
        """Прочитать данные из Google Sheets."""
        creds = self._get_credentials()
        service = build("sheets", "v4", credentials=creds)
        sheet = service.spreadsheets()
        result = sheet.values().get(
            spreadsheetId=sheet_id,
            range=self.RANGE_NAME,
        ).execute()
        return result.get("values", [])

    def _get_credentials(self) -> Any:
        """Получить credentials для Google API."""
        creds_file = settings.gs_credentials_file
        if creds_file:
            import google.auth.transport.requests
            from google.oauth2 import service_account

            return service_account.Credentials.from_service_account_file(
                creds_file, scopes=self.SCOPES
            )
        # fallback: ADC (Application Default Credentials)
        creds, _ = google_default(scopes=self.SCOPES)
        return creds

    # ----------------------------------------------------------
    # Парсинг строк
    # ----------------------------------------------------------
    def _save_expenses(self, rows: list[list[Any]]) -> int:
        """Парсинг строк Google Sheets → raw.gs_expenses.

        Ожидаемая структура (header пропускается):
          A: date, B: article, C: amount, D: channel, E: description
        """
        records: list[dict] = []
        for i, row in enumerate(rows):
            if i == 0 and self._is_header(row):
                continue
            if len(row) < 3:
                continue

            records.append({
                "studio_id": self.studio.studio_id,
                "date": row[0],
                "article": row[1],
                "amount": float(row[2]) if row[2] else 0,
                "channel": row[3] if len(row) > 3 else None,
                "description": row[4] if len(row) > 4 else None,
                "raw_data": None,
            })

        # У gs_expenses PK: (studio_id, id), где id — SERIAL.
        # ON CONFLICT не сработает при SERIAL, поэтому используем обычный INSERT.
        conn = self._get_connection()
        try:
            import psycopg2.extras

            with conn.cursor() as cur:
                psycopg2.extras.execute_batch(
                    cur,
                    """
                    INSERT INTO raw.gs_expenses
                        (studio_id, date, article, amount, channel, description)
                    VALUES
                        (%(studio_id)s, %(date)s, %(article)s, %(amount)s,
                         %(channel)s, %(description)s)
                    """,
                    records,
                )
            conn.commit()
        finally:
            conn.close()
        return len(records)

    def _get_connection(self):
        import psycopg2
        return psycopg2.connect(self.db_url)

    @staticmethod
    def _is_header(row: list[Any]) -> bool:
        """Определить, является ли строка заголовком."""
        headers = {"дата", "date", "статья", "article", "сумма", "amount"}
        first = str(row[0]).strip().lower() if row else ""
        return first in headers
