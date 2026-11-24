-- ICT371 Advanced Database | Question 7: Water Meter Readings and Billing
-- PostgreSQL. Run the whole file in one go (psql -f, or the pgAdmin Query Tool).

DROP SCHEMA IF EXISTS q7_water CASCADE;
CREATE SCHEMA q7_water;
SET search_path = q7_water, public;

------------------------------------------------------------------
-- (a) Database
------------------------------------------------------------------
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INT           NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading  >= 0),
    CONSTRAINT ck_reading_month_start
        CHECK (reading_month = date_trunc('month', reading_month)::date),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INT           NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

------------------------------------------------------------------
-- (b) Function: fn_water_charge  (first 10 units K5, above 10 units K8)
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption must be a non-negative number, got %', p_units;
    END IF;

    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);
    END IF;
    RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);
END;
$$;

------------------------------------------------------------------
-- (d) Trigger first, so seed readings are checked too
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_check_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;   -- raising above aborts the statement, so nothing is stored
END;
$$;

CREATE TRIGGER trg_check_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_reading();

------------------------------------------------------------------
-- (c) Procedure: pr_generate_bill
------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql
SET search_path = q7_water, public
AS $$
DECLARE
    v_prev NUMERIC;
    v_curr NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
      FROM readings
     WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading: %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_curr - v_prev), 0, p_due_on);
END;
$$;

------------------------------------------------------------------
-- (a, continued) Seed data: zero, exactly 10 and above 10 units
------------------------------------------------------------------
INSERT INTO customers (full_name) VALUES ('Gift Mwanza'), ('Hope Chanda'), ('Isaac Sinkala');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
 (1, DATE '2026-09-01', 100.00, 100.00),   -- 0 units
 (1, DATE '2026-10-01', 100.00, 110.00),   -- exactly 10 units
 (2, DATE '2026-09-01',  50.00,  62.50),   -- 12.5 units
 (2, DATE '2026-10-01',  62.50,  70.00),   -- 7.5 units
 (3, DATE '2026-09-01', 200.00, 225.00),   -- 25 units
 (3, DATE '2026-10-01', 225.00, 235.00);   -- exactly 10 units

-- Bills: some already overdue, some not yet due
CALL pr_generate_bill(1, CURRENT_DATE - 40);
CALL pr_generate_bill(2, CURRENT_DATE - 10);
CALL pr_generate_bill(3, CURRENT_DATE - 30);
CALL pr_generate_bill(4, CURRENT_DATE + 15);
CALL pr_generate_bill(5, CURRENT_DATE - 20);
CALL pr_generate_bill(6, CURRENT_DATE + 20);

-- Payments: bill 3 part-paid, bill 5 fully paid, bill 2 untouched
UPDATE bills SET amount_paid = 50.00  WHERE bill_id = 3;
UPDATE bills SET amount_paid = charge WHERE bill_id = 5;

SELECT b.bill_id, r.reading_id, r.current_reading - r.previous_reading AS units,
       b.charge, b.amount_paid, b.due_on
  FROM bills b JOIN readings r USING (reading_id) ORDER BY b.bill_id;

------------------------------------------------------------------
-- (e) View: v_overdue_bills
------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
  FROM bills b
  JOIN readings r  ON r.reading_id  = b.reading_id
  JOIN customers c ON c.customer_id = r.customer_id
 WHERE b.due_on < CURRENT_DATE
   AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills ORDER BY due_on;

------------------------------------------------------------------
-- (f) Index: date-based search for overdue (unpaid) bills
------------------------------------------------------------------
-- Partial index: only bills that still owe money are indexed. Settled bills
-- (the vast majority over time) never appear in an overdue search, so the
-- index stays small, and the range on due_on is read in order.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

SET enable_seqscan = off;
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
  FROM bills
 WHERE amount_paid < charge
   AND due_on < CURRENT_DATE;
RESET enable_seqscan;

------------------------------------------------------------------
-- (g) Scheduled job
------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
SET search_path = q7_water, public
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
      FROM bills
     WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
       SET total_due = EXCLUDED.total_due;   -- replaces, never adds
END;
$$;

-- pg_cron: daily at 00:30.
--   CREATE EXTENSION IF NOT EXISTS pg_cron;   (one-off, superuser)
SELECT cron.schedule(
    'water-receivables-snapshot',
    '30 0 * * *',
    $$CALL q7_water.pr_refresh_receivables()$$
);
SELECT jobid, jobname, schedule, command FROM cron.job;

------------------------------------------------------------------
-- Tests
------------------------------------------------------------------
CALL pr_refresh_receivables();
CALL pr_refresh_receivables();   -- rerun: same total, one row
SELECT * FROM receivable_snapshot;

-- Tariff boundaries: 0 -> 0.00, 10 -> 50.00, 12.5 -> 70.00, 25 -> 170.00
SELECT fn_water_charge(0) AS zero, fn_water_charge(10) AS ten,
       fn_water_charge(12.5) AS twelve_five, fn_water_charge(25) AS twenty_five;

DO $$ BEGIN PERFORM fn_water_charge(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(-1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(99, CURRENT_DATE);        -- unknown reading
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);         -- already billed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

-- Trigger: a bad reading is rejected and not stored
SELECT COUNT(*) AS readings_before FROM readings;
DO $$ BEGIN
    INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
    VALUES (1, DATE '2026-11-01', 110, 100);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN
    UPDATE readings SET current_reading = 1 WHERE reading_id = 2;   -- below previous
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_after FROM readings;

-- Constraint: amount_paid may not exceed charge
DO $$ BEGIN UPDATE bills SET amount_paid = charge + 1 WHERE bill_id = 1;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
