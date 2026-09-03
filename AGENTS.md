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
- GitHub Actions는 arm64 `macos-15` 실행기에서 디버그 테스트, 배포용 테스트, 개발 패키지 생성, 패키지 내용 검사를 수행합니다. CI 성공은 패키지 설치, 공증, 실기기 안전성과 실제 통근 여정을 증명하지 않습니다.
- 정식 배포에는 깨끗한 작업 트리와 현재 커밋을 가리키는 `v$(./scripts/version.sh)` 태그가 필요합니다. Developer ID 서명, 공증, 티켓 첨부, 실기기 검증 기록을 모두 확인한 뒤에만 배포 포인터(release pointer)를 게시합니다.
- 개발 패키지 포인터는 정식 배포 승인을 뜻하지 않으며 GitHub Release를 자동으로 만들지 않습니다.

개발 패키지를 만들 때는 저장소 내부의 새 출력 디렉터리를 사용합니다.

```sh
mkdir -p .release
runtinue_package_dir=$(mktemp -d "$PWD/.release/development.XXXXXX")
RUNTINUE_RELEASE_ROOT="$runtinue_package_dir" ./scripts/package-development.sh
```

실기기 검증 기록은 고정된 manifest와 패키지에 연결합니다.

```sh
./scripts/hardware-validation.sh create \
  "$runtinue_manifest" "$runtinue_package.hardware.json"
./scripts/hardware-validation.sh verify \
  "$runtinue_manifest" "$runtinue_package.hardware.json"
```

## PR

- PR은 기본적으로 초안(Draft) 표시 없이 검토 가능한 상태로 만듭니다.
- 본문에는 목적, 변경 범위, 실행한 검사와 남은 실기기 검증을 구분해 적습니다.
- 인증 정보, 개인 경로, 원본 로그, 공개 대상에서 제외한 작업 문서를 이슈, PR과 리뷰 댓글에도 넣지 않습니다.
