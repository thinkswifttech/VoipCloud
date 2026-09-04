[CmdletBinding()]
param(
  [string]$Configuration = "Release",
  [string]$CertificateThumbprint = $env:VOIPCLOUD_WINDOWS_SIGNING_THUMBPRINT,
  [string]$TimestampUrl = "http://timestamp.digicert.com",
  [string]$ShortBuildDrive = "V:"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$linphoneDll = Join-Path $projectRoot `
  "windows\third_party\linphone\linphone-sdk\win64\bin\liblinphone.dll"

if (-not (Test-Path -LiteralPath $linphoneDll)) {
  throw "The pinned Linphone Windows SDK is missing. Follow windows/third_party/linphone/README.md before packaging."
}

function Resolve-Executable {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string[]]$Candidates = @()
  )

  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -ne $command) { return $command.Source }
  foreach ($candidate in $Candidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and
        (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }
  return $null
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} `
  "Microsoft Visual Studio\Installer\vswhere.exe"
$visualStudio = $null
if (Test-Path -LiteralPath $vswhere) {
  $visualStudio = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
}

$flutter = Resolve-Executable "flutter" @(
  $(if ($env:FLUTTER_ROOT) {
      Join-Path $env:FLUTTER_ROOT "bin\flutter.bat"
    }),
  "D:\coding\Flutter_SDK\flutter\bin\flutter.bat"
)
$cmakeBin = if ($visualStudio) {
  Join-Path $visualStudio `
    "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
} else { $null }
$cmake = Resolve-Executable "cmake" @(
  $(if ($cmakeBin) { Join-Path $cmakeBin "cmake.exe" })
)
$cpack = Resolve-Executable "cpack" @(
  $(if ($cmakeBin) { Join-Path $cmakeBin "cpack.exe" })
)

foreach ($tool in @{
    flutter = $flutter
    cmake = $cmake
    cpack = $cpack
  }.GetEnumerator()) {
  if ([string]::IsNullOrWhiteSpace($tool.Value)) {
    throw "Required command '$($tool.Key)' was not found."
  }
}

$windowsKitBin = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
$signToolCandidates = @()
if (Test-Path -LiteralPath $windowsKitBin) {
  $signToolCandidates = Get-ChildItem -LiteralPath $windowsKitBin `
    -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName "x64\signtool.exe" }
}
$signTool = Resolve-Executable "signtool" $signToolCandidates

$wixRoots = @(
  "${env:ProgramFiles(x86)}\WiX Toolset v3.14",
  "${env:ProgramFiles(x86)}\WiX Toolset v3.11",
  "$env:ProgramFiles\WiX Toolset v3.14",
  "$env:ProgramFiles\WiX Toolset v3.11"
)
$wixRoot = $wixRoots | Where-Object {
  (Test-Path -LiteralPath (Join-Path $_ "bin\candle.exe")) -and
  (Test-Path -LiteralPath (Join-Path $_ "bin\light.exe"))
} | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($wixRoot)) {
  throw "WiX Toolset 3.14 was not found. Install WiXToolset.WiXToolset before packaging."
}
$env:WIX = $wixRoot

