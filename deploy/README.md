# 서버 설치 순서

`setup.ps1`을 실행해서 Vault 봉인을 해제하기까지의 순서를 정리한 문서입니다. 새 서버를 세팅하거나 개발 PC에 운영 환경과 같은 환경을 만들 때 위에서부터 차례대로 따라 하면 됩니다.

전체 작업은 약 20분이 걸리고, 중간에 재부팅이 1번 필요합니다.

## 준비물

- Windows Server 2019 또는 Windows 10/11
- 관리자 계정
- 인터넷 연결 (설치 파일을 내려받기 위해 필요합니다)
- 이 저장소의 사본

새 서버에는 아직 Git이 없습니다. 그래서 GitHub에서 저장소를 ZIP으로 내려받아 압축을 풀거나, 다른 PC에서 폴더를 복사해 옵니다. Git은 `setup.ps1`이 설치합니다.

## 1. `setup.ps1` 실행 (약 10분)

1. 시작 메뉴에서 "PowerShell"을 마우스 오른쪽 버튼으로 누르고 **관리자 권한으로 실행**을 선택합니다.
2. 저장소 폴더로 이동한 뒤 스크립트를 실행합니다.

   ```powershell
   cd C:\Users\user\projects\wiki
   powershell -ExecutionPolicy Bypass -File .\deploy\setup.ps1
   ```

   `.\deploy\setup.ps1`처럼 스크립트를 바로 실행하면 "이 시스템에서 스크립트를 실행할 수 없으므로" 오류가 납니다. Windows의 기본 실행 정책이 스크립트 실행을 막기 때문입니다. 반드시 위처럼 `-ExecutionPolicy Bypass`를 붙여서 실행합니다.

3. 마지막에 "설치 완료. 남은 일:"이 출력되면 성공입니다.

중간에 아래 경고가 출력될 수 있는데, 무시해도 됩니다. uv가 관리자 계정 폴더에 Python 바로가기를 만들려다가 출력하는 안내이고, 서비스는 `C:\tools\python`에 설치된 Python을 직접 사용합니다.

```
warning: `C:\Users\...\.local\bin` is not on your PATH.
```

### 스크립트가 하는 일

| 작업 | 위치 |
|---|---|
| Git, Node, nginx, Vault, NSSM, uv, Python 설치 | `C:\tools\<이름>-<버전>` (Git만 `C:\Program Files\Git`) |
| 데이터 폴더 생성, SYSTEM과 Administrators만 접근하도록 잠금 | `C:\wiki-data`, `C:\wiki-files`, `C:\vault`, `C:\wiki-logs` |
| 데이터 저장소 생성 (`git init`) | `C:\wiki-data` |
| 서비스 등록 (자동 시작) | `wiki-vault`, `wiki-nginx`, `wiki-api` (`api/` 코드가 있을 때만) |

스크립트는 다시 실행해도 안전합니다. 이미 설치된 버전은 건너뛰고, 설정은 같은 값으로 다시 씁니다.

## 2. 재부팅

서비스는 재부팅해야 새로 추가된 PATH와 환경 변수를 읽습니다. 재부팅하기 전에는 `vault` 명령도 찾을 수 없습니다.

재부팅한 뒤 관리자 PowerShell에서 서비스가 실행 중인지 확인합니다.

```powershell
Get-Service wiki-*
```

`wiki-nginx`와 `wiki-vault`가 모두 `Running`으로 나와야 합니다.

## 3. Vault 초기화 (처음 한 번만)

> **이미 쓰던 Vault 데이터를 백업에서 복원한 서버라면 이 단계를 건너뜁니다.** 초기화는 새 Vault를 만드는 작업입니다. 복원한 서버에서는 기존 해제 키로 4단계의 봉인 해제만 하면 됩니다.

```powershell
$env:VAULT_ADDR='http://127.0.0.1:8200'
vault operator init
```

출력에는 해제 키(`Unseal Key 1`~`5`) 5개와 `Initial Root Token` 1개가 들어 있습니다. 이 값들은 **다시 확인할 방법이 없습니다.**

- 출력된 값을 비밀번호 관리자처럼 서버 밖의 안전한 곳에 바로 옮겨 둡니다.
- 서버의 파일, git 저장소, 메신저에는 남기지 않습니다. 서버의 디스크가 유출되더라도 Vault의 내용을 지키기 위해서입니다.
- 해제 키 5개 가운데 3개를 잃어버리면 Vault에 저장한 비밀을 영영 꺼낼 수 없습니다.

## 4. Vault 봉인 해제 (재부팅할 때마다)

Vault는 시작될 때마다 봉인(sealed) 상태입니다. 봉인을 해제하기 전까지 위키는 원본을 저장하면 "검사 대기" 상태로 두고, 비밀 값 보기를 막습니다.

1. 관리자 PowerShell에서 아래 명령을 실행하고 해제 키 하나를 입력합니다.

   ```powershell
   $env:VAULT_ADDR='http://127.0.0.1:8200'
   vault operator unseal
   ```

2. `vault operator unseal`을 2번 더 실행합니다. 매번 앞에서 입력하지 않은 다른 키를 입력합니다.
3. 상태를 확인합니다.

   ```powershell
   vault status
   ```

   `Sealed`가 `false`로 나오면 완료입니다.

## 문제 해결

| 증상 | 원인과 해결 |
|---|---|
| "이 시스템에서 스크립트를 실행할 수 없으므로" | 실행 정책이 막은 것입니다. `powershell -ExecutionPolicy Bypass -File ...`로 실행합니다. |
| "해시 불일치" | 내려받은 파일이 `$Tools`에 기록한 해시와 다릅니다. 파일을 다시 받아도 해시가 다르다면 설치를 멈추고 원인을 확인합니다. |
| nssm.cc에서 다운로드 실패 | nssm.cc가 가끔 503 오류를 냅니다. 스크립트가 5번까지 다시 시도하고, 그래도 실패하면 잠시 뒤 스크립트를 다시 실행합니다. |
| 서비스가 `Running`이 아님 | `C:\wiki-logs\<서비스 이름>.log`를 확인합니다. |
| `C:\wiki-data`에 "Permission denied" | 의도된 잠금입니다. 관리자 PowerShell에서 접근합니다. |
| 브라우저에서 `http://127.0.0.1/` 접속 시 500 오류 | 웹 빌드(`web/dist`)가 아직 없어서 생기는 오류입니다. 웹을 빌드하면 사라집니다. |
| `vault` 명령을 찾을 수 없음 | 재부팅하기 전에는 PATH에 없습니다. 재부팅하거나 `C:\tools\vault-<버전>\vault.exe`로 실행합니다. |

## 버전 올리기

1. `setup.ps1`의 `$Tools`에서 해당 도구의 `Version`을 고칩니다.
2. 새 설치 파일을 내려받아 해시를 계산하고, 결과로 `Sha256`을 바꿉니다. 공식 체크섬 파일이 있다면 그 값과 일치하는지도 확인합니다.

   ```powershell
   (Get-FileHash .\내려받은파일.zip).Hash.ToLower()
   ```

3. 변경 사항을 커밋하고 1~4단계를 다시 진행합니다. Vault 초기화(3단계)는 건너뜁니다.

이전 버전은 `C:\tools`에 그대로 남아 있습니다. 문제가 생기면 `Version`과 `Sha256`을 이전 값으로 되돌리고 스크립트를 다시 실행합니다.
