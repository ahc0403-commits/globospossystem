# POS 원격 보호 계약 결정 — 미승인

2026-10-24 읽기 전용 조회 기준이다. 이 파일은 변경안과 제약이며 설정 변경 승인이나
전환 완료 증거가 아니다. 현재 사용자 지시는 보호 변경·우회·병합·배포를 보류하고
로컬 구현·검증까지만 진행하는 것이다. 푸시나 PR로 원격 테스트가 시작될 수 있으므로
아직 원격 브랜치·draft PR을 만들지 않는다.

## 현재 값과 필요한 전환

대상은 `ahc0403-commits/globospossystem`의 `main` 보호 규칙이다.

```json
{
  "required_status_checks": {
    "strict": true,
    "checks": [{"context": "POS release contract", "app_id": 15368}]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": false,
    "require_last_push_approval": false,
    "require_code_owner_reviews": false
  }
}
```

로컬 전환 후보에서는 공식 배포기가 매번 검증기를 직접 실행한다. 그러나 로컬 프로세스가
기존 GitHub Actions 앱 15368의 신뢰 주체가 될 수는 없다. 단순 context 이름 재사용,
`gh api statuses`로 성공 생성, check의 app 제약 해제, `--admin` 병합은 대안이 아니다.
워크플로를 보존한 채 실행하면 “GitHub에서 테스트하지 않는다”는 지시를 만족하지 못한다.

GitHub는 특정 앱을 required status의 출처로 고정할 수 있다.
[공식 branch protection 설명](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).
현재 출처 제약을 만족하면서 테스트 실행 장소만 로컬로 바꾸는 **동등한 자동 원격 계약은
새 앱·토큰·credential 없이 확인되지 않았다.** 로컬 영수증 해시는 무결성 증거일 뿐
그 원격 신뢰 주체를 대신하는 전자서명이 아니다.

## 최소 선택지와 변경 전후

| 선택지 | 변경 전 → 후 | 보호와 제약 | 현재 실행 |
|---|---|---|---|
| A. 현재 보호 유지 | required check/app/strict/admin 모두 그대로 | 동등한 원격 계약 결정 전 로컬 후보 보관. 원격 전환·병합은 미완료 | 이 선택지로 보류 |
| B. 독립 인적 검토 계약 | approving review `0 → 1`, stale dismissal `false → true`, last-push approval `false → true`, 관리자 강제 유지. 기존 Actions 요구는 **대체 계약 검증·승인 이후에만** 교체 | 기존 write 권한의 독립 검토자가 최종 SHA·recipe·전체 로그/해시·실패/생략을 실제 검토. PR 작성자의 자기 승인은 불가. GitHub 서버는 영수증 내용을 자동 검증하지 못하므로 기존 앱 기반 자동 보호와 동일하다고 주장할 수 없음 | 미승인·미실행 |
| C. required deployment를 이용한 로컬 증거 연결 | 특정 로컬 검증 environment의 exact-SHA deployment 성공을 required-deployments로 추가하고, 검증 후에만 기존 check 계약 교체 검토 | GitHub에서 테스트를 실행할 필요는 없고 현 계정 admin/push와 OAuth repo scope는 읽기 조회로 확인됨. 새 token 없이 deployment API를 사용할 권한 근거가 있으나 실제 쓰기는 수행하지 않음. 그러나 같은 credential 소유자가 status를 직접 만들 수 있어 provenance 보장은 자동 확보되지 않음. GitHub를 검증 메타데이터 보관에도 사용하게 되므로 “커밋 보관만” 정책에 별도 결정 필요 | 미승인·API 쓰기 미실행 |

GitHub의 [required deployments 규칙](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
및 [deployment REST 계약](https://docs.github.com/en/rest/deployments/deployments)은
SHA별 environment/status 연결을 제공한다. 그것만으로 로컬 프로세스가 실제 수행됐다는
신뢰를 보증하지 않는다. 협업자 목록에서 기존 write/admin 주체는 저장소 소유자 1명뿐이었다. 따라서
B의 독립 리뷰어는 현재 없고, 이를 새로 추가하면 금지된 권한 확대에 해당한다.
기존 독립 서명/검증 주체도 확인되지 않았으며 새 신뢰 주체나 자격증명을 만들지 않는다.

따라서 지금 승인 요청할 수 있는 정직한 범위는 B 또는 C를 **동등한 자동 보호라고
간주하지 않는다는 한계를 포함한 보안 정책 재설계**이다. 구체적인 독립 검토자/검증 주체와
영수증 인증·최신 SHA 검토 절차를 정하지 않은 채 required check를 빈 배열로 만드는
실행용 PATCH를 제공하거나 실행하지 않는다. 비용·권한·새 credential 없이 그 제약을
해결할 수 없다면 A를 유지하고 전체 전환을 미완료로 남긴다.

현 조회에서 `required_conversation_resolution=true`, force push/deletion은 모두 false이며
적용 branch rules 조회는 빈 배열이었다. 이 조건도 보존해야 한다. 토큰 원문은 조회·출력하지 않았다.

## 승인 이후에도 보존할 조건

- clean/fresh exact-main, 모든 기존 필수 로컬 검사, 완전한 종료·assertion·로그 증거.
- 관리자 우회 금지, 강제 푸시·브랜치 삭제 금지와 기존 다른 보호 규칙 보존.
- 후보와 병합 후 main 증거 구분 및 실제 remote SHA 확인.
- 공식 배포·고정 운영 대상·Auth·이력·로그인·기능 검증.
- 원격 설정 변경 전 fresh GET으로 현재 값 재확인, 변경 전후 증거와 롤백 계획 보관.

현재 파일은 선택지의 정확한 필드와 한계를 설명한다. 어떤 선택지도 승인·실행되지 않았으며
원격 check 요구를 제거한 상태를 완료안으로 제시하지 않는다.
