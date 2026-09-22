# Runtinue 저장소 작업 지침

## 적용 범위

이 파일은 저장소 전체에 적용됩니다.

## 제품 우선순위

Runtinue는 회사와 집 사이를 이동하는 동안 휴대전화 핫스팟 전환을 거쳐 로컬 에이전트 작업을 이어 가는 macOS 앱입니다. 작업 연속성보다 MacBook 보호와 정상 수면 복구를 우선합니다.

- 안전 상태를 확인할 수 없거나 조건이 기준을 벗어나면 실행 유지를 중단하고 정상 수면 복구를 시도합니다.
- `덮개 닫기 가능`, 보호 성공, 복구 완료는 현재 시스템에서 확인한 상태만 표시합니다. 요청 성공, 캐시, 과거 기록만으로 상태를 확정하지 않습니다.
- 네트워크 전환 중 연결이 끊겨도 이미 확인된 유한 lease를 그 이유만으로 해제하지 않습니다. 기기 안전 조건과 만료 시간은 계속 적용합니다.

## 변경 원칙

설계와 구현에서는 `$simple-change-review`가 정의하는 `simple` 관점을 따릅니다. 해당 스킬을 사용할 수 없는 환경에서도 다음 원칙을 적용합니다.

- 문제를 해결하는 데 필요한 최소의 완결된 범위를 바꿉니다. 계약이 달라지면 정책, 런타임, UI, CLI, 테스트와 사용자 문서를 같은 변경에서 맞춥니다.
- 상태와 정책의 소유자는 하나로 유지하고 데이터는 한 방향으로 흐르게 합니다. 같은 사실을 나타내는 플래그와 캐시를 중복으로 두거나 예외 경로를 늘리지 않습니다.
- 안전 경계를 우회하는 임시 분기와 요청 성공을 실제 상태로 간주하는 낙관적 처리를 추가하지 않습니다.
- 요청과 무관한 리팩터링, 이름 변경과 서식 변경을 섞지 않습니다.

## 검증과 안전

변경한 계약을 직접 검증하는 테스트를 먼저 실행하고 PR 전에는 가능한 범위에서 다음 검사를 실행합니다.

```sh
./scripts/test.sh
./scripts/test-public-boundary.sh
```

- 마지막 코드 변경 뒤 검사를 새로 실행하고 결과를 현재 커밋에 연결합니다.
- 자동화 검사와 모의 장치 테스트는 실제 MacBook의 발열 안전성, 덮개 닫힘 동작과 이동 중 작업 지속을 증명하지 않습니다. 실행하지 않은 실기기 검증을 통과했다고 기록하지 않습니다.
- 설치, 제거, `integration-test.sh` 실행처럼 시스템 전원 상태를 바꾸는 작업은 사용자의 명시적 동의를 받고 고정된 패키지와 SHA-256을 확인한 뒤에만 실행합니다.
- Helper, Supervisor, lease, 센서 판정, 설치와 복구 경계를 바꾸면 실패 경로와 정상 수면 복구를 함께 검증합니다.

## 공개 파일 경계

공개 파일은 `.gitignore`의 허용 목록으로 관리합니다.

- 공개 설명 문서는 루트의 `README.md`와 `AGENTS.md`로 제한합니다. `LICENSE`는 사용 허락과 책임 제한을 담는 별도 파일입니다.
- README 화면 이미지는 `READMEAssets/trip-start.png`, `READMEAssets/trip-protected.png`와 `READMEAssets/recovery.png`만 공개합니다. 이미지는 실제 앱 컴포넌트와 고정 예시 데이터로 렌더링합니다. 사용자의 실제 SSID, 게이트웨이, 사용자명, 기기 식별 정보와 개인 경로를 포함하지 않습니다.
- 보호 완료와 복구 상태 이미지는 `./scripts/render-readme-assets.sh`로 다시 만듭니다. 이 명령은 실제 상태 헤더 컴포넌트와 고정 예시 데이터만 사용합니다.
- 기획 문서, 참고 앱과 아이디어의 출처, 내부 작업 기록, 검토 메모, 원본 로그, 인증 정보, 개인 경로, 기기 식별 정보와 빌드 결과는 커밋하지 않습니다.
- 타사 코드나 자산에 라이선스 고지 의무가 있으면 이를 공개하고 허용 목록과 함께 검토합니다.
- 소스, 테스트, 실행 스크립트, 필수 설정에 새 경로를 추가할 때는 허용 목록과 공개 경계 회귀 테스트를 같은 변경에서 갱신합니다.
- 심볼릭 링크와 서브모듈은 공개하지 않습니다.

