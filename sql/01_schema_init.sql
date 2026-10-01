-- ============================================================================
-- 01_schema_init.sql
-- Autonomous Self-Healing SQL Pipeline: Schema & Initial Master Data
-- DDL: Extensions, Enums, Dim, Fact, Staging & DLQ tables
-- ============================================================================

-- Optional / Recommended: Extension for UUID generation
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. Create State Machine ENUM
CREATE TYPE job_status AS ENUM (
    'PENDING', 
    'RUNNING', 
    'SUCCESS', 
    'FAILED', 
    'REPAIRING', 
    'QUARANTINED'
);

-- 2. Create the Execution Audit Ledger (State Machine)
CREATE TABLE job_execution_log (
    execution_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_name VARCHAR(64) NOT NULL,
    status job_status DEFAULT 'PENDING',
    attempt_count INT DEFAULT 0,
    max_retries INT DEFAULT 3,
    error_code TEXT,
    error_message TEXT,
    next_retry_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    started_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    finished_at TIMESTAMPTZ
);

-- 3. Create Master Dimension Tables
CREATE TABLE dim_customers (
    customer_id INT PRIMARY KEY,
    customer_name VARCHAR(100) NOT NULL,
    segment VARCHAR(50) NOT NULL,       -- Enterprise, SMB, Consumer
    region VARCHAR(50) NOT NULL         -- North, South, East, West
);

CREATE TABLE dim_products (
    product_id INT PRIMARY KEY,
    product_name VARCHAR(100) NOT NULL,
    category VARCHAR(50) NOT NULL,       -- Software, SaaS, Hardware
    unit_price NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0)
);

-- 4. Create Ingestion Staging Table (Raw & Unvalidated)
CREATE TABLE staging_orders (
    batch_id INT,
    order_id INT,
    customer_id INT,
    product_id INT,
    order_date DATE DEFAULT CURRENT_DATE,
    quantity INT,
    unit_price NUMERIC(10, 2)
);

-- 5. Create Core Fact Table (Target Warehouse with Lineage)
CREATE TABLE fact_orders (
    order_id INT PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES dim_customers(customer_id),
    product_id INT NOT NULL REFERENCES dim_products(product_id),
    order_date DATE NOT NULL,
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    total_amount NUMERIC(10, 2) NOT NULL CHECK (total_amount > 0),
    execution_id UUID REFERENCES job_execution_log(execution_id),
    synced_at TIMESTAMPTZ DEFAULT clock_timestamp()
);

-- 6. Create the Dead-Letter Queue (DLQ)
CREATE TABLE dead_letter_quarantine (
    quarantine_id BIGSERIAL PRIMARY KEY,
    execution_id UUID REFERENCES job_execution_log(execution_id) ON DELETE CASCADE,
    source_table VARCHAR(64) NOT NULL,
    raw_record JSONB NOT NULL,
    rejection_reason TEXT,
    quarantined_at TIMESTAMPTZ DEFAULT clock_timestamp()
);

-- 7. Seed Initial Dimension Master Data
INSERT INTO dim_customers (customer_id, customer_name, segment, region) VALUES
(1, 'TechCorp Global', 'Enterprise', 'West'),
(2, 'Apex Retailers', 'SMB', 'North'),
(3, 'Global Cargo Co', 'Enterprise', 'South'),
(4, 'Vertex Solutions', 'SMB', 'East')
ON CONFLICT (customer_id) DO NOTHING;

INSERT INTO dim_products (product_id, product_name, category, unit_price) VALUES
(101, 'Data Lake Platform', 'Software', 500.00),
(102, 'API Connector Pro', 'SaaS', 150.00),
(103, 'BI Cloud Seat', 'SaaS', 50.00),
(104, 'Edge Router V2', 'Hardware', 300.00)
ON CONFLICT (product_id) DO NOTHING;
