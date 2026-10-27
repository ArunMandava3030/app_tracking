param([Parameter(ValueFromRemainingArguments = $true)][string[]]$FlutterArguments)
$ErrorActionPreference = 'Stop'
$appDirectory = Split-Path -Parent $PSScriptRoot
$portableTools = Join-Path (Split-Path -Parent $appDirectory) 'myorg\.mobile-build\tools'
$portableFlutter = Join-Path $portableTools 'flutter\bin\flutter.bat'
if (Test-Path -LiteralPath $portableFlutter) {
    # The public CA bundle was exported from the existing Windows trust store.
    # PKCS12 works in both the build JDK and Android CLI's bundled JVM.
    $buildTrustStore = Join-Path $portableTools 'system-ca.p12'
    $env:JAVA_TOOL_OPTIONS = "$env:JAVA_TOOL_OPTIONS -Djavax.net.ssl.trustStoreType=PKCS12 `"-Djavax.net.ssl.trustStore=$buildTrustStore`" -Djavax.net.ssl.trustStorePassword=changeit".Trim()
    $jdkDirectory = Get-ChildItem -LiteralPath (Join-Path $portableTools 'java') -Directory | Where-Object { $_.Name -like 'jdk*' } | Select-Object -First 1
    $env:JAVA_HOME = $jdkDirectory.FullName
    $env:ANDROID_HOME = Join-Path $portableTools 'android'
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    $env:PUB_CACHE = Join-Path $portableTools 'pub-cache'
    $env:GRADLE_USER_HOME = Join-Path $portableTools 'gradle-cache'
    $env:SSL_CERT_FILE = Join-Path $portableTools 'system-ca.pem'
    $env:PATH = "$(Join-Path $portableTools 'git\cmd');$(Join-Path $portableTools 'flutter\bin');$(Join-Path $env:JAVA_HOME 'bin');$env:PATH"
    Push-Location -LiteralPath $appDirectory
    try { & $portableFlutter @FlutterArguments } finally { Pop-Location }
} else {
    Push-Location -LiteralPath $appDirectory
    try { & flutter @FlutterArguments } finally { Pop-Location }
}
exit $LASTEXITCODE
