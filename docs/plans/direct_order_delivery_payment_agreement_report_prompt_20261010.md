# 배달비 협의 계획 보고 이미지 생성 기록

> **과거 보고 이미지:** 두 가지 지급 방식·필수 협의·매장 차액 부담은 이후 사용자 결정으로 제외됐다. 현재 방향은 [고객 수령 시 기사 직접 결제 전용 개선안](/Users/andreahn/globos_pos_system/docs/plans/direct_order_customer_pays_driver_only_improvement_20261010.md)이다. 기존 이미지는 검토 이력으로 보존한다.

2026-10-10 · 생성 방식: built-in image_gen · 용도: 계획 보고 이미지 (구현 전)

이미지: [보고용 PNG](/Users/andreahn/globos_pos_system/docs/plans/direct_order_delivery_payment_agreement_report_20261010.png)

최종 생성 프롬프트:

```text
Use case: infographic-diagram
Asset type: a single Korean business-report infographic for a restaurant POS planning discussion, for viewing and sharing in chat.
Primary request: Visually report the agreed implementation PLAN for mandatory customer consultation on delivery-fee payment before the cashier finalizes the order amount. This is a proposed feature, not a screenshot or proof of implemented software.
Style: polished, restrained editorial infographic with clear Korean sans-serif type, white/off-white background, charcoal text, restrained teal and blue accents, generous margins, precise alignments, simple flat line icons. No decorative photography or people. Portrait 2:3 canvas, high resolution, all Korean characters and numbers sharp and fully legible. Reading flow from top to bottom. Main title and key rule dominant; two payment option cards equal width; sparse copy, strong hierarchy. Do not crowd the page.
Render exactly the Korean text below, with natural line wrapping and no invented text. Numbers and currency must be exact. Layout text in these sections:

HEADER:
small label "배달 주문 개선 보고"
title "고객 합의 후에만\n최종 금액 확정"
subtitle "배달비 결제 방식 협의부터 실비·현금 마감까지"
small status badge "계획안 · 구현 전"

SECTION 1: full-width five-step flow with arrows, headed "필수 진행 순서"
"캐셔 조건 안내" → "고객 확인" → "캐셔 금액 확정" → "고객 결제" → "조리·배차"
An emphasized gate under the first three stages:
"합의 전에는 최종 확정·결제 안내 불가"
A modest note: "주문 시 선택은 희망 방식이며, 최종 합의는 별도 확인"

SECTION 2: two side-by-side option cards, headed "고객과 반드시 결정할 두 가지 방식"
Card A, teal accent:
"배달비 포함 선결제"
"음식값 + 안내 배달비를 한 번에 결제"
"음식값 200,000동"
"안내 배달비 30,000동"
large total "고객 결제 230,000동"
"매장이 기사에게 지급"
"실비가 늘어도 고객 추가 결제 없음"
Card B, blue accent:
"기사에게 직접 결제"
"매장에는 음식값만 결제"
"음식값 200,000동"
"매장 수금 배달비 0동"
large total "매장 결제 200,000동"
"수령 시 고객이 기사에게 실비 지급"
small note "수령자 지급을 지원하는 매장에서만 제공"

SECTION 3: three compact rule cards under heading "캐셔 화면과 확인 규칙"
Card with status pills:
"미협의 → 확인 대기 → 합의 완료"
"합의 완료 후 최종 확정 버튼 활성화"
Card:
"채팅 확인 / 전화·현장 기록"
"방식·금액·부담 조건, 협의 시각·담당자 저장"
Card:
"확정 전 조건 변경 → 재협의"
"무응답·기본 선택은 동의로 처리하지 않음"

SECTION 4: full-width numeric worked example, visually clear large numbers with payment/ledger icons, headed "포함 선결제 이후: 차액은 매장 부담"
Display three equal metrics:
"고객 안내 배달비" / "30,000동"
"실제 기사 비용" / "40,000동"
"매장 부담액" / "10,000동"
Under metrics, two important statements:
"고객 총 결제액은 230,000동 그대로"
"현금 마감은 기사 지급액 40,000동을 한 번만 차감"
small note "매장 부담액 10,000동을 별도로 다시 차감하지 않음"
small note "실비가 줄어도 고객 결제액 유지 · 차액 기록"

SECTION 5: compact footer band:
"함께 개선: 고객 ↔ 매장 사진·PDF 전송"
"일반 첨부와 결제 증빙 구분 · 전송 상태 · 재시도"
bottom implementation roadmap "구현 순서: DB/API → 고객·캐셔 화면 → 마감·보고서 → 검증·배포"

Constraints: This image reports a PLAN. Do not use claims like implemented, deployed, tests passed. The gate is before cashier final amount, not merely before payment. Direct-to-driver option means the customer pays actual delivery fee to driver separately; never say customer pays once in that card. In prepaid option, merchant absorbs overrun; cashier records actual total driver cost separately from customer quote. Cash ledger deducts full driver payout ONCE, never adds the burden again. Customer confirmation does not automatically finalize; cashier does. Do not draw phone recording as a fabricated customer click. No invented logos, no fake screenshots, no backend jargon in main customer flow, no N+1 assertions, no watermarks. Preserve all labels exactly, including VND examples expressed as 동.
```
