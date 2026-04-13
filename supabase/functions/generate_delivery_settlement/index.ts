// generate_delivery_settlement/index.ts
// Supabase Edge Function — 2주 정산 생성
// 호출: cron (매월 1일, 16일) 또는 수동 invoke
//
// 흐름:
// 1. 정산 기간 결정 (전반기 A / 후반기 B)
// 2. 레스토랑별 external_sales 집계
// 3. delivery_settlements 헤더 생성
// 4. delivery_settlement_items 차감 항목 생성
// 5. external_sales.settlement_id 연결

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'

const PLATFORM_COMMISSION_RATE = 0.015  // 1.5%
const ESTIMATED_PAYMENT_FEE_RATE = 0.015  // ~1.5% (카드/페이 평균)

serve(async (req) => {
  try {
    // 인증: CRON_SECRET 또는 service_role JWT 필수
    const authHeader = req.headers.get('Authorization') ?? ''
    const cronSecret = Deno.env.get('CRON_SECRET')
    if (!cronSecret) {
      console.error('CRON_SECRET not configured')
      return new Response(JSON.stringify({ error: 'Server misconfigured' }), { status: 500 })
    }
    if (authHeader !== `Bearer ${cronSecret}`) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401 })
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    // 1. 정산 기간 결정
    const now = new Date()
    const body = await req.json().catch(() => ({}))
    // 수동 호출 시 기간 지정 가능 (날짜 형식 검증)
    let periodStart: string
    let periodEnd: string
    let periodLabel: string

    const dateRegex = /^\d{4}-\d{2}-\d{2}$/
    const labelRegex = /^\d{4}-\d{2}-[AB]$/

    if (body.period_start && body.period_end && body.period_label) {
      if (!dateRegex.test(body.period_start) || !dateRegex.test(body.period_end) || !labelRegex.test(body.period_label)) {
        return new Response(JSON.stringify({ error: 'Invalid date format. Expected YYYY-MM-DD for dates and YYYY-MM-A/B for label' }), { status: 400 })
      }
      periodStart = body.period_start
      periodEnd = body.period_end
      periodLabel = body.period_label
    } else {
      const year = now.getFullYear()
      const month = now.getMonth() + 1
      const day = now.getDate()

      if (day <= 15) {
        // 16일 실행 → 당월 전반기 (1~15일)
        periodStart = `${year}-${String(month).padStart(2, '0')}-01`
        periodEnd = `${year}-${String(month).padStart(2, '0')}-15`
        periodLabel = `${year}-${String(month).padStart(2, '0')}-A`
      } else {
        // 1일 실행 → 전월 후반기 (16~말일)
        const lastMonth = month === 1 ? 12 : month - 1
        const lastMonthYear = month === 1 ? year - 1 : year
        const lastDay = new Date(lastMonthYear, lastMonth, 0).getDate()
        periodStart = `${lastMonthYear}-${String(lastMonth).padStart(2, '0')}-16`
        periodEnd = `${lastMonthYear}-${String(lastMonth).padStart(2, '0')}-${lastDay}`
        periodLabel = `${lastMonthYear}-${String(lastMonth).padStart(2, '0')}-B`
      }
    }

    // 2. 미정산 주문이 있는 레스토랑 조회
    const { data: restaurants, error: restError } = await supabase
      .from('external_sales')
      .select('restaurant_id, gross_amount')
      .eq('is_revenue', true)
      .eq('order_status', 'completed')
      .is('settlement_id', null)
      .gte('completed_at', `${periodStart}T00:00:00+07:00`)
      .lte('completed_at', `${periodEnd}T23:59:59+07:00`)

    if (restError) throw restError
    if (!restaurants?.length) {
      return new Response(JSON.stringify({
        message: 'No unsettled orders found',
        period: periodLabel
      }), { status: 200 })
    }

    // 레스토랑별 그룹핑
    const byRestaurant = new Map<string, { gross: number }>()
    for (const row of restaurants) {
      const entry = byRestaurant.get(row.restaurant_id) ?? { gross: 0 }
      entry.gross += Number(row.gross_amount)
      byRestaurant.set(row.restaurant_id, entry)
    }

    const results: Array<Record<string, unknown>> = []

    for (const [restaurantId, summary] of byRestaurant.entries()) {
      try {
        const { data: existingSettlement, error: existingError } = await supabase
          .from('delivery_settlements')
          .select('id')
          .eq('restaurant_id', restaurantId)
          .eq('source_system', 'deliberry')
          .eq('period_label', periodLabel)
          .maybeSingle()

        if (existingError) throw existingError

        if (existingSettlement != null) {
          results.push({
            restaurant_id: restaurantId,
            period_label: periodLabel,
            skipped: true,
            reason: 'SETTLEMENT_ALREADY_EXISTS',
          })
          continue
        }

        const grossTotal = Number(summary.gross.toFixed(2))
        const platformCommission = Number(
          (grossTotal * PLATFORM_COMMISSION_RATE).toFixed(2),
        )
        const paymentFee = Number(
          (grossTotal * ESTIMATED_PAYMENT_FEE_RATE).toFixed(2),
        )
        const totalDeductions = Number(
          (platformCommission + paymentFee).toFixed(2),
        )
        const netSettlement = Number(
          (grossTotal - totalDeductions).toFixed(2),
        )

        const { data: settlement, error: insertSettlementError } = await supabase
          .from('delivery_settlements')
          .insert({
            restaurant_id: restaurantId,
            source_system: 'deliberry',
            period_start: periodStart,
            period_end: periodEnd,
            period_label: periodLabel,
            gross_total: grossTotal,
            total_deductions: totalDeductions,
            net_settlement: netSettlement,
            status: 'calculated',
          })
          .select('id, restaurant_id, period_label')
          .single()

        if (insertSettlementError) throw insertSettlementError

        const { error: itemInsertError } = await supabase
          .from('delivery_settlement_items')
          .insert([
            {
              settlement_id: settlement.id,
              item_type: 'platform_commission',
              amount: platformCommission,
              description: '플랫폼 수수료 1.5%',
              reference_rate: PLATFORM_COMMISSION_RATE,
              reference_base: grossTotal,
            },
            {
              settlement_id: settlement.id,
              item_type: 'payment_fee',
              amount: paymentFee,
              description: '결제 수수료 (평균 1.5%)',
              reference_rate: ESTIMATED_PAYMENT_FEE_RATE,
              reference_base: grossTotal,
            },
          ])

        if (itemInsertError) throw itemInsertError

        const { data: updatedSales, error: salesUpdateError } = await supabase
          .from('external_sales')
          .update({ settlement_id: settlement.id })
          .eq('restaurant_id', restaurantId)
          .eq('is_revenue', true)
          .eq('order_status', 'completed')
          .is('settlement_id', null)
          .gte('completed_at', `${periodStart}T00:00:00+07:00`)
          .lte('completed_at', `${periodEnd}T23:59:59+07:00`)
          .select('id')

        if (salesUpdateError) throw salesUpdateError

        results.push({
          restaurant_id: restaurantId,
          settlement_id: settlement.id,
          period_label: settlement.period_label,
          gross_total: grossTotal,
          total_deductions: totalDeductions,
          net_settlement: netSettlement,
          order_count: updatedSales?.length ?? 0,
        })
      } catch (error) {
        console.error('generate_delivery_settlement error:', {
          restaurantId,
          periodLabel,
          error,
        })
        results.push({
          restaurant_id: restaurantId,
          period_label: periodLabel,
          error: error instanceof Error ? error.message : 'Unknown error',
        })
      }
    }

    return new Response(
      JSON.stringify({
        processed_restaurant_count: byRestaurant.size,
        period_label: periodLabel,
        results,
      }),
      {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      },
    )
  } catch (error) {
    console.error('generate_delivery_settlement fatal error:', error)
    return new Response(
      JSON.stringify({
        error: error instanceof Error ? error.message : 'Unknown error',
      }),
      {
        status: 500,
      },
    )
  }
})
