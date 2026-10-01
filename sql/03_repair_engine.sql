-- ============================================================================
-- 03_repair_engine.sql
-- Autonomous Self-Healing SQL Pipeline: Diagnostic Self-Repair Engine
-- Features: Circuit Breakers, ANSI SQLSTATE Classification, DLQ Siphoning,
--           Exponential Backoff for concurrency/locks, State Machine Requeuing
-- ============================================================================

-- Define or replace the stored procedure named 'run_self_repair_engine'
CREATE OR REPLACE PROCEDURE run_self_repair_engine()
LANGUAGE plpgsql
AS $$
DECLARE
    -- rec: Loop cursor variable holding failed job metadata
    rec RECORD;
    -- v_poison_count: Tracks how many bad records were isolated to DLQ
    v_poison_count INT := 0;
BEGIN
    -- 1. Scan for jobs requiring repair whose backoff wait window has expired
    FOR rec IN 
        SELECT 
            execution_id, 
            job_name, 
            attempt_count, 
            max_retries, 
            error_code, 
            error_message
        FROM job_execution_log
        WHERE status = 'FAILED' 
          AND (next_retry_at IS NULL OR next_retry_at <= clock_timestamp())
    LOOP
        -- CIRCUIT BREAKER: Check if max retries were exceeded
        IF rec.attempt_count >= rec.max_retries THEN
            UPDATE job_execution_log
            SET status = 'QUARANTINED',
                finished_at = clock_timestamp()
            WHERE execution_id = rec.execution_id;

            RAISE WARNING 'Execution % exceeded max attempts (%). Permanently QUARANTINED.', 
                          rec.execution_id, rec.max_retries;
            CONTINUE;
        END IF;

        -- Transition state to REPAIRING while diagnostics run
        UPDATE job_execution_log 
        SET status = 'REPAIRING' 
        WHERE execution_id = rec.execution_id;

        -- 2. ANSI SQLSTATE DIAGNOSTIC CLASSIFICATION MATRIX
        CASE 
            -- ================================================================
            -- PLAYBOOK A: DATA INTEGRITY & CONSTRAINT VIOLATIONS
            -- 23502 (NOT NULL violation)
            -- 23514 (CHECK constraint violation: negative quantity/price)
            -- 23503 (FOREIGN KEY violation: invalid customer_id or product_id)
            -- ================================================================
            WHEN rec.error_code IN ('23502', '23514', '23503') THEN
                -- Siphon offending records using a Common Table Expression (CTE)
                WITH bad_rows AS (
                    DELETE FROM staging_orders s
                    WHERE 
                        -- Check Constraint / Not Null checks
                        s.quantity IS NULL 
                        OR s.quantity <= 0
                        OR s.unit_price IS NULL 
                        OR s.unit_price <= 0
                        -- Foreign Key checks against dimensions
                        OR NOT EXISTS (
                            SELECT 1 FROM dim_customers c 
                            WHERE c.customer_id = s.customer_id
                        )
                        OR NOT EXISTS (
                            SELECT 1 FROM dim_products p 
                            WHERE p.product_id = s.product_id
                        )
                    RETURNING *
                )
                INSERT INTO dead_letter_quarantine (
                    execution_id, 
                    source_table, 
                    raw_record, 
                    rejection_reason
                )
                SELECT 
                    rec.execution_id, 
                    'staging_orders', 
                    to_jsonb(b), 
                    rec.error_message
                FROM bad_rows b;

                GET DIAGNOSTICS v_poison_count = ROW_COUNT;

                -- Reset job state to PENDING so the remaining clean rows can be ingested immediately
                UPDATE job_execution_log
                SET status = 'PENDING',
                    attempt_count = attempt_count + 1,
                    next_retry_at = clock_timestamp()
                WHERE execution_id = rec.execution_id;

                RAISE NOTICE 'Repaired: Siphoned % poison rows to DLQ. Job % requeued.', 
                             v_poison_count, rec.execution_id;

            -- ================================================================
            -- PLAYBOOK B: TRANSIENT CONCURRENCY & LOCK CONTENTION
            -- 40001 (SERIALIZATION FAILURE)
            -- 40P01 (DEADLOCK DETECTED)
            -- 57014 (QUERY TIMEOUT / LOCK CANCEL)
            -- ================================================================
            WHEN rec.error_code IN ('40001', '40P01', '57014') THEN
                -- Apply Exponential Backoff: 2^(attempt) * 15 seconds
                UPDATE job_execution_log
                SET status = 'PENDING',
                    attempt_count = attempt_count + 1,
                    next_retry_at = clock_timestamp() + (POWER(2, rec.attempt_count) * INTERVAL '15 seconds')
                WHERE execution_id = rec.execution_id;

                RAISE NOTICE 'Repaired: Concurrency issue. Set exponential backoff for job %.', 
                             rec.execution_id;

            -- ================================================================
            -- PLAYBOOK C: UNHANDLED STRUCTURAL / PERMISSION ERRORS
            -- ================================================================
            ELSE
                UPDATE job_execution_log
                SET status = 'QUARANTINED',
                    finished_at = clock_timestamp()
                WHERE execution_id = rec.execution_id;

                RAISE WARNING 'Unresolvable error code [%]. Moved job % to QUARANTINED.', 
                              rec.error_code, rec.execution_id;
        END CASE;
    END LOOP;
END;
$$;
