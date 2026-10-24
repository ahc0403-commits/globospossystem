# 독립 로컬 결과를 확인하는 최소 GitHub 절차 — 미적용 설계

이 문서는 사용자의 “진행해라” 승인에 따른 설계·로컬 구현 기록이다. 이후 사용자는
커밋·푸시와 정상 공식 운영 반영을 별도로 승인했다. 그 승인은 이 독립 결과 검증기의
활성화나 원격 보안 설정 변경 승인이 아니다. 현재 승인된 독립 실행·서명 주체가 없어
**이 검증기의 운영 성공 경로는 비활성**이다. 같은 제출자의 키로 서명한 영수증을 동등한 보호라고 인정하지 않는다.

## 확인한 현재 상태와 재사용

- main/운영 기준 SHA는 `383e55d875080511bcd8b07ad813ec0e08f31358`이다.
- 기존 로컬 SHA `403ec1e5c1f15bce9ad2367b9a85dee412cc9900`의 전체 8단계 결과와
  250개 보관 파일 해시, 누락·변조 11종 거부 증거를 보존한다. 원래 clone에서 영수증을
  다시 검증했다. 이 증거는 해당 SHA의 로컬 실행·검토 증거이며 독립 서명은 없다.
- 새 Python 검증기와 local recipe 변경에는 새 SHA의 영향 검사를 수행한다. 이전 결과를
  새 SHA의 전체 release PASS 또는 독립 서명 증거로 이름만 바꿔 재사용하지 않는다.
  앱/runtime/DB migration이 바뀌지 않았으므로 기존 Flutter·SQL 31분 검사를 상태 확인
  목적으로 반복하지 않는다. 새 SHA의 전체 exact-main release 검증은 원격 채택 뒤 별도다.
- 저장소는 public, 소유자는 개인(User)이다. main은 check `POS release contract`,
  app `15368`, strict=true, enforce_admins=true, conversation resolution=true를 요구한다.
  force push/deletion=false다. 독립 write/admin 협업자는 없고 현재 소유자 1명뿐이다.
- Actions enabled=true, allowed_actions=all, sha_pinning_required=true. 기본 workflow
  token 권한은 read, PR 승인 허용은 false다. 2026-03-10 API의 Actions policies GET은
  HTTP200이며 현재 `total_count=0`이다. GET 성공이 POST 권한·정책 적용 성공을 뜻하지 않는다.
- 기본/검증 clone에는 Git signing 설정이 없다. 저장소·지침에 승인된 독립 attestor가 없다.
  개인 키·keychain 비밀을 탐색하거나 읽지 않았고 새 운영 키·token을 만들지 않았다.

## 위협 모델과 신뢰 경계