새로 복제한 저장소에서는 먼저 Git 훅을 설정합니다.

```sh
./scripts/setup-repository.sh
```

커밋과 푸시 전에 다음 경계를 확인합니다.

```sh
./scripts/verify-public-tree.sh --staged
./scripts/verify-public-tree.sh --history HEAD
./scripts/test-public-boundary.sh
```

금지 파일이 Git 이력에 들어가면 현재 트리에서 삭제해도 공개 문제가 해결되지 않습니다. 공개를 중단하고 이력과 노출 범위를 별도로 확인합니다.

## 개발과 배포

- 루트의 `VERSION`을 앱, 패키지, manifest에 적용하는 단일 버전 기준으로 사용합니다. `VERSION` 환경 변수로 다른 버전을 주입하지 않습니다.
- 빌드는 `Info.plist`와 manifest에 소스 커밋과 작업 트리 상태를 기록합니다. 커밋되지 않은 변경이 있는 개발 패키지는 패키지와 manifest의 SHA-256을 함께 보관합니다.
- GitHub Actions의 `Repository checks`는 arm64 `macos-15` 실행기에서 디버그 테스트를 수행합니다. `Release candidate` workflow는 고정 태그에서 release 설정 테스트와 서명·공증된 후보 패키지의 manifest 및 checksum 검증을 별도 계약으로 수행합니다. 어느 workflow의 성공도 패키지 설치, 실기기 안전성과 실제 통근 여정을 증명하지 않습니다.
- 기능 브랜치 변경은 PR에서 검증합니다. `push` trigger는 main과 tag처럼 필요한 ref를 명시해 같은 커밋의 중복 실행을 막습니다.
- PR에는 병합 판단에 필요한 검사를 둡니다. 배포 빌드와 패키지 검증은 명시적인 배포 절차에서 실행하며, 상시 자동화가 필요한 근거가 확인된 경우에만 main, tag 또는 수동 workflow에 배치합니다.
- 새 workflow나 job에는 기존 검사와 구분되는 결과 계약이 있어야 합니다. 같은 계약을 반복하거나 실행 시점만 다른 경우에는 기존 workflow의 trigger와 조건을 조정합니다.
- 정식 배포에는 깨끗한 작업 트리와 현재 커밋을 가리키는 `v$(./scripts/version.sh)` 태그가 필요합니다. Developer ID 서명, 공증, 티켓 첨부, 실기기 검증 기록을 모두 확인한 뒤에만 배포 포인터(release pointer)를 게시합니다.
- 개발 패키지 포인터는 정식 배포 승인을 뜻하지 않으며 GitHub Release를 자동으로 만들지 않습니다.

### GitHub release 후보 workflow

`.github/workflows/release-candidate.yml`은 정확한 `vMAJOR.MINOR.PATCH` 태그 push 또는 GitHub Actions에서 그 태그 ref를 직접 선택한 수동 실행에서만 동작합니다. 브랜치 ref에서 수동 실행하면 source contract가 서명 단계 전에 거부합니다. 일반 PR과 main 검사는 이 workflow를 실행하지 않으며, 기존 `Repository checks`도 태그에서 중복 실행하지 않습니다.

서명 job은 GitHub의 보호된 `release-candidate` environment를 사용합니다. 태그와 diff를 검토하는 필수 승인자를 설정하고 다음 secret과 variable을 environment에만 등록합니다.

- Secrets: `RUNTINUE_APPLICATION_CERTIFICATE_P12_BASE64`, `RUNTINUE_APPLICATION_CERTIFICATE_PASSWORD`, `RUNTINUE_INSTALLER_CERTIFICATE_P12_BASE64`, `RUNTINUE_INSTALLER_CERTIFICATE_PASSWORD`, `RUNTINUE_NOTARY_API_KEY_P8_BASE64`, `RUNTINUE_NOTARY_KEY_ID`, `RUNTINUE_NOTARY_ISSUER_ID`
- Variables: `RUNTINUE_DEVELOPER_ID_APPLICATION`, `RUNTINUE_DEVELOPER_ID_INSTALLER`

P12와 App Store Connect API key는 각각 원본 파일 전체를 base64로 인코딩한 값이어야 합니다. Application과 Installer 인증서는 서로 분리하며, workflow는 import 직후 원본 P12/P8 파일과 환경 변수를 제거하고 임시 keychain도 job 종료 전에 삭제합니다. workflow와 action은 `contents: read`만 사용하고 Node 24 기반 action commit을 고정하며 GitHub Release를 만들 권한을 갖지 않습니다.

