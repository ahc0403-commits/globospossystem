Project: /Users/andreahn/globos_pos_system
Task: Fix staff account creation so staff can actually log in.

## Problem
Current staff creation in StaffTab inserts a placeholder auth_id into users table.
Staff cannot log in because there is no real Supabase Auth account.

## Why not use service_role key in Flutter?
Embedding service_role key in the app is a security violation.
The solution is a Supabase Edge Function that runs server-side with service_role.

## Solution: Supabase Edge Function

### Step 1: Create Edge Function

Create file: supabase/functions/create_staff_user/index.ts

```typescript
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // 1. Verify caller is admin or super_admin using their JWT
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Create anon client to verify caller's role
    const anonClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    )

    const { data: { user: callerUser }, error: callerError } = await anonClient.auth.getUser()
    if (callerError || !callerUser) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Check caller role from users table
    const { data: callerProfile, error: profileError } = await anonClient
      .from('users')
      .select('role, restaurant_id')
      .eq('auth_id', callerUser.id)
      .single()

    if (profileError || !callerProfile) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    if (!['admin', 'super_admin'].includes(callerProfile.role)) {
      return new Response(JSON.stringify({ error: 'Forbidden: admin role required' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // 2. Parse request body
    const { email, password, full_name, role, restaurant_id } = await req.json()

    if (!email || !password || !full_name || !role || !restaurant_id) {
      return new Response(JSON.stringify({ error: 'Missing required fields: email, password, full_name, role, restaurant_id' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // admin can only create staff for their own restaurant
    if (callerProfile.role === 'admin' && callerProfile.restaurant_id !== restaurant_id) {
      return new Response(JSON.stringify({ error: 'Forbidden: cannot create staff for another restaurant' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // admin cannot create another admin or super_admin
    if (callerProfile.role === 'admin' && ['admin', 'super_admin'].includes(role)) {
      return new Response(JSON.stringify({ error: 'Forbidden: cannot create admin accounts' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // 3. Create auth user using service_role (server-side only)
    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    )

    const { data: newAuthUser, error: authError } = await serviceClient.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name },
    })

    if (authError || !newAuthUser.user) {
      return new Response(JSON.stringify({ error: authError?.message ?? 'Failed to create auth user' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // 4. Insert into users table
    const { data: newUser, error: insertError } = await serviceClient
      .from('users')
      .insert({
        auth_id: newAuthUser.user.id,
        restaurant_id,
        role,
        full_name,
        is_active: true,
      })
      .select()
      .single()

    if (insertError) {
      // Rollback: delete the auth user we just created
      await serviceClient.auth.admin.deleteUser(newAuthUser.user.id)
      return new Response(JSON.stringify({ error: insertError.message }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    return new Response(
      JSON.stringify({ success: true, user: newUser }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
```

### Step 2: Deploy the Edge Function

Run these commands in the terminal:
```bash
cd /Users/andreahn/globos_pos_system
supabase functions deploy create_staff_user --project-ref ynriuoomotxuwhuxxmhj
```

### Step 3: Update staff_provider.dart

In lib/features/admin/providers/staff_provider.dart,
replace the createStaff method with one that calls the Edge Function:

Find the existing createStaff method and replace its implementation:

```dart
Future<void> createStaff({
  required String restaurantId,
  required String email,
  required String password,
  required String fullName,
  required String role,
}) async {
  state = state.copyWith(isCreating: true, error: null);
  try {
    final response = await supabase.functions.invoke(
      'create_staff_user',
      body: {
        'email': email,
        'password': password,
        'full_name': fullName,
        'role': role,
        'restaurant_id': restaurantId,
      },
    );

    if (response.status != 200) {
      final errorData = response.data;
      final errorMsg = errorData is Map ? errorData['error'] ?? 'Failed to create staff' : 'Failed to create staff';
      state = state.copyWith(isCreating: false, error: errorMsg.toString());
      return;
    }

    state = state.copyWith(isCreating: false, error: null);
    await loadStaff(restaurantId);
  } catch (e) {
    state = state.copyWith(isCreating: false, error: e.toString());
  }
}
```

### Step 4: Update staff_tab.dart

The Add Staff bottom sheet currently has: Name, Email, Role fields.
Add a Password field:

In the bottom sheet form, add a password TextField after the email field:
- Label: "Password"  
- obscureText: true
- Required field
- Hint: "Minimum 8 characters"

Update the onSubmit to pass password to createStaff().

Remove any placeholder auth_id logic or "share email" dialog.
Instead show a success toast: "Staff account created. They can now log in with their email and password."

### Step 5: Update deleteStaff / toggleActive

When deactivating a staff member, also disable their Supabase Auth account.
Create another Edge Function OR just update is_active in users table (simpler, since
login still works but the app checks is_active and shows error).

Actually: just update is_active = false in users table.
Add check in auth_provider.dart _fetchUserProfile:
If user.is_active == false → call logout() and show "Account disabled" error.

In auth_provider.dart, in _fetchUserProfile, after fetching role/restaurant_id:
```dart
final isActive = data['is_active'] as bool? ?? true;
if (!isActive) {
  await supabase.auth.signOut();
  state = const PosAuthState(errorMessage: '비활성화된 계정입니다. 관리자에게 문의하세요.');
  return;
}
```

Update the select query to include is_active:
```dart
.select('role, restaurant_id, is_active')
```

---

## Rules
- Do NOT put service_role key in Flutter code anywhere
- Deploy the edge function before updating Flutter code
- Run flutter analyze after changes
- Run flutter build macos to verify
- git add -A && git commit -m "feat: staff creation via Edge Function - real Supabase Auth accounts, disabled account check" && git push
