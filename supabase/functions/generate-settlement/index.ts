import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

serve(async (req: Request) => {
  // 인증 필수: CRON_SECRET이 설정되어야 함
  const authHeader = req.headers.get("Authorization");
  const cronSecret = Deno.env.get("CRON_SECRET");
  if (!cronSecret) {
    console.error("CRON_SECRET not configured");
    return new Response(JSON.stringify({ error: "Server misconfigured" }), { status: 500 });
  }
  if (authHeader !== `Bearer ${cronSecret}`) {
    return new Response("Unauthorized", { status: 401 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  const now = new Date();
  const day = now.getDate();
  const year = now.getFullYear();
  const month = now.getMonth();

  let periodStart: Date;
  let periodEnd: Date;
  let periodLabel: string;

  if (day <= 15) {
    periodStart = new Date(year, month, 1);
    periodEnd = new Date(year, month, 15);
    periodLabel = `${year}-${String(month + 1).padStart(2, "0")}-A`;
  } else {
    periodStart = new Date(year, month, 16);
    const lastDay = new Date(year, month + 1, 0).getDate();
    periodEnd = new Date(year, month, lastDay);
    periodLabel = `${year}-${String(month + 1).padStart(2, "0")}-B`;
  }

  const startIso = periodStart.toISOString().split("T")[0];
  const endIso = periodEnd.toISOString().split("T")[0] + "T23:59:59.999Z";

  const { data: restaurants } = await supabase
    .from("external_sales")
    .select("restaurant_id")
    .eq("is_revenue", true)
    .eq("order_status", "completed")
    .is("settlement_id", null)
    .gte("completed_at", startIso)
    .lte("completed_at", endIso);

  const restaurantIds = [
    ...new Set(restaurants?.map((r: any) => r.restaurant_id) ?? []),
  ];

  const results: any[] = [];

  for (const rid of restaurantIds) {
    try {
      const { data: sales } = await supabase
        .from("external_sales")
        .select("id, gross_amount, payload")
        .eq("restaurant_id", rid)
        .eq("is_revenue", true)
        .eq("order_status", "completed")
        .is("settlement_id", null)
        .gte("completed_at", startIso)
        .lte("completed_at", endIso);

      if (!sales || sales.length === 0) continue;

      const grossTotal = sales.reduce(
        (sum: number, s: any) => sum + Number(s.gross_amount), 0
      );

      const { data: settlement } = await supabase
        .from("delivery_settlements")
        .insert({
          restaurant_id: rid,
          source_system: "deliberry",
          period_start: startIso,
          period_end: endIso.split("T")[0],
          period_label: periodLabel,
          gross_total: grossTotal,
          total_deductions: 0,
          net_settlement: grossTotal,
          status: "calculated",
        })
        .select()
        .single();

      if (!settlement) continue;

      // 차감 항목 생성
      const items: any[] = [];
      const platformFee = Math.round(grossTotal * 0.015);
      items.push({
        settlement_id: settlement.id,
        item_type: "platform_commission",
        amount: platformFee,
        description: "플랫폼 수수료 1.5%",
        reference_rate: 0.015,
        reference_base: grossTotal,
      });

      const paymentFee = Math.round(grossTotal * 0.015);
      items.push({
        settlement_id: settlement.id,
        item_type: "payment_fee",
        amount: paymentFee,
        description: "결제 수수료 (평균 1.5%)",
        reference_rate: 0.015,
        reference_base: grossTotal,
      });

      if (items.length > 0) {
        await supabase.from("delivery_settlement_items").insert(items);
      }

      const totalDeductions = items.reduce(
        (sum: number, i: any) => sum + Number(i.amount), 0
      );

      await supabase
        .from("delivery_settlements")
        .update({
          total_deductions: totalDeductions,
          net_settlement: grossTotal - totalDeductions,
        })
        .eq("id", settlement.id);

      const saleIds = sales.map((s: any) => s.id);
      await supabase
        .from("external_sales")
        .update({ settlement_id: settlement.id })
        .in("id", saleIds);

      results.push({
        rid, periodLabel, grossTotal, totalDeductions,
        netSettlement: grossTotal - totalDeductions,
        orderCount: sales.length,
      });
    } catch (e) {
      console.error(`Settlement error for ${rid}:`, e);
      results.push({ rid, error: "Settlement processing failed" });
    }
  }

  return new Response(
    JSON.stringify({ processed: restaurantIds.length, periodLabel, results }),
    { headers: { "Content-Type": "application/json" } }
  );
});