workflow artifact는 공증되고 staple된 package, package에 고정된 manifest와 SHA-256 sidecar만 포함하는 14일 보관 후보입니다. `--candidate-only` 경로는 release pointer와 GitHub Release를 만들지 않습니다. 후보를 받은 뒤 대상 Mac에서 다음 순서로 실기기 기록을 만들고 모든 필수 시험을 실제로 수행해야 합니다.

```sh
./scripts/hardware-validation.sh create \
  "$runtinue_manifest" "$runtinue_package" "$runtinue_package.hardware.json"
./scripts/hardware-validation.sh cases
# 각 case마다 describe를 확인하고 token이 요구하는 run 또는 begin/finish 경로만 사용합니다.
./scripts/hardware-validation.sh describe cleanInstall
./scripts/hardware-validation.sh verify \
  "$runtinue_manifest" "$runtinue_package" "$runtinue_package.hardware.json"
```

같은 태그를 checkout한 깨끗한 저장소에서 아래 gate가 통과해야만 로컬 release pointer를 만들 수 있습니다.

```sh
RUNTINUE_VALIDATION_RECORD="$runtinue_package.hardware.json" \
  ./scripts/release-manifest.sh publish \
    "$runtinue_package" "$runtinue_manifest" ".release/Runtinue-latest.json"
```

현재 저장소에는 이 gate 뒤 GitHub Release를 게시하는 자동 권한이나 절차가 없습니다. 후보, manifest, checksum, 실기기 기록과 pointer를 다시 검토한 관리자가 별도의 명시적 승인 절차로만 GitHub Release를 게시합니다.

개발 패키지를 만들 때는 저장소 내부의 새 출력 디렉터리를 사용합니다.

```sh
mkdir -p .release
runtinue_package_dir=$(mktemp -d "$PWD/.release/development.XXXXXX")
RUNTINUE_RELEASE_ROOT="$runtinue_package_dir" ./scripts/package-development.sh
```

실기기 검증 기록은 고정된 manifest와 실제 패키지 바이트에 연결합니다. 기록 파일은
로컬 검증 산출물이며 커밋하지 않습니다. `create`, `token`, 각 시험과 `verify` 사이에
패키지를 교체하지 않습니다.

```sh
./scripts/hardware-validation.sh create \
  "$runtinue_manifest" "$runtinue_package" "$runtinue_package.hardware.json"
./scripts/hardware-validation.sh cases
./scripts/hardware-validation.sh describe cleanInstall
./scripts/hardware-validation.sh verify \
  "$runtinue_manifest" "$runtinue_package" "$runtinue_package.hardware.json"
```

전원 상태를 바꾸는 자동 시험은 사용자가 해당 후보와 case를 확인한 뒤 `token`
출력을 직접 다시 입력한 경우에만 `run`으로 시작합니다. 예를 들어 유한 open-lid
assertion 시험은 `timedAssertionExpiry` case와
`scripts/integration-test.sh --timed-assertion-timeout`을 사용합니다. 설치·인증 준비와
명시적 동의 없이 이 명령을 실행하지 않습니다. 모든 case는 `run` 또는 `begin` 토큰을
만들기 전에 `describe <case>`의 안전 전제·최소 절차·통과 기준을 먼저 확인합니다.
자동화되지 않은 항목은 `begin` 전에 begin 토큰을 확인하고, 실제 절차가 끝난 뒤
`finish passed|failed` 토큰을 확인합니다. `describe`에 적힌 조건을 안전하게 만들 수
없는 case는 실행하거나 통과 처리하지 않고 `notRun`으로 남깁니다.
실패하거나 중단된 case는 같은 기록에서 덮어쓰지 않고 새 기록으로 다시 시작합니다.

```sh
# 출력된 manifest/package/runner SHA를 확인한 뒤 전체 토큰을 직접 복사합니다.
./scripts/hardware-validation.sh token \
  "$runtinue_manifest" "$runtinue_package" timedAssertionExpiry run

./scripts/hardware-validation.sh run \
  "$runtinue_manifest" "$runtinue_package" "$runtinue_package.hardware.json" \
  timedAssertionExpiry --confirm '<token 명령의 전체 출력>' -- \
  "$PWD/scripts/integration-test.sh" --timed-assertion-timeout
```

## PR

- PR은 기본적으로 초안(Draft) 표시 없이 검토 가능한 상태로 만듭니다.
- 본문에는 목적, 변경 범위, 실행한 검사와 남은 실기기 검증을 구분해 적습니다.
- 인증 정보, 개인 경로, 원본 로그, 공개 대상에서 제외한 작업 문서를 이슈, PR과 리뷰 댓글에도 넣지 않습니다.
