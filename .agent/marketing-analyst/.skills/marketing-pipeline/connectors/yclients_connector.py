"""
yclients_connector.py — коннектор к YClients API.

Загружает записи (visits) из YClients для аналитики.
Важно: API игнорирует параметр date — фильтрация клиентская.
"""

import json
import os
import time
from datetime import datetime, timedelta
from typing import Any, Iterator
from urllib.request import Request, urlopen
from urllib.error import HTTPError

from connectors.base_connector import BaseConnector


class YClientsConnector(BaseConnector):
    """Загрузка записей из YClients API."""

    API_BASE = "https://api.yclients.com/api/v1"

    # Staff IDs из SKILL.md (3775989 — Лист ожидания, не считаем как мастера)
    STAFF_MASTER = {
        5111463: "Александра",
        3741329: "Анна Зыкова",
        3745349: "Денис Мартынов",
        3757001: "Татьяна Ковалева",
        4964993: "Светлана",
        3910523: "Ольга",
        4181742: "Екатерина",
    }
    STAFF_WAITLIST = 3775989  # Лист ожидания (буфер)

    # Attendance statuses из SKILL.md
    ATTENDANCE_NO_SHOW = -1    # Не пришёл (красный)
    ATTENDANCE_WAITING = 0     # Ожидание (зелёный)
    ATTENDANCE_VISITED = 1     # Пришёл (жёлтый)
    ATTENDANCE_CONFIRMED = 2   # Подтвердил (фиолетовый)

    def __init__(self, studio: Any, db_url: str = ""):
        # Получаем db_url из .env если не передан
        if not db_url:
            from connectors.config import settings
            db_url = settings.database_url
        super().__init__(studio, db_url)
        self._bearer_token: str = ""
        self._user_token: str = ""
        self._company_id: int = 0

    # ----------------------------------------------------------
    # Конфигурация
    # ----------------------------------------------------------
    def _load_config(self) -> bool:
        """Загрузить конфигурацию из .env."""
        env_paths = [
            os.path.join(os.getcwd(), '.env'),
            os.path.join(os.path.dirname(__file__), '../../../../.env'),
            '.env',
        ]

        env_vars = {}
        for env_path in env_paths:
            if os.path.exists(env_path):
                with open(env_path) as f:
                    for line in f:
                        line = line.strip()
                        if '=' in line and not line.startswith('#'):
                            key, value = line.split('=', 1)
                            value = value.strip().strip("'\"")
                            env_vars[key.strip()] = value
                break

        self._bearer_token = env_vars.get('YC_BEARER_TOKEN', '')
        self._user_token = env_vars.get('YC_USER_TOKEN', '')
        self._company_id = self.studio.yc_company_id or 1234490  # XSize default

        if not self._bearer_token or not self._user_token:
            self.log.warning("YClients не настроен: отсутствуют токены")
            return False

        return True

    # ----------------------------------------------------------
    # API запросы
    # ----------------------------------------------------------
    def _make_request(self, endpoint: str, method: str = "GET",
                     params: dict | None = None) -> dict:
        """Выполнить API запрос к YClients."""
        if not self._bearer_token:
            return {"error": "Not configured"}

        url = f"{self.API_BASE}{endpoint}"
        if params:
            from urllib.parse import urlencode
            url += "?" + urlencode(params)

        headers = {
            "Authorization": f"Bearer {self._bearer_token}, User {self._user_token}",
            "Accept": "application/vnd.yclients.v2+json",
            "Content-Type": "application/json",
        }

        try:
            req = Request(url, headers=headers, method=method)
            with urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode())

        except HTTPError as e:
            error_body = e.read().decode()
            self.log.error("YClients HTTP %s: %s", e.code, error_body[:500])
            return {"error": e.code, "message": error_body[:500]}
        except Exception as e:
            self.log.error("YClients request error: %s", str(e))
            return {"error": "request_failed", "message": str(e)}

    # ----------------------------------------------------------
    # Загрузка записей с пагинацией
    # ----------------------------------------------------------
    def _fetch_records_page(self, page: int = 1, per_page: int = 200) -> list[dict]:
        """Получить одну страницу записей."""
        endpoint = f"/records/{self._company_id}"
        params = {
            "page": page,
            "per_page": per_page,
        }

        result = self._make_request(endpoint, params=params)

        if "error" in result:
            self.log.error("Failed to fetch records: %s", result)
            return []

        # YClients возвращает list или dict с data
        if isinstance(result, list):
            return result
        return result.get("data", [])

    def fetch_records_for_date(self, date_str: str) -> list[dict]:
        """Получить записи за конкретную дату.

        ВАЖНО: YClients API игнорирует параметр date.
        Используем jump search + клиентскую фильтрацию.

        Args:
            date_str: Дата в формате 'YYYY-MM-DD'
        """
        if not self._load_config():
            return []

        self.log.info("Fetching YClients records for %s", date_str)

        # Примерный маппинг страниц (из SKILL.md):
        # Page 1: 2026-05-13 to 2026-04-04
        # Page 3: 2026-03-27 to 2026-03-23
        # Page 5: 2026-03-18 to 2026-03-14

        all_matching_records = []
        checked_pages = set()

        # Алгоритм jump search
        pages_to_check = [1, 3, 5, 7, 10, 15, 20, 30, 50]

        for page in pages_to_check:
            if page in checked_pages:
                continue
            checked_pages.add(page)

            records = self._fetch_records_page(page)
            if not records:
                break

            # Фильтруем записи по дате
            for record in records:
                record_date = record.get("datetime", "")[:10]  # YYYY-MM-DD
                if record_date == date_str:
                    all_matching_records.append(record)

            # Проверяем диапазон дат на странице
            if records:
                first_date = records[0].get("datetime", "")[:10]
                last_date = records[-1].get("datetime", "")[:10]

                # Если нашли дату в диапазоне — проверяем соседние страницы
                if first_date >= date_str >= last_date or \
                   (first_date <= date_str <= last_date):
                    # Проверяем предыдущую и следующую страницы
                    for nearby in [page - 1, page + 1]:
                        if nearby > 0 and nearby not in checked_pages:
                            nearby_records = self._fetch_records_page(nearby)
                            for rec in nearby_records:
                                if rec.get("datetime", "")[:10] == date_str:
                                    all_matching_records.append(rec)
                            checked_pages.add(nearby)

            # Оптимизация: если последняя запись старше target_date — останавливаемся
            if records:
                last_record_date = records[-1].get("datetime", "")[:10]
                if last_record_date < date_str:
                    self.log.debug("Last record %s < target %s, stopping",
                                  last_record_date, date_str)
                    break

        self.log.info("Found %s records for %s", len(all_matching_records), date_str)
        return all_matching_records

    # ----------------------------------------------------------
    # Основной метод fetch
    # ----------------------------------------------------------
    def fetch(self, date_from: str | None = None, date_to: str | None = None) -> int:
        """Загрузить записи из YClients и сохранить в raw.yc_visits.

        Args:
            date_from: Дата начала 'YYYY-MM-DD'
            date_to: Дата окончания 'YYYY-MM-DD'
        """
        if not self._load_config():
            return 0

        if not date_from:
            date_from = (datetime.now() - timedelta(days=1)).strftime('%Y-%m-%d')
        if not date_to:
            date_to = date_from

        total = 0
        current_date = datetime.strptime(date_from, '%Y-%m-%d')
        end_date = datetime.strptime(date_to, '%Y-%m-%d')

        while current_date <= end_date:
            date_str = current_date.strftime('%Y-%m-%d')
            records = self.fetch_records_for_date(date_str)

            if records:
                saved = self._save_visits(records)
                total += saved
                self.log.info("YClients %s: сохранено %s записей", date_str, saved)

            current_date += timedelta(days=1)

        self.log.info("YClients: всего сохранено %s записей за период", total)
        return total

    def fetch_by_date(self, date_str: str) -> int:
        """Загрузить записи за конкретную дату."""
        return self.fetch(date_from=date_str, date_to=date_str)

    # ----------------------------------------------------------
    # Маппинг полей
    # ----------------------------------------------------------
    def _save_visits(self, raw_records: list[dict]) -> int:
        """Маппинг YClients → raw.yc_visits."""
        records: list[dict] = []

        for rec in raw_records:
            staff_id = rec.get("staff_id")

            # Определяем тип записи
            is_waitlist = staff_id == self.STAFF_WAITLIST
            master_name = self.STAFF_MASTER.get(staff_id, "Unknown")

            # Attendance status
            attendance = rec.get("attendance", 0)
            attendance_str = {
                self.ATTENDANCE_NO_SHOW: "no_show",
                self.ATTENDANCE_WAITING: "waiting",
                self.ATTENDANCE_VISITED: "visited",
                self.ATTENDANCE_CONFIRMED: "confirmed",
            }.get(attendance, "unknown")

            # Проверяем нового клиента
            is_new = rec.get("is_new", False)
            services = rec.get("services", [])
            if not is_new and services:
                for svc in services:
                    title = svc.get("title", "").lower()
                    if "первый" in title or "first" in title:
                        is_new = True
                        break

            records.append({
                "id": rec.get("id"),
                "studio_id": self.studio.studio_id,
                "source": "yclients",
                "company_id": self._company_id,
                "datetime": rec.get("datetime"),
                "date": rec.get("datetime", "")[:10] if rec.get("datetime") else None,
                "staff_id": staff_id,
                "staff_name": None if is_waitlist else master_name,
                "is_waitlist": is_waitlist,
                "client_id": rec.get("client", {}).get("id"),
                "client_name": rec.get("client", {}).get("name"),
                "client_phone": self.clean_phone(rec.get("client", {}).get("phone")),
                "services": [s.get("title") for s in services],
                "attendance": attendance,
                "attendance_str": attendance_str,
                "is_new": is_new,
                "price": rec.get("price", 0),
                "duration": rec.get("length", 0),  # minutes
                "raw_data": rec,
            })

        return self._save_to_raw("yc_visits", records)

    # ----------------------------------------------------------
    # Утилиты
    # ----------------------------------------------------------
    def get_services(self) -> list[dict]:
        """Получить список услуг компании."""
        if not self._load_config():
            return []

        endpoint = f"/company/{self._company_id}/services"
        result = self._make_request(endpoint)

        if isinstance(result, list):
            return result
        return result.get("data", [])

    def get_staff(self) -> dict[int, str]:
        """Получить список мастеров (из констант, API /staff может быть недоступен)."""
        return self.STAFF_MASTER.copy()
