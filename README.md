# Runtinue

이동 중에도 이어지는 로컬 에이전트 작업.

Runtinue는 회사와 집 사이를 이동하는 약 1시간 동안 MacBook의 로컬 에이전트 작업을 휴대전화 핫스팟으로 이어가기 위해 만든 개인용 오픈 소스 macOS 앱입니다.

**현재는 실험 단계입니다. 작업의 연속성보다 기기 보호를 우선하며, 안전 조건이 깨지면 실행 유지를 해제하고 정상 수면 복구를 시도합니다.**

## 안전 경고와 책임 제한

이 소프트웨어는 Mac의 수면 동작을 변경하며 관리자 권한으로 설치되는 백그라운드 서비스를 사용합니다. 사용 전에 소스와 동작을 확인하고 중요한 파일을 백업하십시오.

- **가방, 밀폐된 슬리브와 침구처럼 열이 빠져나가기 어려운 곳에서 실행 상태로 사용하지 마십시오.** 통풍과 상태 확인이 어려우면 작업을 중단하고 Mac을 잠자기 상태로 전환하십시오. [Apple의 온도와 통풍 안내](https://support.apple.com/en-us/102336)를 따르십시오.
- 덮개를 닫아도 CPU, GPU, 저장장치와 네트워크가 계속 동작할 수 있어 발열, 기기 손상, 화재와 화상 위험이 남습니다. 앱은 macOS의 열 상태를 사용하며 부품과 외장 표면의 온도를 직접 측정하지 않습니다. 센서 지연, OS 오류와 프로세스 장애 때문에 보호 로직이 실패할 수 있으므로 장시간 고부하 연산, 대규모 빌드와 로컬 모델 추론은 피하십시오.
- 핫스팟 전환 중 TCP 연결, API 요청과 원격 세션이 끊길 수 있습니다. 앱은 에이전트 작업의 지속, 복구와 저장을 보장하지 않습니다. 에이전트 자체의 재시도와 저장 기능을 확인하십시오.
- 안전 조건 위반, 시간 만료와 장애가 발생하면 작업이 중단되거나 결과가 손실될 수 있습니다. 모바일 데이터와 API 요금, 배터리 소모와 손실 위험은 사용자가 판단하고 부담합니다.
- 다른 수면 제어 도구와 함께 사용하지 마십시오. macOS 전역 전원 설정에는 도구별 소유권을 원자적으로 구분하는 기능이 없어 서로의 설정에 영향을 줄 수 있습니다.
- 모든 MacBook, macOS 버전, 핫스팟과 이동 환경을 검증하지 않았습니다. 무중단 운용, 유지보수 일정, 지원, 업데이트와 호환성을 보장하지 않습니다.

**소프트웨어는 MIT 라이선스에 따라 있는 그대로(AS IS) 제공됩니다. 명시적 또는 묵시적 보증을 제공하지 않으며, 저작자와 기여자는 관련 법률이 허용하는 범위에서 사용으로 발생한 청구, 손해와 책임을 부담하지 않습니다.** 이 경고는 제조사의 안전 지침과 적용되는 법률을 대신하지 않습니다. 자세한 사용 허락과 책임 제한은 [LICENSE](LICENSE)를 확인하십시오.

## 작동 방식

Trip은 지정한 Wi-Fi 핫스팟 연결 또는 USB 테더링 전환, 인터넷, 기기 상태, 유한 lease(수면 억제 권한) 순서로 보호를 확인합니다. 회사나 집의 Wi-Fi에서 먼저 시작하거나 이미 연결한 핫스팟에서 바로 시작할 수 있습니다.

사용자가 휴대전화와 macOS에서 연결을 바꾸면 앱이 결과를 확인합니다. 앱은 Wi-Fi에 직접 접속하지 않으며 실제 보호까지 성공한 대상만 다음 시작을 위해 저장합니다. 핫스팟 전환 후 네트워크가 잠시 끊겨도 활성 lease를 그 이유만으로 종료하지 않고 기기 안전 조건과 시간 제한을 계속 적용합니다.

메뉴바와 CLI에서 Trip을 시작하고 상태, 기록과 진단을 확인하거나 중단할 수 있습니다. 활동 신호에 따라 실행을 유지하는 Adaptive 모드와 책상에서 사용하는 Desk 모드도 제공합니다.

안전 중단은 정상 수면 설정을 복구하며 즉시 잠자기를 뜻하지 않습니다. 에이전트 종료와 작업 저장도 별도로 확인해야 합니다. 메뉴바 앱을 종료해도 Supervisor가 관리하는 활성 모드는 계속될 수 있으므로 먼저 메뉴의 중단 기능이나 `runtinue stop`을 사용하십시오.

### 메뉴바 상태

앱은 `Runtinue.app`, CLI는 `runtinue`로 실행합니다. 메뉴바의 기본 아이콘은 달리는 사람의 팔이 화살표로 이어지는 형상입니다.

Trip 상태 헤더의 Flowline(보호 진행선)은 `네트워크 → 인터넷 → 기기 → 보호` 순서를 보여줍니다. 덮개 닫힘이 허용됐다는 응답을 받은 뒤에만 마지막 보호 지점이 검증 완료로 바뀝니다. Trip 중단과 복구 중에는 `수면 보호 → 정상 수면` 순서로 표시합니다.

| 표시 | 의미 |
| --- | --- |
| 달리는 사람과 화살표 | 기본 브랜드 표시이며 안전 승인을 뜻하지 않음 |
| 경고 삼각형 | 활성 보호나 복구 책임이 남았고 시스템 수면 설정을 확인할 수 없음 |
| `✓` | 보호 확인 완료 |
| `…` | 연결 또는 보호 확인 중 |
| `!` | 안전 중단 또는 정상 수면 복구 중 |
| `?` | 보호 상태 확인 불가 |

덮개는 메뉴에 `덮개 닫기 가능`이 표시될 때만 닫으십시오. 경고, 복구 중과 상태 확인 불가에서는 덮개를 열어 두어야 합니다.

## 시작 전 확인

- Apple Silicon MacBook과 macOS 13 이상이 필요합니다. 패키지 빌드와 설치는 네이티브 arm64 환경만 지원합니다. Intel Mac과 Rosetta 실행 환경은 지원하지 않습니다.
- 소스 빌드에는 Swift 6.0 이상을 제공하는 Xcode 또는 Command Line Tools가 필요합니다.
- 실제 수면 제어에는 전체 패키지와 관리자 권한이 필요합니다. 앱 파일만 복사하면 서비스와 호출자 인증 구성이 맞지 않을 수 있습니다.
- Wi-Fi 이름을 감지하려면 메뉴바 앱에 위치 권한을 허용해야 합니다.
- 공증된 설치 패키지의 제공 여부는 별도로 확인해야 합니다.
- 통풍이 되는 장소에서 덮개를 연 채 상태 확인과 중단 기능을 먼저 시험하십시오. 실제 이동과 보호 성공은 별도로 검증해야 합니다.

## 소스 빌드와 테스트

```sh
git clone https://github.com/lastrites2018/Runtinue.git
cd Runtinue
./scripts/setup-repository.sh
./scripts/test.sh
```

테스트는 모의 전원 장치와 입력을 사용하며 실제 수면 설정을 바꾸지 않습니다. 테스트 통과는 실제 Mac의 안전성과 이동 중 작업 지속을 증명하지 않습니다.

CI는 디버그와 release 테스트, 개발 패키지 생성과 내용 검사를 실행합니다. 실행 파일의 arm64 여부, 버전, 코드서명 요구 조건, 설치 스크립트와 manifest(검증 정보 파일)를 확인하며 패키지는 설치하지 않습니다. macOS 작업은 [GitHub의 arm64 `macos-15` 실행기](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)를 사용합니다.

루트의 `VERSION`이 모든 배포 형식의 버전 기준입니다. 빌드는 Info.plist와 manifest에 소스 커밋 SHA와 커밋되지 않은 변경을 기록합니다. dirty(커밋되지 않은 변경이 있는) 개발 패키지는 패키지 SHA-256도 보관하십시오.

소스에서 읽기 전용 진단을 실행할 수 있습니다.

```sh
swift run --disable-sandbox runtinue inspect
swift run --disable-sandbox runtinue diagnose
```

### 개인용 개발 패키지

다음 명령은 임시(ad-hoc) 코드 서명을 사용한 개발 패키지와 검증용 manifest를 만듭니다. Apple 공증과 정식 Installer 서명은 포함하지 않습니다. 보안 경고를 일괄 해제하거나 Gatekeeper를 끄지 마십시오.

```sh
mkdir -p .release
runtinue_package_dir=$(mktemp -d "$PWD/.release/development.XXXXXX")
RUNTINUE_RELEASE_ROOT="$runtinue_package_dir" ./scripts/package-development.sh
```

패키지와 manifest를 같은 디렉터리에 보관하고 SHA-256을 대조하십시오. 다음 명령은 설치하지 않고 패키지와 manifest를 검사합니다.

```sh
runtinue_version=$(./scripts/version.sh)
runtinue_package="$runtinue_package_dir/Runtinue-$runtinue_version-development.pkg"
runtinue_manifest="$runtinue_package.manifest.json"
shasum -a 256 "$runtinue_package"

# 앞서 확인한 64자리 SHA-256으로 바꿉니다.
runtinue_sha256="REPLACE_WITH_VERIFIED_SHA256"

./scripts/install-package.sh "$runtinue_package" \
  --manifest "$runtinue_manifest" --sha256 "$runtinue_sha256"
```

실제 설치는 통풍이 되는 장소에서 덮개를 연 상태로 실행하십시오. 설치 스크립트는 서비스와 시스템 파일을 변경합니다.

```sh
sudo ./scripts/install-package.sh "$runtinue_package" \
  --manifest "$runtinue_manifest" --sha256 "$runtinue_sha256" \
  --apply --allow-power-mutation
```

개발 패키지 검증은 배포 승인이나 하드웨어 안전 인증이 아닙니다.

### SafeClam 설치에서 전환

SafeClam으로 설치한 버전이 남아 있으면 Runtinue 설치가 중단됩니다. 모든 보호 모드를 중단하고 SafeClam 메뉴바를 종료한 뒤 기존 제거 도구를 실행하십시오.

```sh
sudo '/Library/Application Support/com.example.safeclam/uninstall-safeclam'
```

제거 도구는 정상 수면을 확인한 뒤 시스템 구성요소를 제거합니다. 실패하면 파일을 직접 삭제하지 말고 기존 버전의 복구 상태를 확인하십시오.

기존 `~/Library/Application Support/SafeClam`의 설정과 기록은 보존됩니다. Runtinue는 `~/Library/Application Support/Runtinue`를 사용하며 이전 보호 모드를 자동으로 재개하지 않습니다. 앱 식별자가 바뀌므로 Wi-Fi 감지용 위치 권한도 다시 허용해야 합니다.

## 기본 사용법

1. `/Applications/Runtinue.app`을 실행합니다. Wi-Fi를 사용한다면 메뉴에서 감지 권한을 허용합니다.
2. `통근 보호 시작…`을 선택하고 시작 방식을 정합니다.
   - 회사나 집의 Wi-Fi에서 시작한 뒤 휴대전화 핫스팟으로 전환합니다. 기본 연결 대기 시간은 15분입니다.
   - 휴대전화 핫스팟에 먼저 연결한 뒤 바로 시작합니다.
3. 처음 사용하는 핫스팟은 이름을 입력하거나 `현재 Wi-Fi` 옆의 `사용`을 누른 뒤 `휴대전화 핫스팟이 맞습니다`를 선택합니다. 회사나 집의 Wi-Fi를 핫스팟으로 확인하지 마십시오.
4. 보호 시간을 정하고 시작합니다. Flowline이 연결, 인터넷, 기기와 보호 확인을 마치고 메뉴에 `덮개 닫기 가능`을 표시할 때까지 덮개를 열어 두십시오.
5. 도착하면 Trip을 중단하고 정상 수면 복구를 확인합니다.

보호에 성공하면 SSID, 기본 게이트웨이와 Wi-Fi 인터페이스를 저장합니다. 시작 실패와 대기 상태는 기존 대상을 덮어쓰지 않으며, 조합이 달라지면 다시 확인합니다. Wi-Fi 암호는 저장하지 않습니다. 저장한 값은 휴대전화의 신원을 증명하지 않으므로 핫스팟 여부는 사용자가 확인해야 합니다. 연결, 인터넷과 기기 안전 조건은 시작할 때마다 다시 검사합니다.

USB 테더링은 기존 연결에서 Trip을 시작한 뒤 USB로 전환합니다. 앱은 네트워크 인터페이스가 바뀌었는지 확인합니다.

```sh
# 이미 휴대전화 핫스팟에 연결한 경우
runtinue trip start --for 60m --hotspot "My Hotspot" --already-connected

# 회사나 집의 Wi-Fi에서 시작한 뒤 핫스팟으로 전환하는 경우
runtinue trip start --for 60m --hotspot "My Hotspot"

# USB 테더링으로 전환하는 경우
runtinue trip start --for 60m --usb-tether

runtinue status
runtinue stop
```

CLI와 Swift API는 기본적으로 연결 전환을 기다립니다. `--already-connected`와 `.trip(expectedHotspotSSID: ..., alreadyConnected: true)`는 이미 연결한 핫스팟을 사용자가 확인했음을 전달하며 USB 테더링에는 사용할 수 없습니다.

## 안전 정책과 복구 경계

Trip의 기본 최대 시간은 90분입니다. 소프트웨어 정책은 다음 조건에서 실행 유지를 제한합니다.

| 조건 | 동작 |
| --- | --- |
| 배터리 사용, 외부 화면 없음, 덮개 닫힘, 배터리 30% 미만 | 실행 유지 중단 |
| AC 연결 중 충전하지 않거나 충전 표시 중 배터리가 두 차례 연속 감소 | 30% 기준 적용 |
| 충전 중 배터리 10% 미만 | 비상 기준으로 실행 유지 중단 |
| 배터리 정보 확인 불가 | 보호 제한 |
| 외부 화면 없음, 덮개 닫힘, 열 상태 `fair` 이상 | 전원 연결과 관계없이 실행 유지 중단 |

다른 덮개와 화면 조합에는 별도 기준을 적용하며 저전력 모드에서는 기준이 더 엄격해집니다. 이 수치는 소프트웨어 정책이며 안전 인증 기준이 아닙니다.

Helper와 Supervisor는 시스템 수면까지 포함하는 `CLOCK_MONOTONIC_RAW`로 유효 시간(TTL)과 최대 시간을 계산합니다. 수면 중 만료된 lease는 갱신하지 않습니다. [Apple의 연속 시간 설명](https://developer.apple.com/documentation/driverkit/mach_continuous_time)을 참고하십시오.

활성 Helper는 1초마다 `SleepDisabled`를 읽습니다. 설정이 풀리면 한 번 복구한 뒤 다시 읽어 확인하고, 실패하거나 읽을 수 없으면 정상 수면 복구로 전환합니다. 복구를 확인하지 못하면 상태와 lease 기록을 유지하며 재시도합니다. 덮개 레지스트리와 내장 화면 신호가 충돌하면 더 보수적인 덮개 기준을 적용하고 진단 이벤트를 기록합니다. OS가 프로세스를 멈춘 동안에는 감시도 멈추므로 즉시 복구를 보장하지 않습니다.

프로세스 간 통신은 프로토콜 5를 사용하므로 앱, CLI, Supervisor와 Helper를 같은 패키지로 교체해야 합니다. XPC 호출자는 macOS의 [연결 단위 코드서명 검증](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))을 사용합니다. 성공 응답도 lease ID, 사용자 UID, 실제 수면 설정과 유효 기한이 모두 일치해야 인정합니다.

## 상태 확인과 제거

```sh
runtinue status --json
runtinue inspect
runtinue diagnose
runtinue history --limit 20
runtinue events
```

기록보다 실시간 상태를 우선하십시오. 복구 중이거나 상태가 불명확하면 덮개를 열고 사용을 중단하십시오. 수면 억제가 남아 있는지 확인하기 전에 서비스 파일을 삭제하지 마십시오.

제거하기 전에 모든 유지 모드를 중단하십시오. 제거 스크립트는 정상 수면을 확인한 뒤 시스템 구성요소를 제거합니다. 확인에 실패하면 복구에 필요한 구성요소를 보존하며 사용자 기록과 설정도 남깁니다.

```sh
runtinue stop
sudo ./scripts/uninstall.sh
```

## 실기기 검증과 배포 기준

실제 덮개 닫힘, AC 전환, 발열 유도와 프로세스 강제 종료 시험을 완료했다는 공개 기록은 아직 없습니다. 자동화 검사와 패키지 정적 검증만으로 무인 이동 운용이나 일반 사용자 배포를 판단할 수 없습니다. macOS 13과 최신 macOS의 깨끗한 설치에서 `SleepDisabled` 읽기를 확인해야 하며, 키가 없으면 설치와 보호를 중단합니다.

검증은 패키지 SHA-256과 커밋에 결박합니다. 패키지가 달라지면 이전 결과를 재사용할 수 없습니다. 다음 명령은 Mac과 패키지 식별 정보를 담은 **미실행 기록**을 만들며 전원 설정과 시험 결과를 바꾸지 않습니다.

```sh
./scripts/hardware-validation.sh create \
  "$runtinue_manifest" "$runtinue_package.hardware.json"
```

| 시험 영역 | 필수 확인 |
| --- | --- |
| 설치와 복구 | 새 설치, 정상 획득과 해제, root Helper 직접 호출 거부, Supervisor 종료, Helper 종료 후 복구 |
| 이동과 전원 | 통풍되는 책상에서 덮개 닫힘 15분, AC에서 배터리 전환, 핫스팟 전환, 이미 연결한 핫스팟 시작, USB 테더링 |
| 안전 중단 | 배터리 기준, 열 상태 기준, 센서 읽기 불가에서 정상 수면 복구 |
| 수명주기 | 재부팅, 업그레이드와 제거 후 정상 수면 확인 |

각 시험은 덮개를 연 정상 수면 설정에서 시작하고 종료 후 `SleepDisabled=No`를 확인합니다. 기기를 밀폐하거나 위험한 온도로 가열하지 마십시오. 안전하게 실행할 수 없는 항목은 `notRun`으로 남겨야 합니다. 실제 전원을 바꾸는 `integration-test.sh`는 별도의 명시적 동의와 고정 패키지 검사를 요구합니다.

실행한 항목에만 `passed`, UTC 시각과 `operatorConfirmed`를 기록합니다. 검사는 대상 불일치, 누락, 시간 오류와 정상 수면 복구 미확인을 거부합니다. 기록의 사실 여부는 독립적으로 증명하지 못하며 통과 범위는 기록한 Mac 모델과 OS에 한정됩니다.

```sh
./scripts/hardware-validation.sh verify \
  "$runtinue_manifest" "$runtinue_package.hardware.json"
```

정식 배포 후보는 깨끗한 소스와 현재 커밋을 가리키는 `v$(./scripts/version.sh)` 태그를 요구합니다. `release.sh`는 Developer ID 서명, 공증과 티켓 첨부(staple) 후 후보를 보존합니다. 실기기 기록이 없으면 종료 코드 78로 release 포인터 게시를 보류합니다. 검증한 후보의 manifest와 `RUNTINUE_VALIDATION_RECORD`를 지정해 `release-manifest.sh publish`를 실행해야 합니다. 개발 패키지 포인터는 정식 배포 승인을 뜻하지 않으며 GitHub Release는 자동으로 만들지 않습니다.

실기기 기록과 원본 로그는 `.release` 아래에 로컬로 보관합니다. 공개 검증 결과는 개인정보와 기기별 네트워크 정보를 제거한 뒤 이 README에만 정리합니다.

## 저장소 작업 규칙

공개 파일은 `.gitignore`의 허용 목록으로 관리합니다. 소스, 테스트, 실행 스크립트와 필요한 설정을 포함하며 설명 문서는 루트의 `README.md`만 게시합니다. `LICENSE`는 사용 허락을 위한 별도 파일입니다. 그 밖의 문서, 로그, 인증 정보와 빌드 결과는 로컬에 보관합니다.

새로 복제한 환경에서는 `./scripts/setup-repository.sh`를 실행하십시오. 커밋 전에는 스테이징한 파일을, 푸시 전에는 전체 이력을 검사합니다. 금지 파일이 이전 커밋에 남아 있어도 푸시를 차단하며 심볼릭 링크와 서브모듈은 허용하지 않습니다.

```sh
./scripts/verify-public-tree.sh --staged
./scripts/verify-public-tree.sh --history HEAD
./scripts/test-public-boundary.sh
```

CI도 공개 파일 경계를 검사합니다. Git 훅은 clone마다 설치해야 하며 GitHub 웹 편집과 훅 우회까지 막지는 못합니다. 새 파일을 추가할 때는 공개 가능성을 먼저 확인하십시오. 인증 정보, 개인 경로와 원본 로그를 코드, README, 이슈와 PR에 넣지 마십시오.

## 라이선스

[MIT](LICENSE). 개인적인 필요에 맞춰 개발하고 공개합니다. 소스를 검토하고 환경에 맞게 수정해 사용할 수 있습니다. 안전 경고와 라이선스의 책임 제한을 먼저 확인하십시오.