$buildProjectRoot = $projectRoot
$mappedDrive = $false
if ($projectRoot.Length -gt 100) {
  if (Get-PSDrive -Name $ShortBuildDrive.TrimEnd(':') `
      -ErrorAction SilentlyContinue) {
    throw "$ShortBuildDrive is already in use; pass a free -ShortBuildDrive."
  }
  $projectParent = Split-Path -Parent $projectRoot
  & subst.exe $ShortBuildDrive $projectParent
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to create temporary $ShortBuildDrive build mapping."
  }
  $mappedDrive = $true
  $buildProjectRoot = Join-Path `
    "$ShortBuildDrive\" (Split-Path -Leaf $projectRoot)

  # MSVC still applies a 260-character limit to some generated object paths.
  # Reconfigure only the generated Windows tree against the short root.
  $windowsBuild = Join-Path $projectRoot "build\windows"
  if (-not $windowsBuild.StartsWith(
      $projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean a build directory outside the project."
  }
  if (Test-Path -LiteralPath $windowsBuild) {
    Remove-Item -LiteralPath $windowsBuild -Recurse -Force
  }
}

# Flutter 3.41 can omit the C++ wrapper sources when a project is reached via
# SUBST. Pre-populate its ignored ephemeral directory from the same SDK cache.
$flutterRoot = Split-Path -Parent (Split-Path -Parent $flutter)
$wrapperSource = Join-Path $flutterRoot `
  "bin\cache\artifacts\engine\windows-x64\cpp_client_wrapper"
$wrapperTarget = Join-Path $projectRoot `
  "windows\flutter\ephemeral\cpp_client_wrapper"
if (Test-Path -LiteralPath $wrapperSource) {
  New-Item -ItemType Directory -Force -Path $wrapperTarget | Out-Null
  Copy-Item -Path (Join-Path $wrapperSource "*") `
    -Destination $wrapperTarget -Recurse -Force
}

Push-Location $buildProjectRoot
try {
  # Dependencies are resolved before release packaging. Avoid an implicit
  # network-backed `pub get` making an otherwise reproducible MSI build hang.
  & $flutter build windows --release --no-pub
  if ($LASTEXITCODE -ne 0) { throw "Flutter Windows release build failed." }

  # Flutter may honor a configured build directory outside the project root.
  # Search only the mapped project parent and select its newest CPack file,
  # keeping the path on the short drive for CMake consistency. Incremental
  # Flutter builds do not necessarily refresh CPackConfig.cmake's timestamp.
  $buildSearchRoot = Split-Path -Parent $buildProjectRoot
  $cpackConfig = Get-ChildItem -Path $buildSearchRoot `
    -Filter "CPackConfig.cmake" -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($null -eq $cpackConfig) {
    throw "CPackConfig.cmake was not generated by the Windows build."
  }

  $outputDirectory = Join-Path $buildProjectRoot "build\windows\msi"
  New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
  $cmakeBuildDirectory = Split-Path -Parent $cpackConfig.FullName
  & $cmake -S (Join-Path $buildProjectRoot "windows") `
    -B $cmakeBuildDirectory -DVOIPCLOUD_CPACK_INSTALL=ON
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to configure the relative CPack install graph."
  }
  try {
    & $cpack -G WIX -C $Configuration --config $cpackConfig.FullName `
      -B $outputDirectory
    if ($LASTEXITCODE -ne 0) {
      throw "CPack/WiX MSI generation failed. Install WiX Toolset and retry."
    }
  } finally {
    # Leave the generated tree usable by normal `flutter build windows`, whose
    # INSTALL target writes directly to the runner Release directory.
    & $cmake -S (Join-Path $buildProjectRoot "windows") `
      -B $cmakeBuildDirectory -DVOIPCLOUD_CPACK_INSTALL=OFF
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "Unable to restore the normal Flutter install graph."
    }
  }

  $msi = Get-ChildItem -Path $outputDirectory -Filter "*.msi" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($null -eq $msi) { throw "MSI generation completed without an MSI output." }

  if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    if ([string]::IsNullOrWhiteSpace($signTool)) {
      throw "signtool is required when a signing thumbprint is supplied."
    }
    & $signTool sign /sha1 $CertificateThumbprint /fd SHA256 `
      /tr $TimestampUrl /td SHA256 $msi.FullName
    if ($LASTEXITCODE -ne 0) { throw "MSI Authenticode signing failed." }
    & $signTool verify /pa /v $msi.FullName
    if ($LASTEXITCODE -ne 0) { throw "MSI signature verification failed." }
  } else {
    Write-Warning "MSI is unsigned. Production distribution requires an Authenticode certificate."
  }

  Get-FileHash -Algorithm SHA256 -LiteralPath $msi.FullName
  Write-Host "MSI: $($msi.FullName)"
} finally {
  Pop-Location
  if ($mappedDrive) {
    & subst.exe $ShortBuildDrive /D
  }
}
