-- ============================================================================
-- 04_analytics_views.sql
-- Autonomous Self-Healing SQL Pipeline: Analytics & Observability Views
-- Views: MTTR, Pipeline Success Rate, Rescued vs At-Risk Revenue, Error Breakdown
-- ============================================================================

-- ============================================================================
-- VIEW 1: DATA PIPELINE SRE & RELIABILITY METRICS (MTTR & SUCCESS RATE)
-- ============================================================================
CREATE OR REPLACE VIEW vw_pipeline_health_metrics AS
WITH repair_latencies AS (
    -- Pair every FAILED run with the timestamp of the first subsequent SUCCESS run
    SELECT 
        f.job_name,
        f.execution_id AS failed_id,
        f.started_at AS failure_time,
        MIN(s.finished_at) AS resolved_time,
        EXTRACT(EPOCH FROM (MIN(s.finished_at) - f.started_at)) AS recovery_latency_seconds
    FROM job_execution_log f
    JOIN job_execution_log s 
      ON f.job_name = s.job_name 
     AND s.status = 'SUCCESS' 
     AND s.started_at >= f.started_at
    WHERE f.status = 'FAILED'
    GROUP BY f.job_name, f.execution_id, f.started_at
)
SELECT 
    COUNT(*) AS total_failures_detected,
    COALESCE(ROUND(AVG(recovery_latency_seconds)::NUMERIC, 2), 0.00) AS mean_time_to_repair_seconds,
    COALESCE(ROUND(MAX(recovery_latency_seconds)::NUMERIC, 2), 0.00) AS max_latency_seconds,
    ROUND(
        (SELECT COUNT(*) FROM job_execution_log WHERE status = 'SUCCESS') * 100.0 / 
        NULLIF((SELECT COUNT(*) FROM job_execution_log), 0), 
        2
    ) AS pipeline_success_rate_pct
FROM repair_latencies;

-- ============================================================================
-- VIEW 2: FINANCIAL IMPACT (RESCUED REVENUE VS QUARANTINED AT RISK)
-- ============================================================================
CREATE OR REPLACE VIEW vw_pipeline_financial_impact AS
-- 1. Rescued Revenue: Orders that landed in fact_orders via a repaired execution batch
SELECT 
    'Rescued Revenue (Auto-Healed)' AS metric_category,
    COUNT(fo.order_id) AS record_count,
    COALESCE(SUM(fo.total_amount), 0.00) AS total_monetary_value
FROM fact_orders fo
JOIN job_execution_log jel ON fo.execution_id = jel.execution_id
WHERE jel.attempt_count > 0

UNION ALL

-- 2. Clean First-Pass Revenue: Orders ingested without encountering errors
SELECT 
    'First-Pass Revenue (Clean Ingest)' AS metric_category,
    COUNT(fo.order_id) AS record_count,
    COALESCE(SUM(fo.total_amount), 0.00) AS total_monetary_value
FROM fact_orders fo
JOIN job_execution_log jel ON fo.execution_id = jel.execution_id
WHERE jel.attempt_count = 0

UNION ALL

-- 3. Quarantined Revenue: Offending records trapped inside the DLQ
SELECT 
    'Quarantined Revenue (At Risk)' AS metric_category,
    COUNT(dlq.quarantine_id) AS record_count,
    COALESCE(
        SUM(
            (COALESCE(dlq.raw_record->>'quantity', '0'))::NUMERIC * 
            (COALESCE(dlq.raw_record->>'unit_price', '0'))::NUMERIC
        ), 
        0.00
    ) AS total_monetary_value
FROM dead_letter_quarantine dlq;

-- ============================================================================
-- VIEW 3: ROOT CAUSE ERROR CODE DISTRIBUTION (PARETO ANALYSIS)
-- ============================================================================
CREATE OR REPLACE VIEW vw_error_code_distribution AS
SELECT 
    COALESCE(error_code, 'UNKNOWN') AS error_code,
    CASE 
        WHEN error_code = '23502' THEN 'NOT NULL Constraint Violation'
        WHEN error_code = '23514' THEN 'CHECK Constraint Violation (Negative values)'
        WHEN error_code = '23503' THEN 'FOREIGN KEY Violation (Invalid Customer/Product)'
        WHEN error_code = '40P01' THEN 'Database Deadlock Contention'
        WHEN error_code = '40001' THEN 'Serialization Failure'
        WHEN error_code = '57014' THEN 'Query Lock Timeout'
        ELSE 'System / Structural Anomaly'
    END AS error_description,
    COUNT(*) AS occurrence_count,
    ROUND(
        COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 
        2
    ) AS error_share_pct
FROM job_execution_log
WHERE error_code IS NOT NULL
GROUP BY error_code;
