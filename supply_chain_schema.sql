-- =============================================================================
-- supply_chain_schema.sql
-- =============================================================================
-- Creates the relational schema and loads data for supply chain analytics.
-- Run against SQLite (used in the notebook) or any SQL-compatible engine.
--
-- Author  : Samiya Sarker Hiya
-- Context : M.Sc. Operational Research & Business Analytics,
--           Otto-von-Guericke University Magdeburg
-- =============================================================================


-- ── Tables ───────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS dim_sku (
    sku_id      TEXT PRIMARY KEY,
    sku_name    TEXT NOT NULL,
    category    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_supplier (
    supplier_id   TEXT PRIMARY KEY,
    country_code  TEXT,
    tier          INTEGER   -- 1 = preferred, 2 = approved, 3 = conditional
);

CREATE TABLE IF NOT EXISTS dim_warehouse (
    warehouse_id  TEXT PRIMARY KEY,
    city          TEXT,
    region        TEXT
);

CREATE TABLE IF NOT EXISTS fact_inventory (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    date             DATE    NOT NULL,
    sku_id           TEXT    REFERENCES dim_sku(sku_id),
    warehouse_id     TEXT    REFERENCES dim_warehouse(warehouse_id),
    supplier_id      TEXT    REFERENCES dim_supplier(supplier_id),
    opening_stock    REAL,
    demand           REAL,
    units_sold       REAL,
    replenishment    REAL,
    closing_stock    REAL,
    unit_cost_eur    REAL,
    stockout_flag    INTEGER
);

CREATE TABLE IF NOT EXISTS fact_lead_times (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    sku_id           TEXT    REFERENCES dim_sku(sku_id),
    supplier_id      TEXT    REFERENCES dim_supplier(supplier_id),
    order_date       DATE,
    promised_lt_days INTEGER,
    actual_lt_days   INTEGER,
    delay_days       INTEGER,
    on_time          INTEGER
);


-- =============================================================================
-- ANALYTICAL QUERIES
-- =============================================================================

-- ── Q1: Monthly demand by SKU ────────────────────────────────────────────────
-- Used for trend visualisation and seasonality detection.

SELECT
    strftime('%Y-%m', date)   AS year_month,
    sku_id,
    SUM(demand)               AS total_demand,
    SUM(units_sold)           AS total_sold,
    SUM(demand - units_sold)  AS lost_sales,
    ROUND(
        SUM(units_sold) * 1.0 / NULLIF(SUM(demand), 0) * 100, 2
    )                         AS fill_rate_pct
FROM  fact_inventory
GROUP BY year_month, sku_id
ORDER BY year_month, sku_id;


-- ── Q2: Stockout frequency per SKU ──────────────────────────────────────────

SELECT
    sku_id,
    COUNT(*)                                      AS total_days,
    SUM(stockout_flag)                            AS stockout_days,
    ROUND(SUM(stockout_flag) * 100.0 / COUNT(*), 2) AS stockout_rate_pct,
    SUM(demand - units_sold)                      AS total_lost_units
FROM  fact_inventory
GROUP BY sku_id
ORDER BY stockout_rate_pct DESC;


-- ── Q3: Supplier on-time delivery performance ────────────────────────────────

SELECT
    supplier_id,
    COUNT(*)                                            AS total_orders,
    SUM(on_time)                                        AS on_time_orders,
    ROUND(SUM(on_time) * 100.0 / COUNT(*), 2)          AS otd_rate_pct,
    ROUND(AVG(actual_lt_days), 1)                       AS avg_actual_lt,
    ROUND(AVG(promised_lt_days), 1)                     AS avg_promised_lt,
    ROUND(AVG(delay_days), 1)                           AS avg_delay_days,
    MAX(delay_days)                                     AS max_delay_days
FROM  fact_lead_times
GROUP BY supplier_id
ORDER BY otd_rate_pct DESC;


-- ── Q4: Inventory turnover by SKU (annual) ───────────────────────────────────

SELECT
    sku_id,
    ROUND(SUM(units_sold * unit_cost_eur), 2)                         AS cogs_eur,
    ROUND(AVG((opening_stock + closing_stock) / 2 * unit_cost_eur), 2) AS avg_inv_value,
    ROUND(
        SUM(units_sold * unit_cost_eur) /
        NULLIF(AVG((opening_stock + closing_stock) / 2 * unit_cost_eur), 0),
        2
    )                                                                  AS inv_turnover_ratio
FROM  fact_inventory
GROUP BY sku_id
ORDER BY inv_turnover_ratio DESC;


-- ── Q5: Warehouse utilisation summary ───────────────────────────────────────

SELECT
    warehouse_id,
    COUNT(DISTINCT sku_id)                   AS skus_handled,
    SUM(replenishment)                       AS total_inbound_units,
    SUM(units_sold)                          AS total_outbound_units,
    ROUND(AVG(closing_stock), 1)             AS avg_closing_stock,
    SUM(stockout_flag)                       AS total_stockout_days
FROM  fact_inventory
GROUP BY warehouse_id
ORDER BY total_outbound_units DESC;


-- ── Q6: Rolling 30-day average demand (window function) ─────────────────────

SELECT
    date,
    sku_id,
    demand,
    AVG(demand) OVER (
        PARTITION BY sku_id
        ORDER BY date
        ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS rolling_30d_avg_demand
FROM  fact_inventory
ORDER BY sku_id, date;


-- ── Q7: Top 20 % of SKUs by revenue (Pareto / ABC analysis) ─────────────────

WITH sku_revenue AS (
    SELECT
        sku_id,
        SUM(units_sold * unit_cost_eur)  AS revenue_eur
    FROM  fact_inventory
    GROUP BY sku_id
),
ranked AS (
    SELECT
        sku_id,
        revenue_eur,
        SUM(revenue_eur) OVER ()                                       AS total_revenue,
        SUM(revenue_eur) OVER (ORDER BY revenue_eur DESC)              AS cumulative_revenue,
        ROUND(
            SUM(revenue_eur) OVER (ORDER BY revenue_eur DESC) * 100.0
            / SUM(revenue_eur) OVER (), 2
        )                                                               AS cumulative_pct
    FROM sku_revenue
)
SELECT
    sku_id,
    ROUND(revenue_eur, 2)   AS revenue_eur,
    cumulative_pct,
    CASE
        WHEN cumulative_pct <= 80 THEN 'A — High Value'
        WHEN cumulative_pct <= 95 THEN 'B — Medium Value'
        ELSE                           'C — Low Value'
    END                     AS abc_class
FROM ranked
ORDER BY revenue_eur DESC;
