#!/bin/bash
# Phase 2 Step 2 — Dart Codemod: restaurants → stores
# Generated: 2026-04-12
#
# This script performs a dry-run preview by default.
# Pass --apply to actually modify files.
#
# Usage:
#   ./docs/phase_2_step_2_dart_codemod.sh          # preview only
#   ./docs/phase_2_step_2_dart_codemod.sh --apply  # apply changes

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRY_RUN=true
TOTAL_CHANGES=0
FILES_CHANGED=0

if [[ "${1:-}" == "--apply" ]]; then
  DRY_RUN=false
fi

echo "============================================"
echo "Phase 2 Step 2 — Dart Codemod: restaurants → stores"
echo "============================================"
if $DRY_RUN; then
  echo "MODE: preview (dry-run)"
  echo "Re-run with --apply to modify files."
else
  echo "MODE: APPLY (files will be modified in place)"
fi
echo ""

# ──────────────────────────────────────────────
# Build the list of target files
# ──────────────────────────────────────────────
DART_FILES=$(grep -rl 'restaurant' "$PROJECT_ROOT/lib/" --include='*.dart' 2>/dev/null || true)
TS_FILES=$(grep -rl 'restaurant' "$PROJECT_ROOT/supabase/functions/" --include='*.ts' 2>/dev/null || true)
ALL_FILES="$DART_FILES"$'\n'"$TS_FILES"
ALL_FILES=$(echo "$ALL_FILES" | sed '/^$/d' | sort -u)

if [[ -z "$ALL_FILES" ]]; then
  echo "No files with 'restaurant' references found. Nothing to do."
  exit 0
fi

