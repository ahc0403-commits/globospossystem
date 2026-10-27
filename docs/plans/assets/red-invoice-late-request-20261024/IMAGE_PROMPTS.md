# 이미지 생성 기록

도구: 기본 제공 `image_gen.imagegen`. CLI/API 키 경로는 사용하지 않았다.
용도: 2026-10-24 추가 발행 요청 기능의 검토용 UI 시안. 두 이미지 모두 새로 생성했으며 실서비스 스크린샷이 아니다. 표시된 고객·영수증 데이터는 예시다.
검토 기준: 기존 흰색/회색 POS 화면과 파란색 액션, 영수증 하단 버튼 위치, 전화번호 선택 표시, 요청 접수와 실제 발행 완료 구분.

## 01-button-location.png — 최종 프롬프트

```text
Create one high-fidelity UI design proposal image for the existing GLOBOSVN restaurant POS. This is a PROPOSED UI mockup, not an actual production screenshot. Use case ui-mockup. Landscape canvas approximately 1800 by 1300, crisp Korean Noto Sans-like type, white surfaces, pale gray #F5F7FA background, blue #2563EB primary buttons, charcoal text, subtle gray borders, rounded 20px modals. Practical Flutter Material restaurant POS look. No illustrations, no gradients, no device perspective, no unrelated branding.

The image shows WHERE TO ADD THE BUTTON, with two panels across the canvas:
LEFT 55% width: today's receipts screen. Top title exactly "오늘 영수증". A short breadcrumb above it "캐셔 > 오늘 영수증". Date chip "2026.10.24", store "JeonGabok Binh Thanh". Search box placeholder "영수증 번호 · 테이블 검색". Receipt list of 4 rows, modest readable columns 영수증 / 결제시각 / 테이블 / 금액 / 레드인보이스. Selected first row pale blue: BC-20261024-000123, 12:45, 1212, 1,269,720 VND, gray pill "미요청". Other fictional example receipt rows. Make blue numbered circular callout 1 next to selected receipt labelled "영수증 선택".
RIGHT 45% width: large white receipt detail modal, header "BC-20261024-000123" and small "영수증 상세". Readonly labeled details 매장 JeonGabok Binh Thanh, 결제 시각 24/10/2026 12:45:42, 테이블 1212, 결제 수단 계좌이체. A NEW calm status row "레드인보이스" with gray pill "미요청". A horizontal divider then section "주문 내역" with four compact illustrative items: Sprite ×1 18,000; 해물짬뽕 ×2 350,000; 탕수육 S ×1 190,000; "외 6개 품목" and no false subtotal arithmetic. Then prominent total "결제 금액" "1,269,720 VND". Footer buttons in one neat row: text "닫기", outlined printer icon "영수증 재인쇄", filled blue document-plus icon primary button EXACT "레드인보이스 추가 발행". Primary CTA may wrap into two lines if necessary but not clipped. Callout 2 blue outline ring highlights only the new primary button, annotation outside modal "상세 하단에 추가".
Canvas title at top large EXACT "캐셔가 놓친 레드인보이스, 영수증에서 바로 요청". Small top-right pill EXACT "제안 시안 · 샘플 데이터". Bottom caption EXACT "기존 영수증을 선택하고, 하단의 추가 발행 버튼을 누릅니다." Small bottom note EXACT "이미 발행된 건은 상태 확인 후 MISA로 연결".
All main Korean copy must be rendered accurately and legibly. Strong visual hierarchy, generous whitespace, operational screen density, visible button targets. Do not show a reissue action on an already-issued invoice. Sample data only, no real customer tax code, email or phone.
```

## 02-buyer-and-status.png — 최종 프롬프트

```text
Use case ui-mockup. Create one crisp high-fidelity Korean restaurant POS interface proposal board, matching Flutter Material appearance: white cards, pale gray #F5F7FA background, strong blue #2563EB primary CTA, charcoal text, subtle gray outlines, 20px corner radius, legible Korean sans-serif. Landscape approximately 1800 by 1300. This is a design proposal with fictional sample data, not a real deployed screen. No photos, no gradients, no decorative illustration.

Canvas top title exact "구매자 정보 입력 → 발행 요청 접수". Top right small pill "제안 시안 · 샘플 데이터".

LEFT, about 65% width: one large white form modal. Header title exact "레드인보이스 추가 발행", close X. Under heading a read-only pale blue compact receipt summary:
"BC-20261024-000123"
"JeonGabok Binh Thanh · 24/10/2026 12:45"
"결제 금액 1,269,720 VND"
Then operational form, very readable labels. First row small dropdown "번호 유형" value "베트남 세금번호" next to field label "세금번호 *" value "0312345678" with outlined little button "회사 조회".
Full width field label "회사명 *" and value "Công ty ABC".
Full width field label "주소 *" and value "123 Nguyễn Huệ, TP. Hồ Chí Minh".
Next row email field label "수신 이메일 *" value "ketoan@example.com"; phone field label EXACT "전화번호 (선택)" empty placeholder "없으면 공란". Highlight optional phone label with a subtle blue underline or tiny blue tag "선택".
Optional dashed evidence control with paperclip icon "명함 · 고객 메시지 첨부 (선택)".
Small read-only reason summary "추가 요청 사유: 결제 시 발행 요청 누락".
Footer left text "취소", outlined "임시 저장", filled blue main CTA exact "등록하고 발행 요청", sized comfortably with no clipping.
Do not put invented implementation warnings or raw APIs in product UI.

RIGHT, about 35% width: a small arrow pointing from main CTA to a result card. Right card heading exact "요청 접수 후". Green small check icon then title exact "레드인보이스 요청이 접수되었습니다". Under it receipt number "BC-20261024-000123", amber status pill exact "발행 대기". Brief body exact "발행 상태는 영수증에서 확인할 수 있습니다." Button blue outline "영수증으로 돌아가기".
Below, compact vertical 3-step status list: green check "구매자 정보 저장", amber clock "발행 대기", gray circle "발행 완료". Under list tiny explanation "실제 발행 결과에 따라 상태가 갱신됩니다."
Below separate quiet pale blue outlined card heading "이미 발행된 계산서" with an external-link icon button EXACT "MISA에서 확인". Body exact "발행 상태 확인 및 정정은 MISA에서 진행".
Bottom full-canvas caption EXACT "전화번호는 선택 입력 · 접수와 실제 발행 완료를 구분합니다."

All critical Korean text must be rendered verbatim, sharp, and large enough to read. Preserve visual hierarchy and realistic achievable UI. Do not display success as invoice issued: this screen is request accepted and waiting. Do not include real customer name, phone, email, tax number or today's actual receipt number. Only the fictional data stated above.
```
