-- Migration 009: Drop unused staging.channels table (if exists)
-- Reason: Duplicate of metrics.channel_roi, never used in pipeline
-- Date: 2026-05-05

DROP TABLE IF EXISTS staging.channels;
