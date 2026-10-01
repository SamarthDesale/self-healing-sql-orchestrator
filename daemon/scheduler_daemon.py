import psycopg2
import time
from datetime import datetime

# ============================================================================
# DATABASE CONFIGURATION
# Update 'password' to your pgAdmin postgres password
# ============================================================================
DB_CONFIG = {
    "dbname": "self_repair_db",
    "user": "postgres",
    "password": 1590 ,  # <-- Replace with your actual password
    "host": "localhost",
    "port": 5432
}

def call_procedure(proc_name):
    conn = None
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute(f"CALL {proc_name}();")
            print(f"[{datetime.now().strftime('%H:%M:%S')}] Triggered: {proc_name}()")
    except Exception as e:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] Execution error in {proc_name}(): {e}")
    finally:
        if conn:
            conn.close()

def main():
    print("=" * 65)
    print("   AUTONOMOUS SELF-HEALING DATABASE DAEMON ACTIVE")
    print("   Ingestion Cadence: Every 20 seconds | Watchdog: Every 10 seconds")
    print("=" * 65)
    print("Press Ctrl + C to stop.\n")

    tick = 0
    while True:
        tick += 1
        
        # 1. Trigger Watchdog / Repair Sweep every 10 seconds
        call_procedure("run_self_repair_engine")

        # 2. Trigger Main ETL Ingestion every 20 seconds (every 2nd tick)
        if tick % 2 == 0:
            call_procedure("run_order_ingestion")

        time.sleep(10)

if __name__ == "__main__":
    main()