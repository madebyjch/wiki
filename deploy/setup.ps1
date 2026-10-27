#Requires -RunAsAdministrator
# 사내 위키 서버 설치 (docs/DESIGN.md 10장). 다시 실행해도 안전하다: 이미 설치된 버전은 건너뛴다.
# 버전을 올릴 때는 $Tools의 Version, Sha256만 고치고 커밋한다. 이 파일이 서버 구성의 기록이다.
param(
    [string]$AppDir    = (Split-Path $PSScriptRoot),
    [string]$ToolsDir  = 'C:\tools',
    [string]$DataRepo  = 'C:\wiki-data',
    [string]$FileStore = 'C:\wiki-files',
    [string]$VaultDir  = 'C:\vault',
    [string]$LogDir    = 'C:\wiki-logs'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # 켜 두면 Invoke-WebRequest가 매우 느리다
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'

$Python = '3.14.9'
# Url, Bin의 {0} = Version, {1} = Version에서 '.windows'를 뺀 값 (git 파일명용)
$Tools = [ordered]@{
    git   = @{ Version = '2.56.0.windows.3'; Sha256 = 'dc6d3db061999136e139f31376c5582a9ed6f36a4ea12f15e54ad7fa2bfc0bf2'
               Url = 'https://github.com/git-for-windows/git/releases/download/v{0}/Git-{1}-64-bit.exe' }
    nssm  = @{ Version = '2.24'; Sha256 = '727d1e42275c605e0f04aba98095c38a8e1e46def453cdffce42869428aa6743'
               Url = 'https://nssm.cc/release/nssm-{0}.zip'; Bin = 'nssm-{0}\win64' }
    nginx = @{ Version = '1.30.6'; Sha256 = 'c6ee35edb0a861063323f709192ae50d1eefaf2ea7d00678bd2b22d8542dc61e'
               Url = 'https://nginx.org/download/nginx-{0}.zip'; Bin = 'nginx-{0}' }
    vault = @{ Version = '2.2.1'; Sha256 = 'ec0544b354adf70e11db5247b9fa5e7046f70bf0c654944e0095780b5f056342'
               Url = 'https://releases.hashicorp.com/vault/{0}/vault_{0}_windows_amd64.zip'; Bin = '.' }
    node  = @{ Version = '24.22.1'; Sha256 = 'd2046d28c2c3dcd211ac5145c0bf30e2047ef9dfb306693c8c6e2eccd8b95fa5'
               Url = 'https://nodejs.org/dist/v{0}/node-v{0}-win-x64.zip'; Bin = 'node-v{0}-win-x64' }
    uv    = @{ Version = '0.13.5'; Sha256 = 'a38b8d1902b7cfbc76b423ba1bb456f623f42064cdc72628b6075b89afd1019a'
               Url = 'https://github.com/astral-sh/uv/releases/download/{0}/uv-x86_64-pc-windows-msvc.zip'; Bin = '.' }
}

function Save-Verified($t) {
    $url = $t.Url -f $t.Version, ($t.Version -replace '\.windows', '')
    $file = Join-Path $env:TEMP (Split-Path $url -Leaf)
    for ($i = 1; -not (Test-Path $file); $i++) {
        try { Invoke-WebRequest $url -OutFile $file -UseBasicParsing }
        catch { Remove-Item $file -ErrorAction Ignore; if ($i -ge 5) { throw }; Start-Sleep 10 }  # nssm.cc가 가끔 503을 준다
    }
    if ((Get-FileHash $file).Hash -ne $t.Sha256) { Remove-Item $file; throw "해시 불일치: $url" }
    $file
}

# 압축을 C:\tools\<이름>-<버전>에 풀고 실행 파일 폴더를 돌려준다. 버전별 폴더라 되돌리기 쉽다.
function Install-Zip($Name) {
    $t = $Tools[$Name]
    $dest = Join-Path $ToolsDir "$Name-$($t.Version)"
    if (-not (Test-Path $dest)) { Expand-Archive (Save-Verified $t) $dest }
    $bin = Join-Path $dest ($t.Bin -f $t.Version)
    # 시스템 PATH에서 같은 도구의 이전 버전을 빼고 새 버전을 넣는다 (%SystemRoot% 같은 항목이 풀리지 않게 레지스트리로 직접)
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $keep = (Get-Item $key).GetValue('Path', '', 'DoNotExpandEnvironmentNames') -split ';' |
        Where-Object { $_ -and $_ -notlike "$ToolsDir\$Name-*" }
    Set-ItemProperty $key Path ((@($keep) + $bin) -join ';') -Type ExpandString
    $env:Path = "$bin;$env:Path"
    $bin
}

# SYSTEM과 Administrators만 접근 (서버를 다른 프로젝트와 같이 쓰므로). 이름 대신 SID: 한글 Windows에서도 동작
function Lock-Dir($Path) {
    New-Item -ItemType Directory -Force $Path | Out-Null
    icacls $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
}

function Nssm { & $script:NssmExe @args | Out-Null; if ($LASTEXITCODE) { throw "nssm $args 실패" } }

function Register-WikiService($Name, $Exe, $Arguments, $WorkDir) {
    if (-not (Get-Service $Name -ErrorAction Ignore)) { Nssm install $Name $Exe }
    Nssm set $Name Application $Exe
    if ($Arguments) { Nssm set $Name AppParameters $Arguments }
    Nssm set $Name AppDirectory $WorkDir
    Nssm set $Name AppNoConsole 1  # NSSM 2.24가 최신 Windows에서 서비스 시작에 실패하는 문제 회피
    Nssm set $Name AppStdout "$LogDir\$Name.log"
    Nssm set $Name AppStderr "$LogDir\$Name.log"
    Nssm set $Name AppRotateFiles 1
    Nssm set $Name AppRotateBytes 10485760
    Nssm set $Name Start SERVICE_AUTO_START
}

# --- 폴더 ---
$DataRepo, $FileStore, $VaultDir, $LogDir | ForEach-Object { Lock-Dir $_ }
if (Test-Path "$AppDir\config.yaml") { icacls "$AppDir\config.yaml" /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null }

# --- 프로그램 ---
$script:NssmExe = Join-Path (Install-Zip nssm) 'nssm.exe'
$nginxDir = Install-Zip nginx
$vaultExe = Join-Path (Install-Zip vault) 'vault.exe'
Install-Zip node | Out-Null
$uv = Join-Path (Install-Zip uv) 'uv.exe'

$currentGit = try { git --version } catch { '' }
if ($currentGit -ne "git version $($Tools.git.Version)") {
    Start-Process (Save-Verified $Tools.git) '/VERYSILENT /NORESTART /NOCANCEL /SP- /SUPPRESSMSGBOXES' -Wait
    $env:Path = "C:\Program Files\Git\cmd;$env:Path"
}

# 서비스(SYSTEM 계정)도 같은 Python을 쓰도록 사용자 폴더가 아닌 곳에 설치
[Environment]::SetEnvironmentVariable('UV_PYTHON_INSTALL_DIR', "$ToolsDir\python", 'Machine')
[Environment]::SetEnvironmentVariable('KORDOC_OFFLINE', '1', 'Machine')
$env:UV_PYTHON_INSTALL_DIR = "$ToolsDir\python"
& $uv python install $Python

# --- 데이터 저장소 (원격 없음, DESIGN 2장) ---
if (-not (Test-Path "$DataRepo\.git")) { git init -b main $DataRepo }
git -C $DataRepo config core.autocrlf false   # 줄바꿈 변환 금지: 판 비교와 각주 줄 번호 보호
git -C $DataRepo config core.quotepath false  # 한글 파일명 그대로 출력
git -C $DataRepo config core.longpaths true
$safe = $DataRepo -replace '\\', '/'
if (@(git config --system --get-all safe.directory) -notcontains $safe) { git config --system --add safe.directory $safe }  # 서비스는 SYSTEM으로 실행되므로 소유자 검사 통과용
try { Add-MpPreference -ExclusionPath $DataRepo } catch { Write-Warning "Defender 예외 등록 실패: $_" }  # git 작업 속도. 업로드 파일 폴더는 검사 유지

# --- Vault ---
$vaultHcl = Join-Path $VaultDir 'config.hcl'
if (-not (Test-Path $vaultHcl)) {
    [IO.File]::WriteAllText($vaultHcl, @"
storage "file" {
  path = "$($VaultDir -replace '\\', '/')/data"
}
listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}
disable_mlock = true
"@)  # BOM 없는 UTF-8
}
Register-WikiService wiki-vault $vaultExe "server -config=$vaultHcl" $VaultDir

# --- nginx ---
$webRoot = "$AppDir\web\dist" -replace '\\', '/'
[IO.File]::WriteAllText("$nginxDir\conf\nginx.conf", @"
worker_processes 1;
events { worker_connections 1024; }
http {
    include mime.types;
    client_max_body_size 500m;  # DESIGN 11장 업로드 제한
    server {
        listen 80;
        root "$webRoot";
        location / { try_files `$uri /index.html; }
        location /api/ {
            proxy_pass http://127.0.0.1:8000;
            proxy_read_timeout 600s;  # 큰 파일 저장, kordoc 변환
            proxy_send_timeout 600s;
        }
    }
}
"@)  # nginx는 BOM을 읽지 못한다
Register-WikiService wiki-nginx "$nginxDir\nginx.exe" $null $nginxDir

# --- API (앱 코드가 생기면 등록) ---
$apiDir = "$AppDir\api"
if (Test-Path "$apiDir\pyproject.toml") {
    Push-Location $apiDir
    & $uv sync --frozen --python $Python
    if (Test-Path package-lock.json) { npm ci }  # kordoc
    Pop-Location
    # 앱 진입점이 정해지면 app.main:app을 맞춘다
    Register-WikiService wiki-api "$apiDir\.venv\Scripts\python.exe" '-m uvicorn app.main:app --host 127.0.0.1 --port 8000' $apiDir
}

Write-Host @"

설치 완료. 남은 일:
1. 재부팅한다 (서비스가 새 PATH, 환경 변수를 읽으려면 필요. 버전을 올린 뒤에도 마찬가지)
2. 처음 한 번만 Vault를 초기화한다: `$env:VAULT_ADDR='http://127.0.0.1:8200'; vault operator init
   나온 해제 키와 root 토큰은 서버가 아닌 곳에 보관한다
3. 재부팅할 때마다 봉인 해제: vault operator unseal (키 3개 입력)
"@
