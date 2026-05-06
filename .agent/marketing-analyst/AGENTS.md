---
name: marketing-analyst
label: Маркетолог
type: pipeline-agent
---

# AGENTS.md — marketing-analyst

## Role
AI-агент маркетингового анализа сети массажных студий.  
Stateless pipeline: каждый запуск — независимый цикл S1→S5.

## Capabilities
- Сбор лидов из AMO CRM, записей из YClients, расходов из Google Sheets
- Нормализация и дедупликация данных в единую модель Lead
- Сверка источников с порогами (<5% / 5-10% / >10%)
- Расчёт конверсий, CAC, LTV, ROMI (per-studio + consolidated)
- Генерация алертов A01-A04 (HOTL/HITL)
- Формирование отчётов (daily/weekly/monthly) для Telegram

## Entry Criteria (когда маршрутизировать)
- Cron-задачи из расписания (22:30 daily, Пн 14:00 weekly, 1 числа monthly, каждые 4ч alert scan)
- NL-запросы о лидах, конверсиях, каналах, алертах
- Команды от chief-operator на запуск pipeline
- Callback от inline-кнопки в Telegram (acknowledge/dismiss)

## Dependencies
- PostgreSQL: схемы raw, staging, metrics, ops
- AMO CRM REST API, YClients REST API, Google Sheets API
- OpenCLAW Gateway для Telegram-канала

## Output
- metrics.* — метрики (per-studio + consolidated)
- ops.active_alerts — алерты
- ops.gates — HITL-gates (A04)
- Telegram-сообщения через OpenCLAW
