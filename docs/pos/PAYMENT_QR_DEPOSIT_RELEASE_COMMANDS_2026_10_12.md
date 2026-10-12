# POS QR·익일 입금 구분 배포 명령

2026-10-12 / Asia/Ho_Chi_Minh. **명령 준비만 완료했으며 운영 배포·DB 적용은 실행하지 않았다.**

모바일은 모바일 브라우저 화면이다. POS 웹 배포 한 번으로 데스크톱과 모바일 화면에 함께 반영된다.

## 반영 범위

1. 영수증 법인 계좌·QR: `20261012183000_receipt_collection_bank.sql`.
2. 고객 계좌이체 분리, 포토 D+1 입금, 분식클럽 마감 D+1 법인 입금, 조회·갱신 개선: `20261012210000_deposit_breakdown.sql` 및 POS 웹 소스.
3. 인쇄 영수증을 처리하는 Windows 프린트스테이션은 아래의 동일 SHA 패키지로 교체한다.

Office 명령이나 추가 서버 함수 배포는 포함하지 않는다. 공식 배포기에 추가한 `--web-only`는 기존 main·CI·권한·로그인 검사를 유지하고 DB/Edge 배포를 실행하지 않는다. 마이그레이션은 공식 `--db-only`로 각각 적용한다.

## 실행 전 준비

요청한 변경과 배포 도구만 검토해 main에 병합하고, 그 **정확한 SHA**의 `POS release contract` 성공을 확인한다. 현재 작업 폴더에는 기존 변경이 많으므로 자동으로 commit/stash/reset하지 않는다. 깨끗한 승인된 main 체크아웃에서 실행한다. 웹은 전체 빌드이므로 미승인 변경을 main에 함께 넣으면 명령 옵션만으로 제외할 수 없다.

아래 변수는 실제 배포용 체크아웃 경로와 승인한 40자리 SHA로 채운다. 비밀번호·토큰은 명령에 쓰지 않는다. 환경 파일과 기존 고정 POS 계정의 로그인 smoke 정보는 안전한 환경변수로 준비한다.

```bash
export POS_RELEASE_DIR='/absolute/path/to/clean-approved-main-checkout'
export POS_RELEASE_SHA='APPROVED_40_CHARACTER_MAIN_SHA'
export ENV_FILE='/Users/andreahn/.config/globos/pos-production.env'
cd "$POS_RELEASE_DIR"

# 해당 체크아웃을 POS 프로젝트에 연결하고 이력 확인
supabase link --project-ref ynriuoomotxuwhuxxmhj
supabase migration list

# 순서와 검사 경로 확인: DB나 웹을 변경하지 않음
bash scripts/release_payment_qr_deposit.sh --sha "$POS_RELEASE_SHA" --dry-run

# 실제 반영: 영수증 DB → 입금 구분 DB → 웹·모바일 화면
bash scripts/release_payment_qr_deposit.sh --sha "$POS_RELEASE_SHA" --execute
```

래퍼의 기본값은 dry-run이다. 깨끗하지 않은 체크아웃 또는 승인 SHA 불일치 시 중단한다. 각 공식 단계에서도 새로 가져온 origin/main과 필수 CI를 검사한다. 전체 Flutter 테스트와 공식 배포 검사를 생략하지 않는다.

## 중간 실패 후 재개

마이그레이션 이력을 확인해 성공한 DB 단계를 반복하지 않는다. 영수증 DB만 성공했으면 다음을 순서대로 실행한다.

```bash
bash scripts/release_payment_qr_deposit.sh --sha "$POS_RELEASE_SHA" --stage deposit --execute
bash scripts/release_payment_qr_deposit.sh --sha "$POS_RELEASE_SHA" --stage web --execute
```

두 DB 버전이 모두 적용됐고 웹만 실패했다면 `--stage web`만 실행한다. `supabase db push`는 사용하지 않는다.

## 인쇄 영수증용 Windows 패키지

main의 해당 소스 변경으로 자동 실행되는 `Windows Print Station Build`가 같은 SHA에서 성공해야 한다. 아래 명령은 기존 워크플로의 결과를 확인하고 정확한 SHA의 패키지를 받는다.

```bash
export POS_PRINT_PACKAGE_DIR="$HOME/Downloads/globos-print-station-$POS_RELEASE_SHA"
POS_PRINT_RUN_ID="$(gh run list \
  --repo ahc0403-commits/globospossystem \
  --workflow windows_print_station_build.yml \
  --branch main --commit "$POS_RELEASE_SHA" --limit 100 \
  --json databaseId,conclusion \
  --jq 'map(select(.conclusion == "success")) | sort_by(.databaseId) | last | .databaseId // empty')"

if [[ "$POS_PRINT_RUN_ID" =~ ^[0-9]+$ ]]; then
  gh run download "$POS_PRINT_RUN_ID" \
    --repo ahc0403-commits/globospossystem \
    --name "globos-print-station-windows-x64-$POS_RELEASE_SHA" \
    --dir "$POS_PRINT_PACKAGE_DIR"
else
  printf '해당 SHA의 Windows 빌드가 아직 성공하지 않았습니다.\n' >&2
fi
```

Windows에서 인쇄 대기열이 비었는지 확인한 뒤 기존 프린트스테이션을 종료하고 ZIP 전체를 풀어 교체한다. EXE만 교체하면 DLL·data가 일치하지 않을 수 있다. 실행 후 MSB 계좌 `80002014298` QR을 실제 영수증으로 출력해 확인한다. Windows 패키지 빌드·다운로드·단말 교체는 이번 명령 준비 작업에서 실행하지 않았다.

## 로컬 검증

새 범위 검사는 모의 실행과 임시 로컬 Git fixture만 사용한다. 웹·모바일 웹 흐름에서 DB/Edge 호출 없음, 기본 배포 흐름 유지, 필수 검사 실패 시 중단, 마이그레이션 2개 고정, 기본 dry-run, 잘못된 SHA·기존 변경 차단을 확인한다.

```bash
bash -n scripts/deploy_pos_production.sh scripts/release_payment_qr_deposit.sh
bash test/pos_payment_deposit_release_test.sh
```

이번 준비에서 위 범위 검사, 기존 Git/CI·마이그레이션 이력 검사, DB-only 검사, 깨끗한 체크아웃 검사 및 관련 Flutter 배포 계약 검사를 실행했다. Flutter 계약 검사는 5건 통과, Windows 전용 실행 검사는 1건 환경 조건으로 skip했다. 새 업무 코드의 전체 재검증이나 운영 배포 검증을 이번 명령 준비 결과로 주장하지 않는다.
