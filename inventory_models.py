"""
inventory_models.py
-------------------
Classical inventory optimization formulas used throughout the project.

Implements:
  - Economic Order Quantity  (EOQ)
  - Reorder Point            (ROP)
  - Safety Stock             (SS)  — both fixed-service-level and statistical
  - Days of Supply           (DOS)
  - Inventory Turnover Ratio (ITR)
  - Fill Rate                (FR)

Author : Samiya Sarker Hiya
"""

import numpy as np
import pandas as pd
from dataclasses import dataclass, field
from typing import Optional


# ── Data classes ─────────────────────────────────────────────────────────────

@dataclass
class SKUParameters:
    sku_id:            str
    annual_demand:     float   # units / year
    unit_cost_eur:     float   # € per unit
    ordering_cost_eur: float   # € per purchase order
    holding_rate:      float   # fraction of unit cost per year (e.g. 0.25)
    lead_time_days:    float   # average supplier lead time
    lead_time_std:     float   # std-dev of lead time (days)
    demand_std_daily:  float   # std-dev of daily demand
    service_level:     float   = 0.95  # e.g. 0.95 → Z = 1.645
    working_days:      int     = 365


@dataclass
class InventoryPolicy:
    sku_id:          str
    eoq:             float
    reorder_point:   float
    safety_stock:    float
    max_stock:       float
    annual_holding:  float
    annual_ordering: float
    total_cost:      float
    days_of_supply:  float


# ── Service-level → Z-score mapping ─────────────────────────────────────────

SERVICE_LEVEL_Z = {
    0.90: 1.282,
    0.91: 1.341,
    0.92: 1.405,
    0.93: 1.476,
    0.94: 1.555,
    0.95: 1.645,
    0.96: 1.751,
    0.97: 1.881,
    0.98: 2.054,
    0.99: 2.326,
}


def z_score(service_level: float) -> float:
    """Return the z-score for the nearest defined service level."""
    levels = np.array(list(SERVICE_LEVEL_Z.keys()))
    nearest = levels[np.argmin(np.abs(levels - service_level))]
    return SERVICE_LEVEL_Z[nearest]


# ── Core formulas ─────────────────────────────────────────────────────────────

def eoq(annual_demand: float, ordering_cost: float, holding_cost_per_unit: float) -> float:
    """
    Wilson's EOQ formula.
      Q* = sqrt( 2 * D * S / H )
    """
    if holding_cost_per_unit <= 0 or annual_demand <= 0:
        return 0.0
    return np.sqrt(2 * annual_demand * ordering_cost / holding_cost_per_unit)


def safety_stock_statistical(
    z:                float,
    lead_time_days:   float,
    lead_time_std:    float,
    demand_daily:     float,
    demand_std_daily: float,
) -> float:
    """
    Safety stock considering variability in BOTH demand and lead time.
      SS = Z * sqrt( LT * σ_d² + d̄² * σ_LT² )
    """
    variance = (lead_time_days * demand_std_daily**2
                + demand_daily**2 * lead_time_std**2)
    return z * np.sqrt(variance)


def reorder_point(
    demand_daily:  float,
    lead_time_days: float,
    safety_stock:  float,
) -> float:
    """ROP = average demand during lead time + safety stock."""
    return demand_daily * lead_time_days + safety_stock


def days_of_supply(avg_inventory: float, daily_demand: float) -> float:
    """How many days the current average stock covers."""
    if daily_demand <= 0:
        return np.inf
    return avg_inventory / daily_demand


def inventory_turnover(cogs: float, avg_inventory_value: float) -> float:
    """COGS ÷ Average Inventory Value."""
    if avg_inventory_value <= 0:
        return 0.0
    return cogs / avg_inventory_value


def fill_rate(units_sold: float, units_demanded: float) -> float:
    """Fraction of demand fulfilled from stock (no backorders)."""
    if units_demanded <= 0:
        return 1.0
    return min(1.0, units_sold / units_demanded)


# ── Policy builder ───────────────────────────────────────────────────────────

def build_inventory_policy(p: SKUParameters) -> InventoryPolicy:
    holding_cost  = p.unit_cost_eur * p.holding_rate          # € / unit / year
    daily_demand  = p.annual_demand / p.working_days

    q_star  = eoq(p.annual_demand, p.ordering_cost_eur, holding_cost)
    z       = z_score(p.service_level)
    ss      = safety_stock_statistical(
        z, p.lead_time_days, p.lead_time_std,
        daily_demand, p.demand_std_daily
    )
    rop     = reorder_point(daily_demand, p.lead_time_days, ss)
    max_stk = rop + q_star

    # Annual cost breakdown
    n_orders       = p.annual_demand / max(q_star, 1)
    ann_ordering   = n_orders * p.ordering_cost_eur
    ann_holding    = (q_star / 2 + ss) * holding_cost
    total          = ann_ordering + ann_holding

    dos = days_of_supply((q_star / 2 + ss), daily_demand)

    return InventoryPolicy(
        sku_id          = p.sku_id,
        eoq             = round(q_star, 1),
        reorder_point   = round(rop, 1),
        safety_stock    = round(ss, 1),
        max_stock       = round(max_stk, 1),
        annual_holding  = round(ann_holding, 2),
        annual_ordering = round(ann_ordering, 2),
        total_cost      = round(total, 2),
        days_of_supply  = round(dos, 1),
    )


# ── Batch analysis helper ────────────────────────────────────────────────────

def analyse_inventory_policies(params_list: list[SKUParameters]) -> pd.DataFrame:
    records = []
    for p in params_list:
        policy = build_inventory_policy(p)
        records.append({
            "SKU ID":           policy.sku_id,
            "EOQ (units)":      policy.eoq,
            "Reorder Point":    policy.reorder_point,
            "Safety Stock":     policy.safety_stock,
            "Max Stock":        policy.max_stock,
            "Annual Holding €": policy.annual_holding,
            "Annual Ordering €":policy.annual_ordering,
            "Total Cost €":     policy.total_cost,
            "Days of Supply":   policy.days_of_supply,
        })
    return pd.DataFrame(records)