# ──────────────────────────────────────────────
# apply_sed: runs sed expressions on a file
#   - In preview mode: copies file, applies sed, shows diff
#   - In apply mode: modifies file in place
# Arguments: $1 = file path, rest = sed expressions
# ──────────────────────────────────────────────
apply_sed() {
  local file="$1"
  shift
  local sed_args=("$@")

  if [[ ${#sed_args[@]} -eq 0 ]]; then
    return
  fi

  if $DRY_RUN; then
    local tmpfile
    tmpfile=$(mktemp)
    cp "$file" "$tmpfile"
    # Apply all sed expressions to the temp copy
    for expr in "${sed_args[@]}"; do
      sed -i '' "$expr" "$tmpfile"
    done
    local file_changes
    file_changes=$(diff "$file" "$tmpfile" | grep -c '^[<>]' || true)
    file_changes=$((file_changes / 2))
    if [[ $file_changes -gt 0 ]]; then
      local rel_path="${file#$PROJECT_ROOT/}"
      echo "--- $rel_path ($file_changes change(s)) ---"
      diff -u "$file" "$tmpfile" | head -80 || true
      echo ""
      TOTAL_CHANGES=$((TOTAL_CHANGES + file_changes))
      FILES_CHANGED=$((FILES_CHANGED + 1))
    fi
    rm -f "$tmpfile"
  else
    # Count changes before applying
    local tmpfile
    tmpfile=$(mktemp)
    cp "$file" "$tmpfile"
    for expr in "${sed_args[@]}"; do
      sed -i '' "$expr" "$file"
    done
    local file_changes
    file_changes=$(diff "$tmpfile" "$file" | grep -c '^[<>]' || true)
    file_changes=$((file_changes / 2))
    if [[ $file_changes -gt 0 ]]; then
      local rel_path="${file#$PROJECT_ROOT/}"
      echo "  MODIFIED: $rel_path ($file_changes change(s))"
      TOTAL_CHANGES=$((TOTAL_CHANGES + file_changes))
      FILES_CHANGED=$((FILES_CHANGED + 1))
    fi
    rm -f "$tmpfile"
  fi
}

# ══════════════════════════════════════════════
#  DART FILE RULES
# ══════════════════════════════════════════════

for file in $DART_FILES; do
  SED_EXPRS=()

  # ── Rule 1: Supabase table name strings ──
  # .from('restaurants') → .from('stores')
  SED_EXPRS+=("s/\.from('restaurants')/\.from('stores')/g")
  # .from('restaurant_settings') → .from('store_settings')
  SED_EXPRS+=("s/\.from('restaurant_settings')/\.from('store_settings')/g")

  # ── Rule 2: Column name strings in Supabase queries ──
  # .eq('restaurant_id'  → .eq('store_id'
  SED_EXPRS+=("s/\.eq('restaurant_id'/\.eq('store_id'/g")
  # .eq('orders.restaurant_id' → .eq('orders.store_id'
  SED_EXPRS+=("s/\.eq('orders\.restaurant_id'/\.eq('orders\.store_id'/g")
  # 'restaurant_id': (map/json literal keys)
  SED_EXPRS+=("s/'restaurant_id':/'store_id':/g")
  # json['restaurant_id'] and map['restaurant_id']
  SED_EXPRS+=("s/\['restaurant_id'\]/['store_id']/g")
  # row['restaurant_name'] (super_admin_screen)
  SED_EXPRS+=("s/\['restaurant_name'\]/['store_name']/g")
  # >> 'restaurant_id' (Supabase JSON operator)
  SED_EXPRS+=("s/>> 'restaurant_id'/>> 'store_id'/g")
  # 'p_restaurant_id': (RPC parameter keys)
  SED_EXPRS+=("s/'p_restaurant_id':/'p_store_id':/g")
  # 'p_restaurant_id' (in params maps without colon)
  SED_EXPRS+=("s/'p_restaurant_id'/'p_store_id'/g")
  # onConflict: 'restaurant_id'
  SED_EXPRS+=("s/onConflict: 'restaurant_id'/onConflict: 'store_id'/g")
  # .select('role, restaurant_id, ...') — embedded column names in select strings
  SED_EXPRS+=("s/'role, restaurant_id/'role, store_id/g")
  # orders!inner(restaurant_id, created_at) — embedded column in join select
  SED_EXPRS+=("s/(restaurant_id,/(store_id,/g")

  # ── Rule 3: RPC function name strings ──
  SED_EXPRS+=("s/'admin_create_restaurant'/'admin_create_store'/g")
  SED_EXPRS+=("s/'admin_update_restaurant_settings'/'admin_update_store_settings'/g")
  SED_EXPRS+=("s/'admin_update_restaurant'/'admin_update_store'/g")
  SED_EXPRS+=("s/'admin_deactivate_restaurant'/'admin_deactivate_store'/g")
  SED_EXPRS+=("s/'require_admin_actor_for_restaurant'/'require_admin_actor_for_store'/g")
  SED_EXPRS+=("s/'get_user_restaurant_id'/'get_user_store_id'/g")

  # ── Rule 4: Entity type technical identifiers ──
  # 'restaurants' => '매장'
  SED_EXPRS+=("s/'restaurants' => '매장'/'stores' => '매장'/g")
  # entity_type patterns — none found with exact 'entity_type', 'restaurants' but keep for safety

  # ── Rule 5: Class and type names (Dart) ──
  # Order matters: longer names first to avoid partial replacements
  SED_EXPRS+=("s/SuperAdminRestaurantReport/SuperAdminStoreReport/g")
  SED_EXPRS+=("s/SuperRestaurant/SuperStore/g")
  SED_EXPRS+=("s/RestaurantService/StoreService/g")
  # RestaurantSettings class (in waiter_screen.dart)
  SED_EXPRS+=("s/RestaurantSettings/StoreSettings/g")
  # _RestaurantMissingView (in menu_tab.dart, tables_tab.dart)
  SED_EXPRS+=("s/_RestaurantMissingView/_StoreMissingView/g")
  # _RestaurantsTab (in super_admin_screen.dart)
  SED_EXPRS+=("s/_RestaurantsTab/_StoresTab/g")

  # ── Rule 6: Variable and parameter names (Dart camelCase) ──
  # Longer compound names first to prevent partial matches
  SED_EXPRS+=("s/clearSelectedRestaurant/clearSelectedStore/g")
  SED_EXPRS+=("s/selectedRestaurantId/selectedStoreId/g")
  SED_EXPRS+=("s/selectedRestaurant/selectedStore/g")
  SED_EXPRS+=("s/filteredRestaurants/filteredStores/g")
  SED_EXPRS+=("s/createdRestaurantId/createdStoreId/g")
  SED_EXPRS+=("s/createdRestaurantName/createdStoreName/g")
  SED_EXPRS+=("s/overrideRestaurantId/overrideStoreId/g")
  SED_EXPRS+=("s/_initializedRestaurantId/_initializedStoreId/g")
  SED_EXPRS+=("s/_subscribedRestaurantId/_subscribedStoreId/g")
  SED_EXPRS+=("s/_restaurantNameController/_storeNameController/g")
  SED_EXPRS+=("s/_restaurantStep/_storeStep/g")
  SED_EXPRS+=("s/_ensureRestaurantLoaded/_ensureStoreLoaded/g")
  SED_EXPRS+=("s/_showRestaurantSheet/_showStoreSheet/g")
  SED_EXPRS+=("s/_loadStaffIfNeeded/_loadStaffIfNeeded/g")
  SED_EXPRS+=("s/restaurantSettingsProvider/storeSettingsProvider/g")
  SED_EXPRS+=("s/restaurantNameProvider/storeNameProvider/g")
  SED_EXPRS+=("s/restaurantService/storeService/g")
  SED_EXPRS+=("s/loadAllRestaurants/loadAllStores/g")
  SED_EXPRS+=("s/createRestaurant/createStore/g")
  SED_EXPRS+=("s/updateRestaurantSettings/updateStoreSettings/g")
  SED_EXPRS+=("s/updateRestaurant/updateStore/g")
  SED_EXPRS+=("s/deactivateRestaurant/deactivateStore/g")
  SED_EXPRS+=("s/addRestaurant/addStore/g")
  SED_EXPRS+=("s/selectRestaurant/selectStore/g")
  SED_EXPRS+=("s/sourceRestaurants/sourceStores/g")
  # restaurantData → storeData (settings_provider.dart)
  SED_EXPRS+=("s/restaurantData/storeData/g")
  # restaurantId → storeId (as Dart variable/parameter name)
  SED_EXPRS+=("s/restaurantId/storeId/g")
  # restaurantName → storeName (as Dart variable/parameter name)
  SED_EXPRS+=("s/restaurantName/storeName/g")
  # restaurantSettings → storeSettings (standalone variable)
  SED_EXPRS+=("s/restaurantSettings/storeSettings/g")
  # Remaining: restaurants (Dart variable) — must NOT match string literals already handled
  # Only match as identifier: preceded by word boundary or space/dot
  SED_EXPRS+=("s/\.restaurants/\.stores/g")
  # the 'restaurants' variable name in list context (e.g., "final restaurants =", "List<> restaurants")
  # Be conservative: match when preceded by a space (covers: final, List<>, var, =, etc.)
  SED_EXPRS+=("s/ restaurants/ stores/g")
  # restaurant as standalone variable name (careful: don't change comment text or string literals)
  # Match various Dart code patterns where 'restaurant' is a local variable
  SED_EXPRS+=("s/final restaurant /final store /g")
  SED_EXPRS+=("s/final restaurant\$/final store/g")
  # restaurant. → store. (accessing properties on restaurant variable)
  SED_EXPRS+=("s/restaurant\./store./g")
  # restaurant) → store) (closing parens)
  SED_EXPRS+=("s/restaurant)/store)/g")
  # restaurant, → store, (in parameter lists)
  SED_EXPRS+=("s/restaurant,/store,/g")
  # restaurant; → store; (end of statement)
  SED_EXPRS+=("s/restaurant;/store;/g")
  # restaurant? → store? (nullable access)
  SED_EXPRS+=("s/restaurant?/store?/g")
  # restaurant == or restaurant != (equality checks with space)
  SED_EXPRS+=("s/restaurant ==/store ==/g")
  SED_EXPRS+=("s/restaurant !=/store !=/g")
  # 'final restaurant in' (for-in loop variable)
  SED_EXPRS+=("s/final restaurant in/final store in/g")
  # 'final restaurant =' (local variable assignment)
  SED_EXPRS+=("s/final restaurant =/final store =/g")

  # ── SAFETY: Restore protected patterns that may have been over-matched ──
  # Icons.restaurant_menu — the broad restaurant. → store. rule would break this
  SED_EXPRS+=("s/Icons\.store_menu/Icons.restaurant_menu/g")
  # Icons.table_restaurant — the broad pattern might change this
  SED_EXPRS+=("s/Icons\.table_store/Icons.table_restaurant/g")
  # table_restaurant (in Icons.table_restaurant)
  SED_EXPRS+=("s/table_store/table_restaurant/g")
  # import paths: restaurant_service.dart must NOT change (file not renamed)
  SED_EXPRS+=("s/import '\.\.\/\.\.\/core\/services\/store_service\.dart'/import '\.\.\/\.\.\/core\/services\/restaurant_service.dart'/g")
  SED_EXPRS+=("s/services\/store_service\.dart/services\/restaurant_service.dart/g")
  # User-facing string literals that must stay as "Restaurant"
  # 'Restaurant Name' label
  SED_EXPRS+=("s/labelText: 'Store Name'/labelText: 'Restaurant Name'/g")
  # 'Restaurant' fallback display names
  SED_EXPRS+=("s/\.data('Store')/\.data('Restaurant')/g")
  SED_EXPRS+=("s/?? 'Store'/\?\? 'Restaurant'/g")
  SED_EXPRS+=("s/'Store',$/    'Restaurant',/g")
  # 'CREATE YOUR RESTAURANT'
  SED_EXPRS+=("s/'CREATE YOUR STORE'/'CREATE YOUR RESTAURANT'/g")
  # 'Restaurant Name' InputDecoration
  SED_EXPRS+=("s/InputDecoration(labelText: 'Store Name')/InputDecoration(labelText: 'Restaurant Name')/g")
  # 'Restaurant Info' section title
  SED_EXPRS+=("s/'Store Info'/'Restaurant Info'/g")
  # 'Only super_admin can create stores' — error messages with "restaurant" stay
  SED_EXPRS+=("s/can create stores/can create restaurants/g")
  # 'Failed to create store:' — keep as restaurant
  SED_EXPRS+=("s/Failed to create store:/Failed to create restaurant:/g")
  # 'Missing user or restaurant setup' — keep
  SED_EXPRS+=("s/Missing user or store setup/Missing user or restaurant setup/g")
  # 'Restaurant is not available.' — keep
  SED_EXPRS+=("s/Store is not available\./Restaurant is not available./g")
  # 'Restaurant not found for this account.' — keep
  SED_EXPRS+=("s/Store not found for this account\./Restaurant not found for this account./g")
  # 'Restaurant updated', 'Restaurant created', 'Restaurant deactivated' toasts
  SED_EXPRS+=("s/'Store updated'/'Restaurant updated'/g")
  SED_EXPRS+=("s/'Store created'/'Restaurant created'/g")
  SED_EXPRS+=("s/'Store deactivated'/'Restaurant deactivated'/g")
  # 'Add Restaurant' button label
  SED_EXPRS+=("s/Text('Add Store')/Text('Add Restaurant')/g")
  SED_EXPRS+=("s/'Add Store'/'Add Restaurant'/g")
  # 'Edit Restaurant' / 'Add Restaurant' in sheet titles
  SED_EXPRS+=("s/'Edit Store'/'Edit Restaurant'/g")
  # Navigation label 'Restaurants'
  SED_EXPRS+=("s/'Stores', 0/'Restaurants', 0/g")
  # 'RESTAURANTS' header
  SED_EXPRS+=("s/'STORES'/'RESTAURANTS'/g")
  # 'All Restaurants' dropdown
  SED_EXPRS+=("s/'All Stores'/'All Restaurants'/g")
  # 'Forbidden: cannot create staff for another restaurant' — TS comment but check Dart too
  SED_EXPRS+=("s/for another store/for another restaurant/g")
  # receipt_builder.dart: restaurantName is a parameter name → storeName, which is fine
  # BUT the label display is not a string literal with 'Restaurant' so it's safe
  # admin_audit_trace_panel.dart: '생성', '수정' etc are the values, keys are RPC names already handled
  # 'Restaurants' label in _brandRows return type
  SED_EXPRS+=("s/_groupByBrand ? 'Brand' : 'Store'/_groupByBrand ? 'Brand' : 'Restaurant'/g")

  apply_sed "$file" "${SED_EXPRS[@]}"
done

# ══════════════════════════════════════════════
#  TYPESCRIPT (Edge Function) RULES
# ══════════════════════════════════════════════

for file in $TS_FILES; do
  SED_EXPRS=()

  # ── Broadest rule: restaurant_id → store_id everywhere in TS ──
  # In edge functions, restaurant_id is ALWAYS a DB column / RPC param / object key.
  # There are no Flutter SDK constants to protect. Safe to do a global replace.
  SED_EXPRS+=("s/restaurant_id/store_id/g")

  # ── Variable names (camelCase) ──
  # restaurantIds before restaurantId (longer first)
  SED_EXPRS+=("s/restaurantIds/storeIds/g")
  SED_EXPRS+=("s/restaurantId/storeId/g")
  # byRestaurant → byStore
  SED_EXPRS+=("s/byRestaurant/byStore/g")
  # restaurants (variable name) → stores
  SED_EXPRS+=("s/restaurants/stores/g")
  # processed_restaurant_count → processed_store_count
  SED_EXPRS+=("s/processed_restaurant_count/processed_store_count/g")

  # restError — keep as-is (it's just a local variable name, not semantically tied to "restaurant")

  # ── SAFETY: Restore user-facing strings and comments ──
  # 'Forbidden: cannot create staff for another restaurant' — user-facing error
  SED_EXPRS+=("s/for another store/for another restaurant/g")
  # '// admin can only create staff for their own restaurant' — comment
  SED_EXPRS+=("s/their own store/their own restaurant/g")
  # Korean comments mentioning 레스토랑 are fine — sed won't match them since they
  # don't contain the ASCII word "restaurant"

  apply_sed "$file" "${SED_EXPRS[@]}"
done

# ══════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════
echo ""
echo "============================================"
echo "SUMMARY"
echo "============================================"
echo "  Files changed: $FILES_CHANGED"
echo "  Total changes: $TOTAL_CHANGES"

if $DRY_RUN; then
  echo ""
  echo "This was a DRY RUN. No files were modified."
  echo "Run with --apply to apply changes."
fi

# ══════════════════════════════════════════════
#  LEFTOVER CHECK
# ══════════════════════════════════════════════
echo ""
echo "============================================"
echo "LEFTOVER CHECK — remaining 'restaurant' references"
echo "============================================"

if $DRY_RUN; then
  echo "(Dry-run mode: checking what would remain AFTER applying changes)"
  echo ""
fi

# Patterns that are EXPECTED to remain (allowlist)
ALLOWLIST_PATTERN='Icons\.restaurant|Icons\.table_restaurant|import.*restaurant_service\.dart|restaurant_menu'
# Also allow: user-facing strings, comments
ALLOWLIST_PATTERN="$ALLOWLIST_PATTERN|'Restaurant Name'|'Restaurant'|\"Restaurant\"|'Add Restaurant'|'Edit Restaurant'|'Restaurants'|'All Restaurants'|'RESTAURANTS'"
ALLOWLIST_PATTERN="$ALLOWLIST_PATTERN|'Restaurant updated'|'Restaurant created'|'Restaurant deactivated'|'Restaurant Info'"
ALLOWLIST_PATTERN="$ALLOWLIST_PATTERN|Restaurant not found|Restaurant is not|create restaurants|create restaurant:|restaurant setup"
ALLOWLIST_PATTERN="$ALLOWLIST_PATTERN|another restaurant|their own restaurant|'Brand' : 'Restaurant'"
ALLOWLIST_PATTERN="$ALLOWLIST_PATTERN|CREATE YOUR RESTAURANT"
# Error messages in super_admin_provider that are user-facing
ALLOWLIST_PATTERN="$ALLOWLIST_PATTERN|Failed to load restaurants|Failed to create restaurant|Failed to update restaurant|Failed to deactivate restaurant"
# User-facing strings: 'do not have permission.*restaurant', 'does not support buffet'
ALLOWLIST_PATTERN="$ALLOWLIST_PATTERN|for this restaurant|permission to create an order"
# Error strings with 'restaurant' used as natural language
ALLOWLIST_PATTERN="$ALLOWLIST_PATTERN|This restaurant does not|restaurant context missing"

if $DRY_RUN; then
  # In preview mode, replay the exact same sed rules on temp copies then grep for leftovers.
  # We use the same apply_sed mechanism but on copies.
  LEFTOVER=""
  LEFTOVER_TS=""

  for file in $DART_FILES; do
    tmpfile=$(mktemp)
    cp "$file" "$tmpfile"
    # Replay ALL Dart sed rules (must mirror the main loop above)
    sed -i '' \
      -e "s/\.from('restaurants')/\.from('stores')/g" \
      -e "s/\.from('restaurant_settings')/\.from('store_settings')/g" \
      -e "s/\.eq('restaurant_id'/\.eq('store_id'/g" \
      -e "s/\.eq('orders\.restaurant_id'/\.eq('orders\.store_id'/g" \
      -e "s/'restaurant_id':/'store_id':/g" \
      -e "s/\['restaurant_id'\]/['store_id']/g" \
      -e "s/\['restaurant_name'\]/['store_name']/g" \
      -e "s/>> 'restaurant_id'/>> 'store_id'/g" \
      -e "s/'p_restaurant_id'/'p_store_id'/g" \
      -e "s/onConflict: 'restaurant_id'/onConflict: 'store_id'/g" \
      -e "s/'role, restaurant_id/'role, store_id/g" \
      -e "s/(restaurant_id,/(store_id,/g" \
      -e "s/'admin_create_restaurant'/'admin_create_store'/g" \
      -e "s/'admin_update_restaurant_settings'/'admin_update_store_settings'/g" \
      -e "s/'admin_update_restaurant'/'admin_update_store'/g" \
      -e "s/'admin_deactivate_restaurant'/'admin_deactivate_store'/g" \
      -e "s/'require_admin_actor_for_restaurant'/'require_admin_actor_for_store'/g" \
      -e "s/'get_user_restaurant_id'/'get_user_store_id'/g" \
      -e "s/'restaurants' => '매장'/'stores' => '매장'/g" \
      -e "s/SuperAdminRestaurantReport/SuperAdminStoreReport/g" \
      -e "s/SuperRestaurant/SuperStore/g" \
      -e "s/RestaurantService/StoreService/g" \
      -e "s/RestaurantSettings/StoreSettings/g" \
      -e "s/_RestaurantMissingView/_StoreMissingView/g" \
      -e "s/_RestaurantsTab/_StoresTab/g" \
      -e "s/clearSelectedRestaurant/clearSelectedStore/g" \
      -e "s/selectedRestaurantId/selectedStoreId/g" \
      -e "s/selectedRestaurant/selectedStore/g" \
      -e "s/filteredRestaurants/filteredStores/g" \
      -e "s/createdRestaurantId/createdStoreId/g" \
      -e "s/createdRestaurantName/createdStoreName/g" \
      -e "s/overrideRestaurantId/overrideStoreId/g" \
      -e "s/_initializedRestaurantId/_initializedStoreId/g" \
      -e "s/_subscribedRestaurantId/_subscribedStoreId/g" \
      -e "s/_restaurantNameController/_storeNameController/g" \
      -e "s/_restaurantStep/_storeStep/g" \
      -e "s/_ensureRestaurantLoaded/_ensureStoreLoaded/g" \
      -e "s/_showRestaurantSheet/_showStoreSheet/g" \
      -e "s/restaurantSettingsProvider/storeSettingsProvider/g" \
      -e "s/restaurantNameProvider/storeNameProvider/g" \
      -e "s/restaurantService/storeService/g" \
      -e "s/loadAllRestaurants/loadAllStores/g" \
      -e "s/createRestaurant/createStore/g" \
      -e "s/updateRestaurantSettings/updateStoreSettings/g" \
      -e "s/updateRestaurant/updateStore/g" \
      -e "s/deactivateRestaurant/deactivateStore/g" \
      -e "s/addRestaurant/addStore/g" \
      -e "s/selectRestaurant/selectStore/g" \
      -e "s/sourceRestaurants/sourceStores/g" \
      -e "s/restaurantData/storeData/g" \
      -e "s/restaurantId/storeId/g" \
      -e "s/restaurantName/storeName/g" \
      -e "s/restaurantSettings/storeSettings/g" \
      -e "s/\.restaurants/\.stores/g" \
      -e "s/ restaurants/ stores/g" \
      -e "s/restaurant\./store./g" \
      -e "s/restaurant)/store)/g" \
      -e "s/restaurant,/store,/g" \
      -e "s/restaurant;/store;/g" \
      -e "s/restaurant?/store?/g" \
      -e "s/restaurant ==/store ==/g" \
      -e "s/restaurant !=/store !=/g" \
      -e "s/final restaurant in/final store in/g" \
      -e "s/final restaurant =/final store =/g" \
      -e "s/Icons\.store_menu/Icons.restaurant_menu/g" \
      -e "s/table_store/table_restaurant/g" \
      -e "s/services\/store_service\.dart/services\/restaurant_service.dart/g" \
      "$tmpfile"
    local_leftover=$(grep -n 'restaurant' "$tmpfile" 2>/dev/null | grep -ivE "$ALLOWLIST_PATTERN" || true)
    if [[ -n "$local_leftover" ]]; then
      rel_path="${file#$PROJECT_ROOT/}"
      while IFS= read -r line; do
        LEFTOVER="${LEFTOVER}${rel_path}:${line}"$'\n'
      done <<< "$local_leftover"
    fi
    rm -f "$tmpfile"
  done

  for file in $TS_FILES; do
    tmpfile=$(mktemp)
    cp "$file" "$tmpfile"
    sed -i '' \
      -e "s/restaurant_id/store_id/g" \
      -e "s/restaurantIds/storeIds/g" \
      -e "s/restaurantId/storeId/g" \
      -e "s/byRestaurant/byStore/g" \
      -e "s/restaurants/stores/g" \
      -e "s/processed_restaurant_count/processed_store_count/g" \
      -e "s/for another store/for another restaurant/g" \
      -e "s/their own store/their own restaurant/g" \
      "$tmpfile"
    local_leftover=$(grep -n 'restaurant' "$tmpfile" 2>/dev/null | grep -ivE "$ALLOWLIST_PATTERN" || true)
    if [[ -n "$local_leftover" ]]; then
      rel_path="${file#$PROJECT_ROOT/}"
      while IFS= read -r line; do
        LEFTOVER_TS="${LEFTOVER_TS}${rel_path}:${line}"$'\n'
      done <<< "$local_leftover"
    fi
    rm -f "$tmpfile"
  done
else
  LEFTOVER=$(grep -rn 'restaurant' "$PROJECT_ROOT/lib/" --include='*.dart' 2>/dev/null | grep -ivE "$ALLOWLIST_PATTERN" || true)
  LEFTOVER_TS=$(grep -rn 'restaurant' "$PROJECT_ROOT/supabase/functions/" --include='*.ts' 2>/dev/null | grep -ivE "$ALLOWLIST_PATTERN" || true)
fi

if [[ -n "$LEFTOVER" || -n "$LEFTOVER_TS" ]]; then
  echo "WARNING: The following references were NOT changed and are not in the allowlist:"
  echo ""
  if [[ -n "$LEFTOVER" ]]; then
    echo "$LEFTOVER" | while IFS= read -r line; do
      echo "  [DART] $line"
    done
  fi
  if [[ -n "$LEFTOVER_TS" ]]; then
    echo "$LEFTOVER_TS" | while IFS= read -r line; do
      echo "  [TS]   $line"
    done
  fi
  echo ""
  echo "Review these manually to determine if they need changing."
else
  echo "No unexpected 'restaurant' references found. All clear."
fi

echo ""
echo "Done."
