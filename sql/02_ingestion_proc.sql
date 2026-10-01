-- ============================================================================
-- 02_ingestion_proc.sql
-- Autonomous Self-Healing SQL Pipeline: Stored Procedure for Ingestion Logic
-- Features: Subtransactions, EXCEPTION trapping, Idempotent UPSERT, Lineage
-- ============================================================================

-- Define or replace the stored procedure named 'run_order_ingestion'
-- Default parameter 'p_job_name' identifies which ETL workflow this execution belongs to
CREATE OR REPLACE PROCEDURE run_order_ingestion(p_job_name TEXT DEFAULT 'fact_orders_sync')
LANGUAGE plpgsql
AS $$
DECLARE
    -- v_exec_id: Holds the unique UUID generated for this specific batch execution run
    v_exec_id UUID;
    -- v_rows_moved: Tracks the count of rows successfully transferred from staging to fact_orders
    v_rows_moved INT := 0;
BEGIN
    -- STEP 1: INITIALIZE STATE MACHINE AUDIT LEDGER
    -- Create an entry in 'job_execution_log' marking this run as 'RUNNING'
    -- 'RETURNING execution_id INTO v_exec_id' captures the generated UUID to establish data lineage
    INSERT INTO job_execution_log (job_name, status)
    VALUES (p_job_name, 'RUNNING')
    RETURNING execution_id INTO v_exec_id;

    -- STEP 2: ENTER SUBTRANSACTION WITH EXCEPTION ISOLATION
    -- Any failure inside this BEGIN...EXCEPTION block will be trapped locally
    -- without crashing the database process or breaking open connection pools
    BEGIN
        -- Core Batch Operation: Transform from raw staging and load into dimensional warehouse
        INSERT INTO fact_orders (
            order_id,
            customer_id,
            product_id,
            order_date,
            quantity,
            unit_price,
            total_amount,   -- Computed column derived from (quantity * unit_price)
            execution_id,   -- Foreign Key reference linking this row to its execution batch
            synced_at       -- Timestamp indicating when this record reached the fact table
        )
        SELECT 
            s.order_id,
            s.customer_id,
            s.product_id,
            COALESCE(s.order_date, CURRENT_DATE),    -- Fallback to today if order_date was omitted
            s.quantity,
            s.unit_price,
            (s.quantity * s.unit_price) AS total_amount, -- Compute monetary amount dynamically
            v_exec_id,                               -- Attach batch execution lineage
            clock_timestamp()
        FROM staging_orders s
        -- Idempotency Guarantee: If the order_id already exists (e.g. from an earlier partial retry),
        -- update the metrics rather than failing on unique primary key violations
        ON CONFLICT (order_id) DO UPDATE 
        SET quantity = EXCLUDED.quantity,
            unit_price = EXCLUDED.unit_price,
            total_amount = EXCLUDED.total_amount,
            execution_id = EXCLUDED.execution_id,
            synced_at = clock_timestamp();

        -- Capture the number of rows inserted/updated in the statement above
        GET DIAGNOSTICS v_rows_moved = ROW_COUNT;

        -- STEP 3: CLEAN STAGING ENVIRONMENT
        -- Staging data has been committed to the fact table; wipe staging to prevent duplicate processing
        TRUNCATE staging_orders;

        -- STEP 4: TRANSITION STATE MACHINE TO SUCCESS
        -- Update the ledger with terminal status 'SUCCESS' and the completion timestamp
        UPDATE job_execution_log
        SET status = 'SUCCESS',
            finished_at = clock_timestamp()
        WHERE execution_id = v_exec_id;

        RAISE NOTICE 'Ingestion successful. Migrated % records into fact_orders.', v_rows_moved;

    -- STEP 5: TRAP RUNTIME EXCEPTIONS & RECORD DIAGNOSTICS
    -- Intercepts any unhandled failure (e.g., Check Constraint, Foreign Key, NOT NULL, Deadlock)
    EXCEPTION WHEN OTHERS THEN
        -- Record failure metadata into the state machine ledger:
        -- SQLSTATE: Standard 5-character ANSI error code (e.g., '23503' for FK, '23514' for Check)
        -- SQLERRM: Detailed error description string
        -- next_retry_at: Sets a 30-second backoff timestamp before the repair engine can attempt fixes
        UPDATE job_execution_log
        SET status = 'FAILED',
            error_code = SQLSTATE,
            error_message = SQLERRM,
            finished_at = clock_timestamp(),
            next_retry_at = clock_timestamp() + INTERVAL '30 seconds'
        WHERE execution_id = v_exec_id;

        -- Log warning to database console for administrative visibility
        RAISE WARNING 'Ingestion failed with SQLSTATE [%]: %. Dispatched to repair queue.', SQLSTATE, SQLERRM;
    END;
END;
$$;
