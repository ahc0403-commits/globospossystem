Project: /Users/andreahn/globos_pos_system
Flutter Native macOS/iOS/Android POS.

## Problem to fix
Design spec says super_admin and admin must have DIFFERENT screens.
Currently both go to the same AdminScreen — this is wrong.

Design spec (ROLES.md):
- super_admin: cross-restaurant access, can CREATE/EDIT restaurants, view ALL restaurants' data
- admin: single restaurant only, cannot create restaurants, manages own restaurant

## What needs to be built

---

### 1. lib/features/super_admin/super_admin_screen.dart

A completely separate screen for super_admin role.

Layout: Left sidebar (220px) + main content area (macOS optimized)

Sidebar nav items:
- Restaurants (Icons.store) ← default
- All Reports (Icons.bar_chart)
- System Settings (Icons.settings)
- Logout button at bottom

#### Tab 1: Restaurants Management

Provider: super_admin_provider.dart (see below)

Content:
- Header: "RESTAURANTS" in BebasNeue 28px amber + "Add Restaurant" button (amber, top right)
- List of ALL restaurants (cards):
  Each card:
  - Restaurant name in BebasNeue 24px
  - Slug / address in small textSecondary
  - Operation mode badge (standard=grey, buffet=amber, hybrid=blue)
  - Active/inactive status dot
  - "Manage" button → opens edit sheet
  - "Go to Admin" button → switches context to that restaurant's admin view
    (sets a selectedRestaurantId in state, navigates to AdminScreen passing restaurantId)

Add Restaurant bottom sheet:
- Name (required)
- Address
- Slug (required, auto-generated from name but editable)
- Operation Mode dropdown (standard/buffet/hybrid)
- Per Person Charge (shown only if buffet or hybrid)
- SAVE button

Edit Restaurant bottom sheet:
- Same fields as Add, pre-filled
- SAVE button + DELETE (soft delete: set is_active=false)

#### Tab 2: All Reports

- Dropdown to select restaurant (or "All Restaurants")
- Same date range picker as admin reports
- Summary cards: Total Revenue across selected scope
- Per-restaurant revenue breakdown table:
  | Restaurant | Dine-in | Delivery | Total |
- Uses same report_provider.dart logic but fetches across all restaurants
  when super_admin (bypass RLS using service approach or fetch per restaurant)

#### Tab 3: System Settings

Simple read-only info panel:
- Logged-in user info (email, role)
- App version: "GLOBOS POS v1.0.0"
- Supabase project reference (from .env SUPABASE_URL domain)
- Logout button (large, full width, red outlined)

---

### 2. lib/features/super_admin/super_admin_provider.dart

StateNotifierProvider<SuperAdminNotifier, SuperAdminState>

SuperAdminState:
- List<Restaurant> restaurants
- Restaurant? selectedRestaurant  (for context switching)
- bool isLoading
- String? error

Restaurant model (reuse or define here):
- id, name, slug, address, operationMode, perPersonCharge, isActive, createdAt

SuperAdminNotifier:
- loadAllRestaurants(): fetch ALL restaurants (super_admin bypasses RLS via service_role or
  since super_admin has cross-restaurant RLS policy, just fetch normally)
  Order by created_at desc
- addRestaurant(name, address, slug, operationMode, perPersonCharge):
    INSERT into restaurants
    Reload list
- updateRestaurant(id, name, address, slug, operationMode, perPersonCharge):
    UPDATE restaurants WHERE id
    Reload list
- deactivateRestaurant(id):
    UPDATE restaurants SET is_active=false WHERE id
    Reload list
- selectRestaurant(Restaurant r): update selectedRestaurant in state

---

### 3. Update lib/core/router/app_router.dart

Add new route:
  GoRoute(path: '/super-admin', builder: (_, __) => const SuperAdminScreen())

Update redirect logic:
- role == 'super_admin' AND restaurantId != null → '/super-admin'  (NOT '/admin')
- role == 'admin' → '/admin' (unchanged)

Remove the existing:
  case 'super_admin': return '/admin';

Replace with:
  case 'super_admin': return '/super-admin';

---

### 4. lib/features/admin/admin_screen.dart — minor update

The AdminScreen should show a banner/badge when accessed by super_admin
"acting as" a specific restaurant (context-switching from SuperAdminScreen).

Add optional constructor param: restaurantId (overrides authProvider restaurantId)
If this param is passed, show a top banner: "Acting as: [restaurant name] — Back to System Admin"
with a back arrow that returns to /super-admin

Actually, keep it simple for now:
- Just ensure AdminScreen reads restaurantId from authProvider only
- No context switching needed in this iteration

---

### 5. Design rules
- Background: AppColors.surface0 (#111210)
- Sidebar: AppColors.surface1 (#1C1D1A)
- Cards: AppColors.surface1 with radius 16
- Accent: AppColors.amber500 (#F5A623)
- Text: AppColors.textPrimary (#F0EDE6)
- Secondary: AppColors.textSecondary (#9E9B92)
- Badges: small rounded containers with appropriate colors
- BebasNeue for headings/numbers, NotoSansKR for body
- Import AppColors and supabase from '../../main.dart'
- Never call supabase directly from widgets

---

### Rules:
- Run flutter analyze and fix ALL errors
- After analyze passes: flutter build macos
- git add -A && git commit -m "feat: super_admin screen - restaurant management + all-reports + system settings, separated from admin screen" && git push
