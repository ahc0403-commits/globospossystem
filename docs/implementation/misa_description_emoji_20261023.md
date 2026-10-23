# MISA Description 장식 이모지 정규화

상태: 별도 브랜치의 구현·검증. 구매 개선의 POS 운영 배포 SHA `98b6cf3b`에는 포함하지 않았다. 기존 MISA 150건을 업로드·발행·신고하지 않았다. 원래 매출 자동화 앱도 수정하지 않았다.

## 동작과 보존

- 레스토랑 단독·레스토랑/포토 통합 엑셀의 최종 Description 문자열 경계에서만 적용한다. 원장, 메뉴 마스터, 승인 매핑, 고객 영수증, 원본 스냅샷과 해시를 수정하지 않는다.
- 정책 `misa-description-emoji-v1-unicode18`: 고정 Unicode 18.0의 Emoji/Emoji_Presentation/Emoji_Component/Extended_Pictographic 표와 `characters`의 확장 문자소 단위로 처리한다. 기본 이모지 표시 문자, 보조 평면의 등록된 그림 이모지, 이모지 스타일 선택자·ZWJ 결합, 국기·키캡을 제거한다. 삭제할 문자소의 모든 문자가 등록된 이모지 또는 구성 요소인지 검사한다. 일반 텍스트 스타일의 ©/®/™/화살표와 숫자·구두점은 유지한다.
- 제거 시 붙은 VS15/VS16, 피부색·태그·ZWJ도 함께 제거한다. 홀로 남은 이모지 구성 요소, 비이모지 ZWJ, 잘못된 UTF-16/XML 제어 문자, 정규화 후 빈 이름은 영수증·품목·메뉴·필드와 코드 포인트 오류로 중단한다.
- NFC/ASCII 변환, 비BMP 일괄 삭제, 공백 합치기를 하지 않는다. 베트남어 성조, 한글, 비이모지 보조 문자는 보존한다. 고추를 지운 위치의 기존 공백도 그대로 남는다.
- 포토 전용 출력과 포토 Description은 변경하지 않는다. 기존 17열, 영수증 묶음, 수량·단가·VAT·합계·결제·고객·일자, POS Ledger v3, Store Reconciliation을 유지한다.

## 감사와 독립 대조

- 변경이 있는 경우에만 `Description Normalization` 시트에 원문·출력문·정책·문자소·UTF-16 삭제 위치·행·원본 ID를 기록한다. 통합 산출물 manifest에도 같은 기록을 남긴다. 원본 `content_sha256`, `source_hash`, `line_hash` 계산 입력은 정규화하지 않는다.
- `scripts/misa_description_audit.py`는 생산자의 함수를 호출하지 않는다. 독립 원본 명세의 원문과 감사 원문을 대조하고, 허용된 이모지 시퀀스 삭제를 UTF-16 위치에서 재구성한다. 임의의 문자·숫자·품목명 삭제, 겹친 위치, 남은 구성 요소, 정책·ID 불일치를 거절한다.
- 기존 구조 대조는 기본적으로 그대로 엄격하다. `--allow-description-normalization`은 새 정책과 감사가 유효할 때만 감사 시트·정책 키 추가 및 Description의 허용된 삭제를 인정한다. 다른 데이터 셀과 POS Ledger 해시가 바뀌면 실패한다.

```sh
python3 scripts/compare_misa_workbook_structure.py \
  /path/to/original-source.xlsx /path/to/normalized.xlsx \
  --allow-description-normalization \
  --source-manifest /path/to/independent-manifest.json \
  --output /path/to/comparison.json
```

명세는 기존 `receipts[].sequence/receipt_id/kind/lines[].invoice_name`의 원문을 유지한다. 새로운 검사로 금액·고객·승인 원본 검증을 대체하지 않는다.

## 매출 자동화 앱과의 적용 경계

현재 패키지의 `akj/source_manifest.py`는 원본 `invoice_name`과 업로드 Description을 그대로 비교한다. 새 엑셀을 자동화에 사용하려면 그 기대 Description 계산에 **알려진 정책의 검증된 감사 기록만** 연결해야 한다. 원본 명세 생성·승인 검증·금액 검증은 그대로 둔다. `verify_record(original_invoice_name, record)`가 허용된 삭제를 검증한 반환값만 비교에 사용하며, 정책이 없는 기존 파일은 기존 비교를 유지한다. 이 작업에서는 실행 중인 패키지를 수정하거나 이미 발행된 파일을 다시 처리하지 않았다.

## 검증 증거

- 2026-10-22 원본의 실제 고추 포함 Description 5개를 읽기 전용으로 확인했다. 이 문자열과 가상 금액으로 별도 샘플을 생성했다. 운영 파일과 MISA ID는 변경하지 않았다.
- 일반 문자·성조·한글·보조 문자 보존, VS/ZWJ/국기/키캡, 원본·금액·고객·해시 보존, 멱등성, 포토 불변, 오류 위치 및 통합 산출물 감사를 테스트한다.
- Python 독립 감사 검사는 실제 단어·숫자·원문·메뉴 ID·금액·정책·삭제 위치 변경을 거절한다.
- 샘플 대조: Description 5개만 변경, 다른 모든 데이터 셀·원본 Ledger 해시 동일, 독립 원문 8개 품목 대조.
- 정규화는 이미 받은 문자열을 메모리에서 처리하며 행별 DB/API 호출을 추가하지 않는다. CPU 비용은 문자 수에, 감사 메모리는 변경된 문자소와 품목 수에 비례한다. 10,000행 미세 측정은 별도 `performance.json`에 기록하며 UI 지연이나 운영 전체 메모리 측정으로 간주하지 않는다.

원자료: [Unicode Emoji 데이터](https://www.unicode.org/Public/18.0.0/ucd/emoji/emoji-data.txt), [Unicode Emoji 사양](https://www.unicode.org/reports/tr51/), [Dart characters](https://pub.dev/packages/characters). 생성 스크립트는 원자료 SHA-256을 고정하고 Unicode 라이선스를 함께 보존한다.

가상금액 샘플 재생성(실제 업로드용 아님):

```sh
MISA_DESCRIPTION_SAMPLE_DIR=/tmp/misa-description-sample \
  flutter test test/misa_description_normalization_test.dart
```

테스트는 기본적으로 공유 임시 경로에 파일을 쓰지 않는다.