| 대상 | 공격/실패 | 방어 또는 남는 조건 |
|---|---|---|
| 제출 credential | 성공 status·영수증·해시를 임의 생성 | GitHub status를 읽어 성공으로 믿지 않는다. 승인된 독립 실행자 공개키로 Ed25519 서명을 검사한다. 현재 키 목록은 비어 있으므로 exit3 |
| 일반 서명 키 | 제출자가 임의 문서에도 서명 가능 | 키가 있다는 사실이나 policy boolean은 독립성 증명이 아니다. 실행 기록/키 사용을 제출자와 분리해 통제하는 실제 주체가 먼저 필요 |
| receipt/statement | 변조·다른 repo/PR/head/base 재사용 | domain, exact head/base SHA, PR 번호, 실행 ID와 raw receipt SHA256를 서명에 결합. 중복 JSON key·초과 입력·다른 키·오래된 결과 거부 |
| 검사 축소 | step 제거, 다른 명령, 빈/생략/실패/부족한 건수 | 고정 local recipe/runner digest, 최소 assertion 수, repository stage 수, 도구/OS·산출물/fixture manifest 확인. scripts/test/workflow/lock 입력 digest가 다르면 별도 policy review 필요 |
| policy 변경 | 후보에서 자기 키·약한 policy로 교체 | 검증 코드는 trusted default branch의 policy를 사용하고, candidate input manifest의 policy 파일 hash도 trusted base의 실제 파일 hash와 같아야 함. 정책 회전/첫 설치는 별도 검토가 필요 |
| 증거 제출 ref | 작성자가 파일을 바꾸거나 부분 갱신 | 별도 결과 ref는 비신뢰 transport다. 서명·receipt digest로 결합해 혼합/변조는 거부. 같은 소스 commit에 자기 SHA를 넣는 순환 구조를 사용하지 않음 |
| PR 변경 경합 | 읽는 동안 새 commit/base로 변경 | GitHub PR metadata를 앞뒤 두 번 읽고 event/head/base가 모두 같을 때만 통과. strict는 계속 유지 |
| workflow 위장 | 다른 job이 같은 이름·Actions app으로 성공 | app_id만으로 workflow 신원을 고정할 수 없다. 모든 workflow에 이벤트 allowlist를 적용해 PR 소스 실행을 차단하는 강화안과 trusted default-branch 검증기를 함께 검토. 현재 미적용 |
| 관리자 credential 침해 | 보호/실행 정책 자체 변경 | 현 계정은 admin이다. 이 검증기가 control plane 관리자 침해까지 막는다고 주장하지 않는다. 기존 보호 설정을 신뢰하는 경계이며 관리자 권한 분리도 현재 확인되지 않음 |

서명 검사는 **신뢰할 수 있는 주체의 주장인지** 확인한다. 테스트가 실행되었다는 사실을
서명 알고리즘 자체가 만들어내지는 않는다. 승인된 local executor는 제출자가 바꿀 수 없는
검증 코드·recipe·검사 입력으로 실제 전체 검사를 실행하고 원본 로그/산출물·실제 exit/count를
검사한 뒤에만 해당 프로토콜을 서명해야 한다. PR 코드가 일반 signing API를 호출하거나
기존의 임의 서명 가능한 SSH/GPG 키를 등록하는 방식은 이 조건을 만족하지 않는다.
기존 403ec1e5의 unsigned receipt를 나중에 임의 키로 서명해 독립 실행 증거로 바꿀 수 없다.

## 구현된 안전한 부분

- `scripts/receipt_verification/verify.py`: 표준 OpenSSL Ed25519 검증만 사용한다. 자체
  암호 알고리즘·keyless 신원 발급·운영 signing CLI를 만들지 않는다. raw statement 앞에
  고정 프로토콜 domain을 결합한다. 공개 SPKI key 종류와 fingerprint도 고정한다.
- `cli.py`: offline metadata 검증이다. trust-policy 경로 override/unsigned/skip 성공
  옵션이 없다. shipped policy는 enabled=false, keys=[]이며 실제 exit3으로 차단한다.
- `github_readonly.py`: 고정 GitHub API 도메인에 GET만 한다. redirect/임의 URL·과대 응답을
  거부한다. PR metadata 2회와 결과 파일 3회, **최대 5회**로 고정한다. PR 코드·압축 파일을
  실행/추출하지 않고 subprocess는 고정 OpenSSL 검증 1회뿐이다. API 쓰기·status 생성 없음.
- `trust-policy.json`: 승인된 key가 없고 독립 custody/workflow 승인도 false다. JSON의
  true 값만으로 운영 독립성을 확보했다고 간주하면 안 된다. pins를 계산해도 활성화되지 않는다.
- local recipe에는 검증기 보안 회귀만 1단계 추가했다. 모든 unit·보안·기능 테스트는 로컬에서
  수행한다. GitHub 제안 job에는 unittest, Flutter/Dart/Deno/Node 실행이나 앱 build가 없다.

## 최소 원격 절차 제안과 계산량

1. 승인된 독립 실행자가 exact candidate SHA를 로컬에서 검증하고 원본 receipt 및 서명을 만든다.
   독립된 실행·서명 환경은 현재 없으므로 이 단계의 운영 통합은 미완료다.
