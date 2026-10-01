import psycopg2
import random
import time
from datetime import datetime

DB_CONFIG = {
    "dbname": "self_repair_db",
    "user": "postgres",
    "password": 1590 ,  # <-- Replace with your actual password
    "host": "localhost",
    "port": 5432
}

# Known dimension keys in PostgreSQL
VALID_CUSTOMERS = [1, 2, 3, 4]
VALID_PRODUCTS = {101: 500.00, 102: 150.00, 103: 50.00, 104: 300.00}

def generate_order(batch_id, order_seq):
    order_id = int(f"{batch_id}{order_seq:02d}")
    scenario = random.choices(
        population=["CLEAN", "POISON_FK", "POISON_QTY"],
        weights=[0.70, 0.15, 0.15],
        k=1
    )[0]

    if scenario == "CLEAN":
        cust_id = random.choice(VALID_CUSTOMERS)
        prod_id = random.choice(list(VALID_PRODUCTS.keys()))
        qty = random.randint(1, 5)
        price = VALID_PRODUCTS[prod_id]
        return (batch_id, order_id, cust_id, prod_id, qty, price, "CLEAN")

    elif scenario == "POISON_FK":
        # Violates foreign key constraint (customer 9999 does not exist)
        prod_id = random.choice(list(VALID_PRODUCTS.keys()))
        return (batch_id, order_id, 9999, prod_id, 2, VALID_PRODUCTS[prod_id], "POISON_FK")

    else: # POISON_QTY
        # Violates CHECK (quantity > 0)
        cust_id = random.choice(VALID_CUSTOMERS)
        prod_id = random.choice(list(VALID_PRODUCTS.keys()))
        return (batch_id, order_id, cust_id, prod_id, -1, VALID_PRODUCTS[prod_id], "POISON_QTY")

def inject_batch(batch_id):
    conn = psycopg2.connect(**DB_CONFIG)
    conn.autocommit = True
    cur = conn.cursor()

    orders = [generate_order(batch_id, i) for i in range(1, 6)]
    
    print(f"\n[{datetime.now().strftime('%H:%M:%S')}] ---> Injecting Batch {batch_id} (5 records)...")
    for o in orders:
        cur.execute("""
            INSERT INTO staging_orders (batch_id, order_id, customer_id, product_id, quantity, unit_price)
            VALUES (%s, %s, %s, %s, %s, %s)
        """, (o[0], o[1], o[2], o[3], o[4], o[5]))
        print(f"      Order {o[1]} | Status: {o[6]} | Cust: {o[2]} | Prod: {o[3]} | Qty: {o[4]}")

    conn.close()

def main():
    print("=" * 60)
    print("   SYNTHETIC CHAOS GENERATOR: INGESTION STRESS TEST")
    print("=" * 60)
    
    batch_counter = 500
    while True:
        batch_counter += 1
        inject_batch(batch_counter)
        print("Batch staged. Waiting 30 seconds for next cycle...")
        time.sleep(30)

if __name__ == "__main__":
    main()
