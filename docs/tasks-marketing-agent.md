# Tasks: Marketing Agent — план реализации

## Этап 1: Фундамент (PostgreSQL) ✅

| № | Задача | Файлы | Строк | Зависит от | Статус |
|---|--------|-------|-------|------------|--------|
| 1.1 | Создать миграцию: схема raw | `migrations/001_raw_schema.sql` | ~90 | — | ✅ |
| 1.2 | Создать миграцию: схема staging | `migrations/002_staging_schema.sql` | ~55 | 1.1 | ✅ |
| 1.3 | Создать миграцию: схема metrics | `migrations/003_metrics_schema.sql` | ~95 | 1.2 | ✅ |
| 1.4 | Создать миграцию: схема ops | `migrations/004_ops_schema.sql` | ~90 | — | ✅ |
| 1.5 | Скрипт инициализации БД (запуск всех миграций) | `migrations/init_db.sh` | ~35 | 1.1–1.4 | ✅ |

**Результат:** PostgreSQL база с 4 схемами, ~15 таблицами, индексами по `studio_id + date`

---

## Этап 2: Коннекторы (Python) ✅

| № | Задача | Файлы | Строк | Зависит от | Статус |
|---|--------|-------|-------|------------|--------|
| 2.1 | Базовый класс коннектора (retry, backoff, логгирование) | `connectors/base_connector.py` | ~80 | — | ✅ |
| 2.2 | Коннектор AMO CRM | `connectors/amo_connector.py` | ~120 | 2.1, 1.1 | ✅ |
| 2.3 | Коннектор YClients | `connectors/yc_connector.py` | ~100 | 2.1, 1.1 | ✅ |
| 2.4 | Коннектор Google Sheets | `connectors/gsheets_connector.py` | ~110 | 2.1, 1.1 | ✅ |
| 2.5 | Оркестратор коннекторов (читает ops.studios, запускает per studio) | `connectors/run_all.py` | ~90 | 2.2–2.4, 1.4 | ✅ |
| 2.6 | Config (подключение к БД, studios) | `connectors/config.py` | ~65 | — | ✅ |
| 2.7 | Требования | `connectors/requirements.txt` | ~10 | — | ✅ |

**Результат:** 8 файлов (3 коннектора + базовый класс + оркестратор + config + requirements)

---

## Этап 3: Pipeline (SQL + Python) ✅

| № | Задача | Файлы | Строк | Зависит от | Статус |
|---|--------|-------|-------|------------|--------|
| 3.1 | S2: Normalize (нормализация + дедупликация) | `pipeline/s2_normalize.sql` | ~100 | 1.2 | ✅ |
| 3.2 | S3: Reconcile (сверка источников с порогами) | `pipeline/s3_reconcile.sql` | ~80 | 3.1 | ✅ |
| 3.3 | S4: Metrics (расчёт конверсий, CAC, LTV, ROMI) | `pipeline/s4_metrics.sql` | ~170 | 3.1 | ✅ |
| 3.4 | S5a: Alerts (проверка алертов A01-A04) | `pipeline/s5a_alerts.sql` | ~160 | 3.3 | ✅ |
| 3.5 | S5b: Reports (выборка данных для отчётов) | `pipeline/s5b_reports.sql` | ~120 | 3.3 | ✅ |
| 3.6 | Оркестратор pipeline (запуск S2→S5 для studio_id) | `pipeline/run_pipeline.py` | ~160 | 3.1–3.5 | ✅ |

**Результат:** 6 файлов, pipeline S2→S5, проверка HITL-gates, аргументы --studio_id / --all-studios

---

## Этап 4: Telegram-интеграция (через OpenCLAW) ✅

