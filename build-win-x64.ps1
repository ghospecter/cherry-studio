<#
  build-win-x64.ps1 — Cherry Studio 一键编译打包 (win32-x64)

  用法:
    powershell -ExecutionPolicy Bypass -File build-win-x64.ps1            # 常规打包
    powershell -ExecutionPolicy Bypass -File build-win-x64.ps1 -Bootstrap # 含 pnpm install
    powershell -ExecutionPolicy Bypass -File build-win-x64.ps1 -NoProxy   # 直连网络(无需代理)

  前提:
    - 已执行过 pnpm install(或用 -Bootstrap 在此执行)
    - 已存在 .env(由 .env.example 复制)

  注意:
    - 本脚本含本机特定值(代理 127.0.0.1:7897、VS2022 路径),仅供本机使用,请勿直接提交到仓库。
    - 代理是因为本机 shell 直连 GitHub 超时、而浏览器走本地代理;若你的环境可直连,用 -NoProxy 或改 $Proxy 为空。
#>
param(
  [string]$Proxy = "http://127.0.0.1:7897",                       # GitHub 下载用的本地代理;置空("")则直连
  [string]$VsPath = "D:\Program Files\Microsoft Visual Studio\2022\Professional",
  [switch]$Bootstrap,                                            # 加此开关会在打包前先执行 pnpm install
  [switch]$NoProxy                                              # 加此开关则不设置代理
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root
Write-Host "==> 工作目录: $root"

# 1) 网络:本机 shell 直连 GitHub 超时,浏览器走本地代理。设置后下载二进制/依赖可用。
if (-not $NoProxy -and $Proxy) {
  $env:HTTP_PROXY  = $Proxy; $env:HTTPS_PROXY = $Proxy
  $env:http_proxy  = $Proxy; $env:https_proxy = $Proxy
  Write-Host "==> 代理已设置: $Proxy"
} else {
  Write-Host "==> 不使用代理(直连)"
}

# 2) VS2022 工具链(供 node-pty / better-sqlite3 等原生模块重编译)
$env:GYP_MSVS_VERSION = "2022"
$env:GYP_MSVS_OVERRIDE_PATH = $VsPath

# 3) 可选:安装依赖(CI=true 跳过 prepare 里的 prek install)
if ($Bootstrap) {
  $env:CI = "true"
  Write-Host "==> [1/5] pnpm install"
  pnpm install --frozen-lockfile
  Remove-Item env:CI
}

# 4) node-pty 默认开启 Spectre 缓解,而本机 VS2022 未安装 Spectre 缓解库(MSB8040)。
#    将 binding.gyp 里的 SpectreMitigation 改为 false(幂等:仅当仍为 'Spectre' 时改)。
$gyp = Get-ChildItem -Path $root -Recurse -Filter binding.gyp -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'node-pty' } | Select-Object -First 1
if ($gyp) {
  $content = Get-Content $gyp.FullName -Raw
  if ($content -match "'SpectreMitigation': 'Spectre'") {
    Set-Content $gyp.FullName ($content -replace "'SpectreMitigation': 'Spectre'", "'SpectreMitigation': 'false'")
    Write-Host "==> [2/5] 已修补 node-pty binding.gyp (禁用 Spectre 缓解)"
  } else {
    Write-Host "==> [2/5] node-pty 无需修补(已非 Spectre)"
  }
} else {
  Write-Host "==> [2/5] 未找到 node-pty binding.gyp,跳过修补"
}

# 5) 编译渲染层/主进程(electron-vite -> out/),含 typecheck
Write-Host "==> [3/5] pnpm run build (typecheck + electron-vite build)"
pnpm run build

# 6) 下载打包所需的外部二进制(mise/bun/uv/rg/mingit),已存在且版本一致则跳过
Write-Host "==> [4/5] 下载捆绑二进制 (download-binaries.js win32 x64)"
node scripts/download-binaries.js win32 x64

# 7) 打包。不设置 CI,避免触发 electron-builder 隐式发布。
Write-Host "==> [5/5] electron-builder --win --x64"
pnpm exec electron-builder --win --x64

Write-Host "==> 完成。产物位于 dist\ (Cherry-Studio-2.0.8-x64-setup.exe / -portable.exe)"
