---
title: "Phase 2 Step 2 — Edge Function References"
version: "1.0"
date: "2026-04-12"
status: "static analysis complete"
---

# Phase 2 Step 2 — Edge Function References

## Summary
- Total edge function files with references: **3**
- Total occurrences: **39**

---

## File 1: `supabase/functions/create_staff_user/index.ts`

**Occurrences: 9**

| Line | Context | Classification |
|------|---------|----------------|
| 47 | `.select('role, restaurant_id')` | Column reference (select) |
| 69 | `const { email, password, full_name, role, restaurant_id } = await req.json()` | Destructured request field |
| 71 | `if (!email \|\| !password \|\| !full_name \|\| !role \|\| !restaurant_id)` | Validation check |
| 75 | `'Missing required fields: email, password, full_name, role, restaurant_id'` | UI/error string |
| 84 | `// admin can only create staff for their own restaurant` | Comment |
| 87 | `callerProfile.restaurant_id !== restaurant_id` | Column comparison |
| 91 | `error: 'Forbidden: cannot create staff for another restaurant'` | UI/error string |
| 145 | `restaurant_id,` | Insert field (into `users` table) |

---

## File 2: `supabase/functions/generate_delivery_settlement/index.ts`

**Occurrences: 21**

| Line | Context | Classification |
|------|---------|----------------|
| 7 | `// 2. 레스토랑별 external_sales 집계` | Comment (Korean) |
| 76 | `const { data: restaurants, error: restError } = await supabase` | Variable name |
| 78 | `.select('restaurant_id, gross_amount')` | Column reference (select) |
| 86 | `if (!restaurants?.length)` | Variable name |
| 94 | `const byRestaurant = new Map<string, { gross: number }>()` | Variable name |
| 95 | `for (const row of restaurants)` | Variable name |
| 96 | `const entry = byRestaurant.get(row.restaurant_id) ?? { gross: 0 }` | Column access + variable |
| 98 | `byRestaurant.set(row.restaurant_id, entry)` | Column access + variable |
| 103 | `for (const [restaurantId, summary] of byRestaurant.entries())` | Variable name (destructured) |
| 108 | `.eq('restaurant_id', restaurantId)` | Column reference (filter) |
| 117 | `restaurant_id: restaurantId,` | Insert field (delivery_settlements) |
| 142 | `restaurant_id: restaurantId,` | Error result field |
| 152 | `.select('id, restaurant_id, period_label')` | Column reference (select) |
| 183 | `.eq('restaurant_id', restaurantId)` | Column reference (filter) |
| 194 | `restaurant_id: restaurantId,` | Result field |
| 204 | `restaurantId,` | Console log variable |
| 209 | `restaurant_id: restaurantId,` | Error result field |
| 218 | `processed_restaurant_count: byRestaurant.size,` | Variable name in response |

---

## File 3: `supabase/functions/generate-settlement/index.ts`

**Occurrences: 9**

| Line | Context | Classification |
|------|---------|----------------|
| 44 | `const { data: restaurants } = await supabase` | Variable name |
| 46 | `.select("restaurant_id")` | Column reference (select) |
| 53 | `const restaurantIds = [` | Variable name |
| 54 | `...new Set(restaurants?.map((r: any) => r.restaurant_id) ?? []),` | Column access + variable |
| 59 | `for (const rid of restaurantIds)` | Variable name (derived) |
| 64 | `.eq("restaurant_id", rid)` | Column reference (filter) |
| 80 | `restaurant_id: rid,` | Insert field (delivery_settlements) |
| 151 | `JSON.stringify({ processed: restaurantIds.length, periodLabel, results }),` | Variable name in response |

---

## Classification Summary (Edge Functions)

| Category | Count |
|----------|-------|
| Column references (select/filter/insert with `'restaurant_id'`) | 19 |
| Variable names (`restaurants`, `restaurantId`, `restaurantIds`, `byRestaurant`) | 13 |
| UI/error strings | 3 |
| Comments | 2 |
| Request body destructuring | 2 |
| **Total** | **39** |

---

## Migration Notes

All three edge functions reference `restaurant_id` as a column name that maps to database tables (`users`, `external_sales`, `delivery_settlements`). When the database column is renamed from `restaurant_id` to `store_id`, these edge functions must be updated in lockstep with the migration. The `generate_delivery_settlement` function is the most heavily affected with 21 occurrences.
