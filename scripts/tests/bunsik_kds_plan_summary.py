"""Summarize nested auto_explain plans without copying fixture payloads."""
from pathlib import Path
import json
import sys

source = Path(sys.argv[1]).read_text()
decoder = json.JSONDecoder()
position = 0
plans = []
while position < len(source):
    start = source.find("{", position)
    if start < 0:
        break
    try:
        value, size = decoder.raw_decode(source[start:])
        position = start + size
    except json.JSONDecodeError:
        position = start + 1
        continue
    if isinstance(value, dict) and "Plan" in value:
        plans.append(value)

relations = []
def walk(node, number):
    relation = node.get("Relation Name")
    if relation:
        rows = (node.get("Actual Rows", 0) + node.get("Rows Removed by Filter", 0)) * node.get("Actual Loops", 1)
        relations.append({"plan": number, "relation": relation, "node": node["Node Type"],
                          "rows_examined": rows, "loops": node.get("Actual Loops", 1)})
    for child in node.get("Plans", []):
        walk(child, number)

for number, plan in enumerate(plans):
    walk(plan["Plan"], number)
watched = {"order_items", "orders", "emergency_order_queue", "emergency_fulfillment_items",
           "emergency_combo_component_items", "emergency_floor_direct_items",
           "emergency_fulfillment_events", "emergency_floor_ready_lots", "emergency_tray_ready_lots"}
large = [row for row in relations if row["relation"] in watched and row["rows_examined"] > 10000]
result = {"nested_plans": len(plans), "business_scan_limit": 10000,
          "large_business_scans": large, "relation_scans": relations}
Path(sys.argv[2]).write_text(json.dumps(result, indent=2) + "\n")
if not plans or large:
    raise SystemExit("Unexpected broad business-table scan in scoped history/snapshot")
print("BUNSIK_NESTED_SCAN_SCOPE=PASS no_business_scan_over_10000_rows")
