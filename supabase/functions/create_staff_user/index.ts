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

    // admin can only create staff for their own restaurant
    if (
      callerProfile.role === 'admin' &&
      callerProfile.restaurant_id !== restaurant_id
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

    // admin cannot create another admin or super_admin
    if (
      callerProfile.role === 'admin' &&
      ['admin', 'super_admin'].includes(role)
    ) {
      return new Response(
        JSON.stringify({ error: 'Forbidden: cannot create admin accounts' }),
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
