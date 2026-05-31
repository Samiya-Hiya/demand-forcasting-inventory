"""
generate_data.py
----------------
Generates a realistic synthetic retail supply chain dataset
for demand forecasting and inventory optimization analysis.

Author : Samiya Sarker Hiya
Course  : M.Sc. Operational Research & Business Analytics,
          Otto-von-Guericke University Magdeburg
"""

import pandas as pd
import numpy as np
from datetime import datetime, timedelta
import os

# ── Reproducibility ─────────────────────────────────────────────────────────
np.random.seed(42)

# ── Configuration ───────────────────────────────────────────────────────────
START_DATE   = datetime(2021, 1, 1)
END_DATE     = datetime(2023, 12, 31)
SKUS         = {
    "SKU-001": {"name": "Industrial Bearing Set",   "category": "Mechanical",  "base_demand": 120, "lead_time_days": 14},
    "SKU-002": {"name": "Electronic Control Unit",  "category": "Electronics", "base_demand":  55, "lead_time_days": 21},
    "SKU-003": {"name": "Hydraulic Pump Assembly",  "category": "Hydraulic",   "base_demand":  40, "lead_time_days": 28},
    "SKU-004": {"name": "Safety Valve Kit",         "category": "Safety",      "base_demand":  90, "lead_time_days":  7},
    "SKU-005": {"name": "Conveyor Belt Module",     "category": "Mechanical",  "base_demand":  70, "lead_time_days": 18},
}
SUPPLIERS    = ["SupplierA-DE", "SupplierB-CN", "SupplierC-PL", "SupplierD-CZ"]
WAREHOUSES   = ["Berlin-HUB", "Hamburg-HUB", "Munich-HUB"]


def date_range(start: datetime, end: datetime) -> pd.DatetimeIndex:
    return pd.date_range(start=start, end=end, freq="D")


def seasonal_factor(date: pd.Timestamp) -> float:
    """Q4 surge + mild summer dip matching industrial supply patterns."""
    month = date.month
    if month in [11, 12]:   return 1.35
    if month in [1, 2]:     return 0.85
    if month in [7, 8]:     return 0.90
    return 1.0


def generate_demand_series() -> pd.DataFrame:
    dates  = date_range(START_DATE, END_DATE)
    rows   = []
    for sku_id, meta in SKUS.items():
        trend     = np.linspace(0, 0.15, len(dates))          # +15 % growth over period
        noise     = np.random.normal(0, 0.12, len(dates))
        for i, d in enumerate(dates):
            sf       = seasonal_factor(d)
            demand   = max(0, round(
                meta["base_demand"] * sf * (1 + trend[i]) * (1 + noise[i]) / 30
            ))                                                  # daily units
            rows.append({
                "date":       d,
                "sku_id":     sku_id,
                "sku_name":   meta["name"],
                "category":   meta["category"],
                "daily_demand": demand,
            })
    df = pd.DataFrame(rows)
    df["date"] = pd.to_datetime(df["date"])
    return df


def generate_inventory_transactions(demand_df: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for sku_id, meta in SKUS.items():
        stock   = meta["base_demand"] * 2           # opening stock
        sku_d   = demand_df[demand_df["sku_id"] == sku_id].sort_values("date")
        for _, row in sku_d.iterrows():
            sold  = min(stock, row["daily_demand"])
            stock -= sold
            # Replenishment trigger
            reorder_point = meta["base_demand"] * meta["lead_time_days"] / 30 * 1.5
            replenish     = 0
            if stock < reorder_point:
                replenish = round(meta["base_demand"] * 2)
                stock    += replenish
            rows.append({
                "date":           row["date"],
                "sku_id":         sku_id,
                "opening_stock":  stock + sold - replenish,
                "demand":         row["daily_demand"],
                "units_sold":     sold,
                "replenishment":  replenish,
                "closing_stock":  stock,
                "warehouse":      np.random.choice(WAREHOUSES),
                "supplier":       np.random.choice(SUPPLIERS),
                "unit_cost_eur":  round(np.random.uniform(15, 200), 2),
                "stockout_flag":  int(sold < row["daily_demand"]),
            })
    return pd.DataFrame(rows)


def generate_supplier_lead_times(demand_df: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for sku_id, meta in SKUS.items():
        n_orders = 60
        for _ in range(n_orders):
            promised = meta["lead_time_days"]
            actual   = max(1, promised + int(np.random.normal(0, 4)))
            rows.append({
                "sku_id":            sku_id,
                "supplier":          np.random.choice(SUPPLIERS),
                "promised_lt_days":  promised,
                "actual_lt_days":    actual,
                "delay_days":        actual - promised,
                "on_time":           int(actual <= promised),
                "order_date":        START_DATE + timedelta(days=int(np.random.uniform(0, 700))),
            })
    return pd.DataFrame(rows)


def main():
    out = os.path.join(os.path.dirname(__file__), "..", "data")
    os.makedirs(out, exist_ok=True)

    print("⟳  Generating demand series …")
    demand_df = generate_demand_series()
    demand_df.to_csv(f"{out}/daily_demand.csv", index=False)
    print(f"   ✓  daily_demand.csv  ({len(demand_df):,} rows)")

    print("⟳  Generating inventory transactions …")
    inv_df = generate_inventory_transactions(demand_df)
    inv_df.to_csv(f"{out}/inventory_transactions.csv", index=False)
    print(f"   ✓  inventory_transactions.csv  ({len(inv_df):,} rows)")

    print("⟳  Generating supplier lead-time records …")
    lt_df = generate_supplier_lead_times(demand_df)
    lt_df.to_csv(f"{out}/supplier_lead_times.csv", index=False)
    print(f"   ✓  supplier_lead_times.csv  ({len(lt_df):,} rows)")

    print("\n✅  All datasets written to /data/")


if __name__ == "__main__":
    main()