| № | Задача | Файлы | Строк | Зависит от | Статус |
|---|--------|-------|-------|------------|--------|
| 4.1 | Форматтеры отчётов (daily/weekly/monthly) | `telegram/report_formatters.py` | ~130 | 3.5 | ✅ |
| 4.2 | Формирователь сообщений с inline-кнопками для OpenCLAW | `telegram/message_builder.py` | ~130 | 4.1 | ✅ |
| 4.3 | Обработчик callback от кнопки ✅ (UPDATE ops.gates) | `telegram/callback_handler.py` | ~120 | 1.4 | ✅ |

**Результат:** Форматтеры (MarkdownV2) + сообщения с inline-кнопками + обработчик acknowledge/dismiss.

---

## Этап 5: OpenCLAW workspace ✅

| № | Задача | Файлы | Строк | Зависит от | Статус |
|---|--------|-------|-------|------------|--------|
| 5.1 | AGENTS.md — определение агента | `workspace/AGENTS.md` | ~35 | — | ✅ |
| 5.2 | SOUL.md — личность агента | `workspace/SOUL.md` | ~25 | — | ✅ |
| 5.3 | TOOLS.md — доступные инструменты | `workspace/TOOLS.md` | ~55 | — | ✅ |
| 5.4 | SKILL.md — основной промпт (адаптирован под код) | `workspace/SKILL.md` | ~190 | 3.6, 4.1 | ✅ |

**Результат:** Полный workspace для OpenCLAW gateway (4 файла)

---

## Этап 6: Studio management ✅

| № | Задача | Файлы | Строк | Зависит от | Статус |
|---|--------|-------|-------|------------|--------|
| 6.1 | SQL: CRUD для ops.studios | `studio/studio_mgmt.sql` | ~40 | 1.4 | ✅ |
| 6.2 | Скрипт добавления новой студии | `studio/add_studio.py` | ~120 | 6.1 | ✅ |

**Результат:** `add_studio.py --studio-id=X --name="..."` — добавление/листинг/деактивация

---

## Соответствие нумерации README

Нумерация pipeline в задачах соответствует `README.md`:

| README | Реализация |
|--------|-----------|
| **S1**: Collect | **Этап 2** — Python-коннекторы (`connectors/`) |
| **S2**: Normalize | **3.1** — `pipeline/s2_normalize.sql` |
| **S3**: Reconcile | **3.2** — `pipeline/s3_reconcile.sql` |
| **S4**: Metrics | **3.3** — `pipeline/s4_metrics.sql` |
| **S5a**: Alerts | **3.4** — `pipeline/s5a_alerts.sql` |
| **S5b**: Reports | **3.5** — `pipeline/s5b_reports.sql` |

Collect (S1) выделен в отдельный Этап 2, так как это Python-код (коннекторы к API), а остальные шаги — SQL-запросы.

## Порядок разработки

```
Этап 1 (Фундамент)
    ↓
Этап 2 (Коннекторы · S1 Collect) → Этап 3 (Pipeline · S2→S5) → Этап 4 (Telegram)
    ↓                                         ↓
    └───────────── Этап 5 (OpenCLAW workspace) ←───────────┘
    ↓
Этап 6 (Studio management) — в любой момент после 1.4
```

## Что можно параллелить

| Параллель | Задачи |
|-----------|--------|
| Группа A | 1.1–1.5 (миграции) |
| Группа B | 2.1 (базовый класс) |
| Группа C | 5.1–5.3 (workspace) |
| После 1.1 | 2.2, 2.3, 2.4 параллельно |
| После 2.5 | 3.1–3.5 параллельно |

## Проверка результата

1. **Этап 1:** `psql -f migrations/001_raw_schema.sql` — таблицы созданы
2. **Этап 2 (S1 Collect):** `python connectors/run_all.py` — данные в `raw.*`
3. **Этап 3 (S2→S5):** `python pipeline/run_pipeline.py --studio_id=studio_a` — метрики в `metrics.*`
4. **Этап 4:** Telegram приходит отчёт с кнопкой
5. **Этап 5:** OpenCLAW gateway запускает агента
6. **Этап 6:** `python studio/add_studio.py --name="Студия Б"` — студия в `ops.studios`
