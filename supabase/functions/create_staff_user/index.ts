import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const ALLOWED_ORIGINS = (Deno.env.get('ALLOWED_ORIGINS') ?? '').split(',').filter(Boolean)

const corsHeaders = {
  'Access-Control-Allow-Origin': ALLOWED_ORIGINS[0] ?? '',
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
      { global: { headers: { Authorization: authHeader } } },
    )

    const {
      data: { user: callerUser },
      error: callerError,
    } = await anonClient.auth.getUser()
    if (callerError || !callerUser) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // Check caller role from users table
    const { data: callerProfile, error: profileError } = await anonClient
      .from('users')
      .select('id, role, restaurant_id, primary_store_id, brand_id')
      .eq('auth_id', callerUser.id)
      .single()

    if (profileError || !callerProfile) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    if (
      !['admin', 'store_admin', 'brand_admin', 'super_admin'].includes(
        callerProfile.role,
      )
    ) {
      return new Response(
        JSON.stringify({ error: 'Forbidden: admin role required' }),
        {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        },
      )
    }

    // 2. Parse request body
    const { email, password, full_name, role, restaurant_id } = await req.json()

    if (!email || !password || !full_name || !role || !restaurant_id) {
      return new Response(
        JSON.stringify({
          error:
            'Missing required fields: email, password, full_name, role, restaurant_id',
        }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        },
      )
    }

    const supportedRoles = [
      'waiter',
      'kitchen',
      'cashier',
      'admin',
      'store_admin',
      'brand_admin',
      'photo_objet_master',
      'photo_objet_store_admin',
    ]

    if (!supportedRoles.includes(role)) {
      return new Response(
        JSON.stringify({ error: `Unsupported role: ${role}` }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        },
      )
    }

    const { data: targetStore, error: targetStoreError } = await anonClient
      .from('restaurants')
      .select('id, brand_id, is_active')
      .eq('id', restaurant_id)
      .single()

    if (targetStoreError || !targetStore) {
      return new Response(JSON.stringify({ error: 'Target store not found' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    if (targetStore.is_active === false) {
      return new Response(JSON.stringify({ error: 'Target store is inactive' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    if (
      ['brand_admin', 'photo_objet_master'].includes(role) &&
      !targetStore.brand_id
    ) {
      return new Response(
        JSON.stringify({
          error: 'Target store must belong to a brand for brand-scoped roles',
        }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        },
      )
    }

    const callerStoreId = callerProfile.primary_store_id ?? callerProfile.restaurant_id

    // store-scoped admins can only create staff for their own store
    if (
      ['admin', 'store_admin'].includes(callerProfile.role) &&
      callerStoreId !== restaurant_id
    ) {
      return new Response(
        JSON.stringify({
          error: 'Forbidden: cannot create staff for another restaurant',
        }),
        {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        },
      )
    }

    if (
      callerProfile.role === 'brand_admin' &&
      callerProfile.brand_id !== targetStore.brand_id
    ) {
      return new Response(
        JSON.stringify({
          error: 'Forbidden: cannot create staff for another brand',
        }),
        {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        },
      )
    }

    // store-scoped admins cannot create elevated admin roles
    if (
      ['admin', 'store_admin'].includes(callerProfile.role) &&
      [
        'admin',
        'store_admin',
        'brand_admin',
        'super_admin',
        'photo_objet_master',
        'photo_objet_store_admin',
      ].includes(role)
    ) {
      return new Response(
        JSON.stringify({ error: 'Forbidden: cannot create admin accounts' }),
        {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        },
      )
    }

    if (
      callerProfile.role === 'brand_admin' &&
      ['brand_admin', 'super_admin', 'photo_objet_master'].includes(role)
    ) {
      return new Response(
        JSON.stringify({ error: 'Forbidden: cannot create this role' }),
        {
          status: 403,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        },
      )
    }

    // 3. Create auth user using service_role (server-side only)
    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    )

    const { data: newAuthUser, error: authError } =
      await serviceClient.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { full_name },
      })

    if (authError || !newAuthUser.user) {
      return new Response(
        JSON.stringify({
          error: authError?.message ?? 'Failed to create auth user',
        }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        },
      )
    }

    // 4. Insert into users table
    const { data: newUser, error: insertError } = await serviceClient
      .from('users')
      .insert({
        auth_id: newAuthUser.user.id,
        restaurant_id,
        brand_id: targetStore.brand_id,
        primary_store_id: restaurant_id,
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

    const { error: storeAccessError } = await serviceClient
      .from('user_store_access')
      .upsert(
        {
          user_id: newUser.id,
          store_id: restaurant_id,
          is_primary: true,
          is_active: true,
          source_type: 'direct',
          granted_by: callerProfile.id,
        },
        { onConflict: 'user_id,store_id,source_type' },
      )

    if (storeAccessError) {
      await serviceClient.from('users').delete().eq('id', newUser.id)
      await serviceClient.auth.admin.deleteUser(newAuthUser.user.id)
      return new Response(JSON.stringify({ error: storeAccessError.message }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    if (role === 'brand_admin' || role === 'photo_objet_master') {
      const { error: brandAccessError } = await serviceClient
        .from('user_brand_access')
        .upsert(
          {
            user_id: newUser.id,
            brand_id: targetStore.brand_id,
            is_active: true,
            granted_by: callerProfile.id,
          },
          { onConflict: 'user_id,brand_id' },
        )

      if (brandAccessError) {
        await serviceClient.from('user_store_access').delete().eq('user_id', newUser.id)
        await serviceClient.from('users').delete().eq('id', newUser.id)
        await serviceClient.auth.admin.deleteUser(newAuthUser.user.id)
        return new Response(JSON.stringify({ error: brandAccessError.message }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        })
      }

      const { error: syncError } = await serviceClient.rpc(
        'sync_user_store_access',
        {
          p_user_id: newUser.id,
        },
      )
      if (syncError) {
        console.error('sync_user_store_access error:', syncError)
      }
    }

    const { error: refreshClaimsError } = await serviceClient.rpc('refresh_user_claims', {
      p_auth_user_id: newAuthUser.user.id,
    })
    if (refreshClaimsError) {
      console.error('refresh_user_claims error:', refreshClaimsError)
    }

    return new Response(JSON.stringify({ success: true, user: newUser }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    console.error('create_staff_user error:', err)
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