2. 결과를 `pos-local-verification-results` ref의
   `local-verification/<head-sha>/{statement.json,signature.bin,receipt.json}`에 보관하는
   방안을 제안한다. 결과 ref·파일 경로는 제안이며 아직 만들거나 push하지 않았다.
3. `proposals/pos_release_contract.yml.example`은 trusted default-branch의 코드만 checkout하고
   `POS release contract` job에서 서명/metadata만 확인한다. contents:read와 기존 자동
   GITHUB_TOKEN만 제안하며 checks/statuses/id-token/attestations write는 추가하지 않는다.
   job skip·continue-on-error·경로 필터로 성공을 만들지 않는다.
4. `pull_request_target`은 required-check 평가에 허용된 event지만 GITHUB_SHA는 default
   branch다. 실제 check의 PR 연결·최신 head/base 변경 시 무효화는 **승인된 원격 통합 검사
   전까지 미검증**이다. 본문에 head SHA를 출력하는 것만으로 서버 연결이 검증된 것이 아니다.
5. GitHub 계산은 2MiB 이하 receipt JSON, 16KiB 이하 statement, 64byte signature,
   source/산출물 digest manifest 검사와 공개키 검증이다. raw 로그/웹 asset 전체를 다시
   내려받아 테스트하거나 빌드하지 않는다. 전체 bytes/실제 테스트 완전성은 독립 local executor가
   검증한 뒤 서명하는 신뢰 경계다. GitHub는 그 서명의 진위·정책 일치를 확인한다.
6. API 요청 수는 소스 파일·테스트·DB 행 수에 비례하지 않고 최대 5회다. 5초/request,
   OpenSSL 10초 timeout, job 2분 상한을 제안한다. rate limit·누락/지연은 실패로 차단하고
   fallback 성공이나 자동 재시도는 없다. 실제 hosted queue/실행 시간은 아직 측정하지 않았다.
7. public 저장소의 standard hosted runner는 현재 GitHub 요금 문서상 무료다. 기존 hosted
   실행 환경에서 metadata 확인을 하는 제안이며 새 runner 등록/대형 runner/유료 서비스가
   아니다. 아무 계산도 없거나 Actions가 전혀 실행되지 않는다고 표현하지 않는다. artifact/cache
   upload는 없고 실제 원격 실행·추가 비용은 아직 발생시키지 않았다. 공개 범위가 바뀌면 재검토한다.

## 정확한 원격 변경 전후 — 모두 미승인·미실행

| 대상 | 현재 → 제안 | 유지/위험 |
|---|---|---|
| main.required_status_checks.checks | `[{context:POS release contract,app_id:15368}]` → **그대로** | 다른 앱/commit status로 바꾸지 않음 |
| strict / enforce_admins | `true / true` → **그대로** | fresh branch·관리자 적용 보존 |
| conversation resolution / force push / deletion | `true / false / false` → **그대로** | 보존 |
| 기본 workflow 권한 / PR 승인 | `read / false` → **그대로** | 새 token·앱 권한 없음. 제안 job은 contents:read |
| required PR approval | `0` → **현 제안은 그대로** | 외부 reviewer를 확보했다고 가정하지 않음 |
| Actions event policies | `[]` → 아래 단일 active policy 제안 | 모든 workflow에 `pull_request_target`만 허용해 PR/push/manual의 app 테스트·위장 job 실행을 차단하는 방안. 설정 변경 승인과 실제 통합 검사가 필요 |

설정 대상은 `repos/ahc0403-commits/globospossystem/actions/policies`이다. 요청 body는
[actions-event-policy.json](proposals/actions-event-policy.json)에 있으며, **POST는 실행하지 않았다**.
conditions는 `~ALL`, exclude=[], rule은 `restrict_action_events`, allowed_events는
`[pull_request_target]`이다. branch protection의 check를 지우거나 앱 제약을 풀지 않는다.
현재 API GET만 성공했으므로 write 성공을 가정하지 않으며 새 권한·token 발급도 하지 않는다.

