import {
  buildCashRegisterInvoicePayload,
  validateCashRegisterInvoicePayload,
} from "./meinvoice.ts";
const seller = {
  taxEntityId: "akj",
  taxCode: "0318453298",
  sellerName: "AKJ",
  authBaseUrl: "https://fixture.invalid",
  apiBaseUrl: "https://fixture.invalid",
  appId: "fixture",
  invoiceSeries: "1C26MAJ",
  integrationStatus: "ready",
};
function assert(ok: unknown) {
  if (!ok) throw new Error("Assertion failed");
}
function ordinaryJob(email: string, phone: string, payment = "TM") {
  return {
    id: "ordinary-contact-fixture",
    source_system: "restaurant_pos",
    created_at: "2026-10-08T16:32:20Z",
    payment_method_snapshot: payment,
    buyer_snapshot: { email, phone, unit_name: "Bán cho người tiêu dùng" },
    line_items_snapshot: [{
      order_item_id: "cola-line",
      menu_item_id: "cola-sku",
      invoice_profile_id: "cola-approval",
      invoice_name_vi: "Cola",
      misa_unit_name: "Chai",
      quantity: 1,
      total_amount_ex_tax: 54000,
      vat_rate: 10,
      vat_amount: 5400,
    }, {
      order_item_id: "fanta-line",
      menu_item_id: "fanta-sku",
      invoice_profile_id: "fanta-approval",
      invoice_name_vi: "Fanta",
      misa_unit_name: "Chai",
      quantity: 1,
      total_amount_ex_tax: 32000,
      vat_rate: 8,
      vat_amount: 2560,
    }],
  };
}
Deno.test("registered buyer invoice accepts omitted phone and preserves a leading zero", () => {
  for (const phone of ["", "02800000000"]) {
    const job = ordinaryJob("buyer@example.invalid", phone, "CK");
    job.buyer_snapshot = {
      ...job.buyer_snapshot,
      unit_name: "Fixture company",
      ...{ tax_code: "0012345678", address: "Fixture address" },
    };
    const payload = buildCashRegisterInvoicePayload({
      ...job,
      buyer_kind: "registered",
    }, seller);
    validateCashRegisterInvoicePayload(payload);
    const invoice = (payload.InvoiceData as any[])[0];
    assert(invoice.BuyerTaxCode === "0012345678");
    assert((invoice.BuyerPhoneNumber ?? "") === phone);
  }
});
for (
  const [email, phone] of [
    ["fixture@example.com", "0123456789"],
    ["fixture@example.com", ""],
    ["", "0123456789"],
    ["", ""],
  ]
) {
  Deno.test(`ordinary native invoice preserves email=${!!email}, phone=${!!phone}`, () => {
    const payload = buildCashRegisterInvoicePayload(
      ordinaryJob(email, phone),
      seller,
    );
    validateCashRegisterInvoicePayload(payload);
    const invoice = (payload.InvoiceData as any[])[0];
    assert((invoice.BuyerEmail ?? "") === email);
    assert((invoice.ReceiverEmail ?? "") === email);
    assert((invoice.BuyerPhoneNumber ?? "") === phone);
    assert(invoice.IsSendEmail === !!email);
  });
}
for (
  const label of [
    "Ví điện tử",
    "VNPAY",
    "Voucher",
    "Chưa thu tiền",
    "TM/Ví điện tử",
    "TM/VNPAY",
    "TM/Voucher",
    "Chưa thu tiền/TM",
  ]
) {
  Deno.test(`native payload retains approved payment label ${label}`, () => {
    const payload = buildCashRegisterInvoicePayload(
      ordinaryJob("", "", label),
      seller,
    );
    validateCashRegisterInvoicePayload(payload);
    const invoice = (payload.InvoiceData as any[])[0];
    assert(invoice.PaymentMethodName === label);
    assert(
      invoice.TotalAmountWithoutVAT === 86000 &&
        invoice.TotalVATAmount === 7960 && invoice.TotalAmount === 93960,
    );
    assert(
      invoice.OriginalInvoiceDetail[0].VATRateName === "10%" &&
        invoice.OriginalInvoiceDetail[1].VATRateName === "8%",
    );
  });
}
Deno.test("native invoice retains all 9 menu lines and beverage snapshots", () => {
  const bases = [54000, 32000, 40000, 40000, 40000, 40000, 40000, 40000, 80000];
  const payload = buildCashRegisterInvoicePayload({
    id: "fixture",
    source_system: "restaurant_pos",
    snapshot_version: 2,
    created_at: "2026-10-08T16:32:20Z",
    payment_method_snapshot: "CK",
    line_items_snapshot: bases.map((s, i) => ({
      order_item_id: `line-${i}`,
      menu_item_id: `sku-${i}`,
      invoice_profile_id: `approval-${i}`,
      invoice_name_vi: i === 0 ? "Cola" : i === 1 ? "Fanta" : `Approved ${i}`,
      misa_unit_name: i < 2 ? "Chai" : "Phần",
      quantity: i === 8 ? 2 : 1,
      total_amount_ex_tax: s,
      vat_rate: i === 0 ? 10 : 8,
      vat_amount: s * (i === 0 ? .1 : .08),
    })),
  }, seller);
  validateCashRegisterInvoicePayload(payload);
  const invoice = (payload.InvoiceData as any[])[0];
  const details = invoice.OriginalInvoiceDetail;
  assert(details.length === 9);
  assert(details.reduce((n: number, d: any) => n + d.Quantity, 0) === 10);
  assert(
    invoice.TotalAmountWithoutVAT === 406000 &&
      invoice.TotalVATAmount === 33560 && invoice.TotalAmount === 439560,
  );
  assert(invoice.PaymentMethodName === "CK");
  assert(details[0].VATRateName === "10%" && details[1].VATRateName === "8%");
});
Deno.test("fractional quantities and approved units are retained", () => {
  const payload = buildCashRegisterInvoicePayload({
    id: "fractional",
    created_at: "2026-10-08",
    payment_method_snapshot: "TM",
    line_items_snapshot: [{
      invoice_name_vi: "Approved portion",
      misa_unit_name: "Phần",
      quantity: .5,
      total_amount_ex_tax: 50000,
      vat_rate: 8,
      vat_amount: 4000,
    }],
  }, seller);
  validateCashRegisterInvoicePayload(payload);
  assert(
    (payload.InvoiceData as any[])[0].OriginalInvoiceDetail[0].Quantity === .5,
  );
});

Deno.test("Photo retains its normal service unit without restaurant SKU rules", () => {
  const payload = buildCashRegisterInvoicePayload({
    id: "photo",
    source_system: "photo_objet_moers",
    created_at: "2026-10-08",
    payment_method_snapshot: "TM",
    line_items_snapshot: [{
      display_name: "Dịch vụ chụp ảnh",
      quantity: 1,
      total_amount_ex_tax: 100000,
      vat_rate: 8,
      vat_amount: 8000,
    }],
  }, seller);
  validateCashRegisterInvoicePayload(payload);
  assert(
    (payload.InvoiceData as any[])[0].OriginalInvoiceDetail[0].UnitName ===
      "Lần",
  );
});
