<#
  构建并签名 AppGallery 发布包。

  为什么不用 hvigor 直接签：hvigor 只接受 DevEco GUI 加密过的口令
  （要求长度 >= 32），明文会报 "length ... is less than 32"。这里改成
  「先出未签名包，再用 SDK 的 hap-sign-tool 签」，明文口令即可。

  用法： pwsh -File tools\sign-release.ps1
  产物： out\光谱工坊-<versionName>-release.hap
#>

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$env:NODE_HOME = 'D:\DevEco Studio\tools\node'
$env:JAVA_HOME = 'D:\DevEco Studio\jbr'
$env:DEVECO_SDK_HOME = 'D:\DevEco Studio\sdk'
$env:HVIGOR_USER_HOME = 'E:\DevEcoProjects\tools\hvigor-home'
$env:HVIGOR_PNPM_STORE_PATH = 'E:\DevEcoProjects\tools\pnpm-store'
$env:npm_config_cache = 'E:\DevEcoProjects\tools\npm-cache'
$env:npm_config_userconfig = 'E:\DevEcoProjects\tools\npmrc'
$env:Path = "$env:JAVA_HOME\bin;D:\DevEco Studio\tools\node;D:\DevEco Studio\tools\ohpm\bin;" +
            "D:\DevEco Studio\sdk\default\openharmony\native\build-tools\cmake\bin;" +
            "D:\DevEco Studio\sdk\default\openharmony\native\llvm\bin;C:\msys64\ucrt64\bin;$env:Path"

# 1. 未签名包。应用市场要的是 .app（App Pack），不是单个 .hap。
& 'D:\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleApp --mode project `
    -p product=release -p buildMode=release --no-daemon
if ($LASTEXITCODE -ne 0) { throw "hvigor 构建失败" }

$unsigned = Get-ChildItem "$root\build\outputs\release" -Filter '*-unsigned.app' -ErrorAction SilentlyContinue |
             Select-Object -First 1 -ExpandProperty FullName
if (-not $unsigned) { throw "找不到未签名 .app，检查 build\outputs\release" }

# 2. 签名
$version = (Select-String -Path "$root\AppScope\app.json5" -Pattern 'versionName"\s*:\s*"([^"]+)"').Matches[0].Groups[1].Value
$out = "$root\out\光谱工坊-$version-release.app"
New-Item -ItemType Directory -Force -Path "$root\out" | Out-Null

$jar = 'D:\DevEco Studio\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'
& "$env:JAVA_HOME\bin\java.exe" -jar $jar sign-app -mode localSign -keyAlias spektra `
    -signAlg SHA256withECDSA `
    -appCertFile "$root\signing\spektra-release.cer" `
    -profileFile "$root\signing\spektra-release.p7b" `
    -inFile $unsigned -outFile $out `
    -keystoreFile "$root\signing\spektra.p12" `
    -keyPwd 'SpektraWorkshop2026' -keystorePwd 'SpektraWorkshop2026' -profileSigned 1
if ($LASTEXITCODE -ne 0) { throw "签名失败" }

# 3. 自检
& "$env:JAVA_HOME\bin\java.exe" -jar $jar verify-app -inFile $out
if ($LASTEXITCODE -ne 0) { throw "签名校验失败" }

$size = [math]::Round((Get-Item $out).Length / 1MB, 1)
Write-Host "`n发布包就绪：$out ($size MB)" -ForegroundColor Green