이 정책은 기존 모든 event를 허용하는 상태를 제한하지만, GitHub가 2026-12-02부터 적용할
public `pull_request_target` 기본 차단을 명시적으로 허용하는 선택이기도 하다. 따라서 단순히
위험 없는 강화라고 부르지 않는다. trusted main 코드만 실행, read token, secret 미참조,
PR 코드 미실행을 전제로 그 opt-in 위험까지 확인받아야 한다. 현재 승인된 변경은 없다.

## 첫 설치·남은 최소 조건

- **독립 local executor/서명 주체 확보가 먼저다.** 현 제출 credential과 같은 통제 아래의
  범용 키는 C안 문제를 해결하지 않는다. 이미 존재하는 별도 통제 주체가 있다면 신원·키 보관·
  실행 코드·signing 조건을 검토해 승인된 공개키만 고정할 수 있다. 없으면 새 권한/credential/
  신뢰 주체를 허용하지 않는 현재 제약으로는 동등한 실행 진위 보장을 완료할 수 없다.
- **trusted workflow만 실행되는 원격 경계**가 필요하다. 위 이벤트 정책은 public 개인 repo에서
  가능한 보완안이다. 조직/enterprise required-workflow 규칙은 현재 개인 repo에 있다고
  가정하지 않는다. 이벤트 제한의 위장 job/skip/다른 event 차단 효과는 실제 승인 후 확인해야 한다.
- **bootstrap deadlock을 숨기지 않는다.** 현재 main에는 검증 전용 workflow/신뢰 키가 없고
  기존 check가 merge를 막는다. 정책을 먼저 켜면 기존 app-test workflow도 차단되어 설치가
  막힐 수 있다. 검토된 정확한 SHA·독립 증거·기존 보호 하의 첫 설치 순서를 별도로 승인받아야
  한다. 관리자 bypass나 잠깐 check 제거를 설치 절차로 제공하지 않는다.
- 승인 후에도 PR head 변경·base 이동·잘못된 서명·누락·혼합 ref·shadow job·skip·API 실패를
  실제 원격에서 검사하고, 앱 테스트/빌드가 GitHub에서 실행되지 않았는지 job steps로 확인해야 한다.
  현재는 이 원격 실행 자체가 보류되어 있다.

## 근거

- [이벤트별 workflow source/SHA](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)
- [required check의 최신 SHA·허용 event·skip 의미](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks)
- [workflow 실행 정책의 public 제공·event 제한](https://docs.github.com/en/actions/how-tos/administer/control-workflow-execution)
- [정책 REST schema](https://docs.github.com/en/rest/actions/policies)
- [public pull_request_target 기본 정책과 2026-12-02 적용](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target)
- [public standard runner 과금](https://docs.github.com/billing/managing-billing-for-github-actions/about-billing-for-github-actions)
- [OpenSSL Ed25519 검증](https://docs.openssl.org/3.6/man1/openssl-pkeyutl/)

현재 구현·로컬 검사와 원격 적용·정책 변경은 별개다. 여기서는 설계/비활성 구현만 제공하며
실제 신뢰 주체·원격 통합·공식 release가 완료됐다고 표시하지 않는다.

## 후속 정상 공개·운영 반영 요청

최종 실제 후보에서 기존 8단계와 추가 보안 검사를 포함한 전체 9단계를 로컬로 수행한다.
통과한 소스는 앱 테스트 workflow가 없는 branch/PR로 저장·검토할 수 있다. 비활성 검증기
활성화·자기 서명·새 신뢰 인프라를 정상 릴리스의 조건으로 추가하지 않는다. 병합은 기존
보호 규칙을 지키며, required check 때문에 막히면 실행되지 않은 단계와 정확한 설정
변경 전후·위험을 보고하고 별도 명시적 승인을 받는다. tooling-only 변경이면 불필요한 앱
배포를 만들지 않고, 실제 main에 공식 로컬 검증 경로가 채택됐는지 확인한다.
