# NOTE: Windows PowerShell 5.1 の文字化け防止のため、このファイルは UTF-8 (BOM 付き) で保存すること。

#region Common
$script:VerboseEnabled = $false
$script:MinAwsCliVersion = [version]'2.32.0'
$script:CacheMarginMinutes = 5

function New-SsmcException {
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][int]$ExitCode
    )
    $exception = [System.Exception]::new($Message)
    $exception.Data['SsmcExitCode'] = $ExitCode
    return $exception
}

function Get-SsmcExitCode {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $code = $ErrorRecord.Exception.Data['SsmcExitCode']
    if ($null -eq $code) { return 1 }
    return [int]$code
}

function Enable-SsmcVerbose {
    $script:VerboseEnabled = $true
}

function Write-SsmcVerbose {
    param([string]$Message)
    if ($script:VerboseEnabled) { Write-Host "[verbose] $Message" -ForegroundColor DarkGray }
}
#endregion

#region AwsCli
function ConvertTo-SsmcArgumentString {
    param([string[]]$Arguments)
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -eq '') {
            '""'
        } elseif ($argument -notmatch '[\s"]') {
            $argument
        } else {
            # Windows のコマンドライン規則: 引用符の直前のバックスラッシュを二重にし、引用符をエスケープする
            $escaped = [regex]::Replace($argument, '(\\*)"', '$1$1\"')
            $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
            '"' + $escaped + '"'
        }
    }
    return ($quoted -join ' ')
}

function Format-SsmcAwsCommandLine {
    param([string[]]$Arguments)
    return 'aws ' + ($Arguments -join ' ')
}

function Get-SsmcAwsPath {
    $command = Get-Command aws -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { return $null }
    return $command.Path
}

function New-SsmcAwsStartInfo {
    param([string[]]$Arguments)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-SsmcAwsPath
    $startInfo.Arguments = ConvertTo-SsmcArgumentString $Arguments
    $startInfo.UseShellExecute = $false
    return $startInfo
}

function Invoke-Aws {
    param([Parameter(Mandatory)][string[]]$Arguments)
    Write-SsmcVerbose (Format-SsmcAwsCommandLine $Arguments)
    $startInfo = New-SsmcAwsStartInfo $Arguments
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    # 未指定だと aws CLI は cp932 で出力し、日本語（Name タグ等）が文字化けする
    $startInfo.EnvironmentVariables['PYTHONUTF8'] = '1'
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdoutTask.Result
        StdErr   = $stderrTask.Result
    }
}

function Invoke-AwsInteractive {
    param([Parameter(Mandatory)][string[]]$Arguments)
    Write-SsmcVerbose (Format-SsmcAwsCommandLine $Arguments)
    # 出力をリダイレクトせずコンソールを引き継ぐ（start-session / login は対話操作が必要）
    $process = [System.Diagnostics.Process]::Start((New-SsmcAwsStartInfo $Arguments))
    $process.WaitForExit()
    return $process.ExitCode
}

function Get-SsmcAwsErrorKind {
    param([string]$StdErr)
    if ($StdErr -match 'MultiFactorAuthentication failed|invalid MFA') { return 'InvalidMfa' }
    if ($StdErr -match 'could not be found|Unable to locate credentials|ExpiredToken|expired|aws login|reauthenticate') { return 'LoginRequired' }
    if ($StdErr -match 'AccessDenied|UnauthorizedOperation|not authorized') { return 'AccessDenied' }
    return 'Other'
}

function ConvertFrom-SsmcAwsJson {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    return ($Text | ConvertFrom-Json)
}

function ConvertTo-SsmcDateTimeOffset {
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [DateTimeOffset]) { return $Value }
    # PowerShell 7 の ConvertFrom-Json は日時文字列を DateTime に自動変換するため、両方を受け付ける
    if ($Value -is [datetime]) { return [DateTimeOffset]$Value }
    return [DateTimeOffset]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture)
}
#endregion

#region Prereq
function Get-SsmcAwsCliVersion {
    $result = Invoke-Aws -Arguments @('--version')
    if ($result.ExitCode -ne 0) { return $null }
    if ("$($result.StdOut) $($result.StdErr)" -match 'aws-cli/(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    return $null
}

function Find-SsmcSessionManagerPlugin {
    $command = Get-Command session-manager-plugin -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Path }
    $defaultPath = Join-Path $env:ProgramFiles 'Amazon\SessionManagerPlugin\bin\session-manager-plugin.exe'
    if (Test-Path -LiteralPath $defaultPath) { return $defaultPath }
    return $null
}

function Test-SsmcPrerequisite {
    param([Parameter(Mandatory)][string]$SharedConfigPath)
    $installUrl = 'https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html'
    if (-not (Get-SsmcAwsPath)) {
        "AWS CLI v2 が見つかりません。インストールしてください: $installUrl"
    } else {
        $version = Get-SsmcAwsCliVersion
        if ($null -eq $version -or $version -lt $script:MinAwsCliVersion) {
            "AWS CLI $($script:MinAwsCliVersion) 以上が必要です（aws login に対応するため）。更新してください: $installUrl"
        }
    }
    if (-not (Find-SsmcSessionManagerPlugin)) {
        'Session Manager Plugin が見つかりません。インストールしてください: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html'
    }
    if (-not (Test-Path -LiteralPath $SharedConfigPath)) {
        "共通設定ファイルが見つかりません: $SharedConfigPath"
    }
}

function Add-SsmcPluginToPath {
    # aws CLI は PATH から session-manager-plugin を探すため、既定のインストール先にしかない場合に備えて追加する
    $plugin = Find-SsmcSessionManagerPlugin
    if ($null -eq $plugin) { return }
    $directory = Split-Path -Parent $plugin
    if (($env:PATH -split ';') -notcontains $directory) { $env:PATH = "$env:PATH;$directory" }
}
#endregion

#region Config
function Get-SsmcSharedConfigPath {
    # 実機確認用の ssmc.shared.test.json があれば、配布用の ssmc.shared.json より優先する
    param([Parameter(Mandatory)][string]$Directory)
    $testPath = Join-Path $Directory 'ssmc.shared.test.json'
    if (Test-Path -LiteralPath $testPath) { return $testPath }
    return (Join-Path $Directory 'ssmc.shared.json')
}

function Get-SsmcUserConfigPath {
    return (Join-Path $env:APPDATA 'ssmc\ssmc.user.json')
}

function Get-SsmcCacheDirectory {
    return (Join-Path $env:LOCALAPPDATA 'ssmc\cache')
}

function Test-SsmcInteger {
    param($Value)
    # PowerShell 5.1 は Int32、7 は Int64 で JSON の数値を返すことがある
    return ($Value -is [int] -or $Value -is [long])
}

function Test-SsmcPort {
    param($Value)
    return ((Test-SsmcInteger $Value) -and $Value -ge 1 -and $Value -le 65535)
}

function ConvertTo-SsmcHashtable {
    param($InputObject)
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $table = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-SsmcHashtable $property.Value
        }
        return $table
    }
    return $InputObject
}

function Read-SsmcJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        return (ConvertTo-SsmcHashtable ($text | ConvertFrom-Json))
    } catch {
        throw (New-SsmcException -Message "設定ファイルを読み込めません: $Path ($($_.Exception.Message))" -ExitCode 1)
    }
}

function Join-SsmcTable {
    param($Base, $Override)
    $result = [ordered]@{}
    foreach ($table in @($Base, $Override)) {
        if ($null -eq $table) { continue }
        foreach ($key in $table.Keys) { $result[$key] = $table[$key] }
    }
    return $result
}

function New-SsmcRequest {
    return [pscustomobject]@{
        EnvKey           = $null
        TargetName       = $null
        TargetInstanceId = $null
        Type             = 'shell'
        RemoteHost       = $null
        RemotePort       = $null
        LocalPort        = $null
    }
}

function ConvertTo-SsmcPreset {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Raw,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Environments
    )
    $prefix = "プリセット '$Name'"
    if (-not $Environments.Contains([string]$Raw['env'])) {
        throw (New-SsmcException -Message "$prefix の env '$($Raw['env'])' は environments に存在しません。" -ExitCode 1)
    }
    $targetName = $null
    $targetInstanceId = $null
    if ($Raw['target'] -is [System.Collections.IDictionary]) {
        $targetName = $Raw['target']['name']
        $targetInstanceId = $Raw['target']['instanceId']
    }
    if ([string]::IsNullOrWhiteSpace($targetName) -eq [string]::IsNullOrWhiteSpace($targetInstanceId)) {
        throw (New-SsmcException -Message "$prefix は target.name と target.instanceId のどちらか一方を指定してください。" -ExitCode 1)
    }
    $type = 'shell'
    if ($Raw['type']) { $type = [string]$Raw['type'] }
    if ($type -cnotin @('shell', 'portForward')) {
        throw (New-SsmcException -Message "$prefix の type は shell または portForward を指定してください。" -ExitCode 1)
    }
    $request = New-SsmcRequest
    $request.EnvKey = [string]$Raw['env']
    $request.TargetName = $targetName
    $request.TargetInstanceId = $targetInstanceId
    $request.Type = $type
    if ($type -eq 'portForward') {
        foreach ($field in @('remotePort', 'localPort')) {
            if (-not (Test-SsmcPort $Raw[$field])) {
                throw (New-SsmcException -Message "$prefix の $field は 1〜65535 の整数で指定してください。" -ExitCode 1)
            }
        }
        $request.RemoteHost = $Raw['remoteHost']
        $request.RemotePort = [int]$Raw['remotePort']
        $request.LocalPort = [int]$Raw['localPort']
    }
    return $request
}

function Merge-SsmcConfig {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Shared,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$User
    )
    if ($Shared['version'] -ne 1) {
        throw (New-SsmcException -Message '共通設定の version は 1 を指定してください。' -ExitCode 1)
    }
    $defaults = $Shared['defaults']
    if ($defaults -isnot [System.Collections.IDictionary] -or [string]::IsNullOrWhiteSpace($defaults['region'])) {
        throw (New-SsmcException -Message '共通設定に defaults.region がありません。' -ExitCode 1)
    }
    $ttl = $defaults['credentialTtlMinutes']
    if ($null -ne $User['credentialTtlMinutes']) { $ttl = $User['credentialTtlMinutes'] }
    if (-not (Test-SsmcInteger $ttl) -or $ttl -lt 15) {
        throw (New-SsmcException -Message 'credentialTtlMinutes は 15 以上の整数で指定してください。' -ExitCode 1)
    }

    $rawEnvironments = Join-SsmcTable $Shared['environments'] $User['environments']
    if ($rawEnvironments.Count -eq 0) {
        throw (New-SsmcException -Message '共通設定に environments がありません。' -ExitCode 1)
    }
    $environments = [ordered]@{}
    foreach ($key in $rawEnvironments.Keys) {
        $item = $rawEnvironments[$key]
        if ([string]::IsNullOrWhiteSpace($item['displayName'])) {
            throw (New-SsmcException -Message "環境 '$key' に displayName がありません。" -ExitCode 1)
        }
        if ($item['roleArn'] -notmatch '^arn:aws:iam::\d{12}:role/.+') {
            throw (New-SsmcException -Message "環境 '$key' の roleArn が不正です: $($item['roleArn'])" -ExitCode 1)
        }
        $region = $defaults['region']
        if (-not [string]::IsNullOrWhiteSpace($item['region'])) { $region = $item['region'] }
        $environments[$key] = [pscustomobject]@{
            Key         = [string]$key
            DisplayName = $item['displayName']
            RoleArn     = $item['roleArn']
            Region      = $region
        }
    }

    $presets = [ordered]@{}
    $rawPresets = Join-SsmcTable $Shared['presets'] $User['presets']
    foreach ($name in $rawPresets.Keys) {
        $presets[$name] = ConvertTo-SsmcPreset -Name $name -Raw $rawPresets[$name] -Environments $environments
    }

    return [pscustomobject]@{
        CredentialTtlMinutes = [int]$ttl
        LoginProfile         = $User['loginProfile']
        Environments         = $environments
        Presets              = $presets
    }
}

function Get-SsmcConfig {
    param(
        [Parameter(Mandatory)][string]$SharedConfigPath,
        [Parameter(Mandatory)][string]$UserConfigPath
    )
    $shared = Read-SsmcJsonFile -Path $SharedConfigPath
    if ($null -eq $shared) { $shared = [ordered]@{} }
    $user = [ordered]@{}
    if (Test-Path -LiteralPath $UserConfigPath) {
        $loaded = Read-SsmcJsonFile -Path $UserConfigPath
        if ($null -ne $loaded) { $user = $loaded }
    }
    return (Merge-SsmcConfig -Shared $shared -User $user)
}

function Save-SsmcLoginProfile {
    param(
        [Parameter(Mandatory)][string]$UserConfigPath,
        [Parameter(Mandatory)][string]$LoginProfile
    )
    $data = [ordered]@{}
    if (Test-Path -LiteralPath $UserConfigPath) {
        $loaded = Read-SsmcJsonFile -Path $UserConfigPath
        if ($null -ne $loaded) { $data = $loaded }
    }
    $data['loginProfile'] = $LoginProfile
    $directory = Split-Path -Parent $UserConfigPath
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($UserConfigPath, ($data | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
}

function Resolve-SsmcRequest {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Preset,
        [string]$Environment,
        [string]$Target,
        [int]$LocalPort,
        [int]$RemotePort,
        [string]$RemoteHost
    )
    if ($Preset) {
        if (-not $Config.Presets.Contains($Preset)) {
            throw (New-SsmcException -Message "プリセット '$Preset' が見つかりません。ssmc --help で一覧を確認してください。" -ExitCode 1)
        }
        $request = $Config.Presets[$Preset].PSObject.Copy()
    } else {
        $request = New-SsmcRequest
    }
    if ($Environment) {
        if (-not $Config.Environments.Contains($Environment)) {
            throw (New-SsmcException -Message "環境 '$Environment' が見つかりません。ssmc --help で一覧を確認してください。" -ExitCode 1)
        }
        $request.EnvKey = $Environment
    }
    if ($Target) {
        if ($Target -match '^i-[0-9a-f]{8,17}$') {
            $request.TargetInstanceId = $Target
            $request.TargetName = $null
        } else {
            $request.TargetName = $Target
            $request.TargetInstanceId = $null
        }
    }
    if ($LocalPort -or $RemotePort) {
        if (-not (Test-SsmcPort $LocalPort) -or -not (Test-SsmcPort $RemotePort)) {
            throw (New-SsmcException -Message '-LocalPort と -RemotePort は両方を 1〜65535 で指定してください。' -ExitCode 1)
        }
        $request.Type = 'portForward'
        $request.LocalPort = $LocalPort
        $request.RemotePort = $RemotePort
        $request.RemoteHost = $null
        if ($RemoteHost) { $request.RemoteHost = $RemoteHost }
    } elseif ($RemoteHost) {
        throw (New-SsmcException -Message '-RemoteHost を使うときは -LocalPort と -RemotePort も指定してください。' -ExitCode 1)
    }
    return $request
}
#endregion

#region CredCache
function Get-SsmcCachePath {
    param(
        [Parameter(Mandatory)][string]$RoleArn,
        [Parameter(Mandatory)][string]$CacheDirectory
    )
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($RoleArn))
    } finally {
        $sha256.Dispose()
    }
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return (Join-Path $CacheDirectory ($hex.Substring(0, 16) + '.dat'))
}

function Test-SsmcCredentialUsable {
    param(
        [Parameter(Mandatory)]$Credential,
        [Parameter(Mandatory)][string]$RoleArn,
        [Parameter(Mandatory)][DateTimeOffset]$Now
    )
    if ($Credential.RoleArn -ne $RoleArn) { return $false }
    return (($Credential.Expiration - $Now).TotalMinutes -ge $script:CacheMarginMinutes)
}

function Save-SsmcCredential {
    param(
        [Parameter(Mandatory)]$Credential,
        [Parameter(Mandatory)][string]$CacheDirectory
    )
    if (-not (Test-Path -LiteralPath $CacheDirectory)) { New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null }
    $json = [ordered]@{
        AccessKeyId     = $Credential.AccessKeyId
        SecretAccessKey = $Credential.SecretAccessKey
        SessionToken    = $Credential.SessionToken
        Expiration      = $Credential.Expiration.ToUniversalTime().ToString('o')
        RoleArn         = $Credential.RoleArn
        UserName        = $Credential.UserName
    } | ConvertTo-Json -Compress
    # キーを指定しない ConvertFrom-SecureString は DPAPI（CurrentUser）で暗号化する
    $encrypted = ConvertTo-SecureString -String $json -AsPlainText -Force | ConvertFrom-SecureString
    [System.IO.File]::WriteAllText((Get-SsmcCachePath -RoleArn $Credential.RoleArn -CacheDirectory $CacheDirectory), $encrypted)
}

function Read-SsmcCredential {
    param(
        [Parameter(Mandatory)][string]$RoleArn,
        [Parameter(Mandatory)][string]$CacheDirectory,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    $path = Get-SsmcCachePath -RoleArn $RoleArn -CacheDirectory $CacheDirectory
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $credential = $null
    try {
        $secure = ConvertTo-SecureString -String ([System.IO.File]::ReadAllText($path).Trim())
        $data = [System.Net.NetworkCredential]::new('', $secure).Password | ConvertFrom-Json
        $credential = [pscustomobject]@{
            AccessKeyId     = $data.AccessKeyId
            SecretAccessKey = $data.SecretAccessKey
            SessionToken    = $data.SessionToken
            Expiration      = (ConvertTo-SsmcDateTimeOffset $data.Expiration)
            RoleArn         = $data.RoleArn
            UserName        = $data.UserName
        }
    } catch {
        Write-SsmcVerbose "キャッシュを読み込めませんでした: $($_.Exception.Message)"
    }
    if ($null -ne $credential -and (Test-SsmcCredentialUsable -Credential $credential -RoleArn $RoleArn -Now $Now)) {
        return $credential
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    return $null
}

function Clear-SsmcCredentialCache {
    param([Parameter(Mandatory)][string]$CacheDirectory)
    if (-not (Test-Path -LiteralPath $CacheDirectory)) { return }
    Get-ChildItem -LiteralPath $CacheDirectory -Filter '*.dat' | Remove-Item -Force
}
#endregion

#region Auth
function Get-SsmcCallerIdentity {
    param([Parameter(Mandatory)][string]$LoginProfile)
    $result = Invoke-Aws -Arguments @('sts', 'get-caller-identity', '--profile', $LoginProfile, '--output', 'json')
    if ($result.ExitCode -ne 0) {
        Write-SsmcVerbose $result.StdErr
        return $null
    }
    $data = ConvertFrom-SsmcAwsJson $result.StdOut
    return [pscustomobject]@{
        Account  = $data.Account
        Arn      = $data.Arn
        UserName = ($data.Arn -split '/')[-1]
    }
}

function Get-SsmcMfaSerial {
    param(
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][string]$UserName
    )
    # MFA デバイス名は IAM ユーザー名と同一という運用ルールに基づく
    return "arn:aws:iam::${Account}:mfa/$UserName"
}

function Connect-SsmcLoginProfile {
    param([Parameter(Mandatory)][string]$LoginProfile)
    $identity = Get-SsmcCallerIdentity -LoginProfile $LoginProfile
    if ($null -ne $identity) { return $identity }
    Write-Host "プロファイル '$LoginProfile' のログインを確認できません。ブラウザでログインします..." -ForegroundColor Yellow
    $null = Invoke-AwsInteractive -Arguments @('login', '--profile', $LoginProfile)
    $identity = Get-SsmcCallerIdentity -LoginProfile $LoginProfile
    if ($null -eq $identity) {
        throw (New-SsmcException -Message "ログインに失敗しました（プロファイル: $LoginProfile）。" -ExitCode 2)
    }
    return $identity
}

function Read-SsmcMfaCode {
    while ($true) {
        # 30 秒で無効になる値なので、入力内容は伏せない
        $code = ([string](Read-Host -Prompt 'MFAコード（6桁）')).Trim()
        if ($code -match '^\d{6}$') { return $code }
        Write-Host '6桁の数字で入力してください。' -ForegroundColor Yellow
    }
}

function Invoke-SsmcAssumeRole {
    param(
        [Parameter(Mandatory)][string]$LoginProfile,
        [Parameter(Mandatory)][string]$RoleArn,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][int]$TtlMinutes,
        [Parameter(Mandatory)][string]$MfaCode
    )
    $serial = Get-SsmcMfaSerial -Account $Identity.Account -UserName $Identity.UserName
    return (Invoke-Aws -Arguments @(
            'sts', 'assume-role',
            '--profile', $LoginProfile,
            '--role-arn', $RoleArn,
            '--role-session-name', $Identity.UserName,
            '--serial-number', $serial,
            '--token-code', $MfaCode,
            '--duration-seconds', [string]($TtlMinutes * 60),
            '--tags', "Key=SSMSessionRunAs,Value=$($Identity.UserName)",
            '--output', 'json'))
}

function ConvertFrom-SsmcAssumeRoleOutput {
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][string]$RoleArn,
        [Parameter(Mandatory)][string]$UserName
    )
    $credentials = (ConvertFrom-SsmcAwsJson $Json).Credentials
    return [pscustomobject]@{
        AccessKeyId     = $credentials.AccessKeyId
        SecretAccessKey = $credentials.SecretAccessKey
        SessionToken    = $credentials.SessionToken
        Expiration      = (ConvertTo-SsmcDateTimeOffset $credentials.Expiration)
        RoleArn         = $RoleArn
        UserName        = $UserName
    }
}

function Get-SsmcRoleCredential {
    param(
        [Parameter(Mandatory)][string]$LoginProfile,
        [Parameter(Mandatory)][string]$RoleArn,
        [Parameter(Mandatory)][int]$TtlMinutes,
        [Parameter(Mandatory)][string]$CacheDirectory,
        [switch]$NoCache
    )
    if (-not $NoCache) {
        $cached = Read-SsmcCredential -RoleArn $RoleArn -CacheDirectory $CacheDirectory
        if ($null -ne $cached) {
            Write-Host "キャッシュ済みの認証情報を使用します（有効期限: $($cached.Expiration.ToLocalTime().ToString('HH:mm'))）" -ForegroundColor DarkGray
            return $cached
        }
    }
    $identity = Connect-SsmcLoginProfile -LoginProfile $LoginProfile
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $code = Read-SsmcMfaCode
        $result = Invoke-SsmcAssumeRole -LoginProfile $LoginProfile -RoleArn $RoleArn -Identity $identity -TtlMinutes $TtlMinutes -MfaCode $code
        if ($result.ExitCode -eq 0) {
            $credential = ConvertFrom-SsmcAssumeRoleOutput -Json $result.StdOut -RoleArn $RoleArn -UserName $identity.UserName
            Save-SsmcCredential -Credential $credential -CacheDirectory $CacheDirectory
            return $credential
        }
        $kind = Get-SsmcAwsErrorKind $result.StdErr
        if ($kind -eq 'InvalidMfa' -and $attempt -lt $maxAttempts) {
            Write-Host 'MFAコードが正しくないか、期限切れです。もう一度入力してください。' -ForegroundColor Yellow
            continue
        }
        if ($kind -eq 'InvalidMfa') {
            throw (New-SsmcException -Message "MFAコードの認証に $maxAttempts 回失敗しました。" -ExitCode 2)
        }
        if ($result.StdErr -match 'DurationSeconds') {
            throw (New-SsmcException -Message "credentialTtlMinutes（$TtlMinutes 分）がロールの最大セッション時間を超えています。設定を見直してください。" -ExitCode 2)
        }
        throw (New-SsmcException -Message "ロールへのスイッチに失敗しました: $($result.StdErr.Trim())" -ExitCode 2)
    }
}

function Set-SsmcProcessEnvironment {
    param([Parameter(Mandatory)][string]$Name, [AllowNull()][string]$Value)
    # [Environment]::SetEnvironmentVariable に $null を渡すと PowerShell が空文字に変換し、
    # PowerShell 7 (.NET) では空文字の変数が残る。aws CLI は AWS_PROFILE= を「プロファイル ''」と解釈して失敗する
    if ([string]::IsNullOrEmpty($Value)) {
        Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
    } else {
        Set-Item -LiteralPath "Env:$Name" -Value $Value
    }
}

function Invoke-SsmcWithCredential {
    param(
        [Parameter(Mandatory)]$Credential,
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    $names = @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_REGION', 'AWS_PROFILE', 'AWS_DEFAULT_PROFILE')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        Set-SsmcProcessEnvironment -Name 'AWS_ACCESS_KEY_ID' -Value $Credential.AccessKeyId
        Set-SsmcProcessEnvironment -Name 'AWS_SECRET_ACCESS_KEY' -Value $Credential.SecretAccessKey
        Set-SsmcProcessEnvironment -Name 'AWS_SESSION_TOKEN' -Value $Credential.SessionToken
        Set-SsmcProcessEnvironment -Name 'AWS_REGION' -Value $Region
        # プロファイル指定が残っていると、そちらの認証情報が使われるおそれがあるため外す
        Set-SsmcProcessEnvironment -Name 'AWS_PROFILE' -Value $null
        Set-SsmcProcessEnvironment -Name 'AWS_DEFAULT_PROFILE' -Value $null
        & $ScriptBlock
    } finally {
        foreach ($name in $names) { Set-SsmcProcessEnvironment -Name $name -Value $saved[$name] }
    }
}
#endregion

#region Inventory
function Get-SsmcInstance {
    param([Parameter(Mandatory)][string]$Region)
    $ec2 = Invoke-Aws -Arguments @('ec2', 'describe-instances', '--region', $Region, '--filters', 'Name=instance-state-name,Values=running', '--output', 'json')
    if ($ec2.ExitCode -ne 0) {
        throw (New-SsmcException -Message "EC2 インスタンス一覧の取得に失敗しました: $($ec2.StdErr.Trim())" -ExitCode 3)
    }
    $instances = @(foreach ($reservation in @((ConvertFrom-SsmcAwsJson $ec2.StdOut).Reservations)) {
            foreach ($instance in @($reservation.Instances)) {
                # Tags を 1 つも持たないインスタンスは、JSON に Tags 自体が含まれない
                $tags = @()
                if ($instance.PSObject.Properties['Tags']) { $tags = @($instance.Tags) }
                $nameTag = $tags | Where-Object { $_.Key -eq 'Name' } | Select-Object -First 1
                $name = $null
                if ($null -ne $nameTag) { $name = $nameTag.Value }
                [pscustomobject]@{ Name = $name; InstanceId = $instance.InstanceId; PrivateIp = $instance.PrivateIpAddress; PingStatus = $null }
            }
        })

    $ssm = Invoke-Aws -Arguments @('ssm', 'describe-instance-information', '--region', $Region, '--output', 'json')
    $statusMap = $null
    if ($ssm.ExitCode -eq 0) {
        $statusMap = @{}
        foreach ($information in @((ConvertFrom-SsmcAwsJson $ssm.StdOut).InstanceInformationList)) {
            $statusMap[$information.InstanceId] = $information.PingStatus
        }
    } elseif ((Get-SsmcAwsErrorKind $ssm.StdErr) -eq 'AccessDenied') {
        Write-SsmcVerbose "SSM の状態を取得する権限がないため、状態の表示を省略します: $($ssm.StdErr.Trim())"
    } else {
        throw (New-SsmcException -Message "SSM 管理情報の取得に失敗しました: $($ssm.StdErr.Trim())" -ExitCode 3)
    }
    Merge-SsmcInstanceStatus -Instances $instances -StatusMap $statusMap
}

function Merge-SsmcInstanceStatus {
    param(
        [AllowEmptyCollection()][object[]]$Instances = @(),
        [hashtable]$StatusMap
    )
    $merged = @(foreach ($instance in $Instances) {
            $status = $null
            if ($null -ne $StatusMap) {
                $status = '未登録'
                if ($StatusMap.ContainsKey($instance.InstanceId)) { $status = $StatusMap[$instance.InstanceId] }
            }
            [pscustomobject]@{ Name = $instance.Name; InstanceId = $instance.InstanceId; PrivateIp = $instance.PrivateIp; PingStatus = $status }
        })
    $merged | Where-Object { $_.Name } | Sort-Object Name, InstanceId
    $merged | Where-Object { -not $_.Name } | Sort-Object InstanceId
}

function Select-SsmcInstanceByTarget {
    param(
        [AllowEmptyCollection()][object[]]$Instances = @(),
        [string]$TargetName,
        [string]$TargetInstanceId
    )
    if ($TargetInstanceId) { return ($Instances | Where-Object { $_.InstanceId -eq $TargetInstanceId }) }
    if ($TargetName) { return ($Instances | Where-Object { $_.Name -eq $TargetName }) }
    return $Instances
}

function Get-SsmcInstanceDisplayName {
    param([Parameter(Mandatory)]$Instance)
    if ($Instance.Name) { return $Instance.Name }
    return '<Nameタグなし>'
}

function ConvertTo-SsmcInstanceMenuItem {
    param([Parameter(Mandatory)][object[]]$Instances)
    $nameWidth = ($Instances | ForEach-Object { (Get-SsmcInstanceDisplayName $_).Length } | Measure-Object -Maximum).Maximum
    foreach ($instance in $Instances) {
        $name = Get-SsmcInstanceDisplayName $instance
        $label = '{0}  {1}  {2}' -f $name.PadRight($nameWidth), $instance.InstanceId.PadRight(19), ([string]$instance.PrivateIp).PadRight(15)
        if ($null -ne $instance.PingStatus) { $label += '  ' + $instance.PingStatus }
        [pscustomobject]@{
            Label      = $label.TrimEnd()
            SearchText = "$name $($instance.InstanceId) $($instance.PrivateIp)"
            Dim        = ($null -ne $instance.PingStatus -and $instance.PingStatus -ne 'Online')
            Value      = $instance
        }
    }
}
#endregion

#region Session
function Get-SsmcSessionArgument {
    param(
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)]$Request
    )
    $arguments = @('ssm', 'start-session', '--target', $InstanceId, '--region', $Region)
    if ($Request.Type -ne 'portForward') { return $arguments }
    # PowerShell 5.1 はネイティブコマンドへ渡す引数の " を正しく扱えないため、JSON ではなく shorthand 構文で渡す
    if ($Request.RemoteHost) {
        return $arguments + @('--document-name', 'AWS-StartPortForwardingSessionToRemoteHost',
            '--parameters', "host=$($Request.RemoteHost),portNumber=$($Request.RemotePort),localPortNumber=$($Request.LocalPort)")
    }
    return $arguments + @('--document-name', 'AWS-StartPortForwardingSession',
        '--parameters', "portNumber=$($Request.RemotePort),localPortNumber=$($Request.LocalPort)")
}

function Test-SsmcLocalPortAvailable {
    param([Parameter(Mandatory)][int]$Port)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        $listener.Stop()
    }
}

function Start-SsmcSession {
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)]$Request
    )
    $name = Get-SsmcInstanceDisplayName $Instance
    if ($Request.Type -eq 'portForward') {
        $destination = "${name}:$($Request.RemotePort)"
        if ($Request.RemoteHost) { $destination = "$($Request.RemoteHost):$($Request.RemotePort)" }
        Write-Host ''
        Write-Host "ポートフォワードを開始します: localhost:$($Request.LocalPort) -> $destination（経由: $name / $($Instance.InstanceId)）" -ForegroundColor Green
        Write-Host "  接続は別のアプリ（リモートデスクトップ、ブラウザ、DB クライアント等）から localhost:$($Request.LocalPort) に対して行ってください。"
        Write-Host '  このウィンドウを閉じるか Ctrl+C を押すと、トンネルが切断されます。'
        # Ctrl+C は cmd にも届くため、ssmc.bat 経由では cmd の確認が表示される（.bat 側では抑止できない）
        Write-Host '  ssmc.bat から起動した場合、Ctrl+C の後に「バッチ ジョブを終了しますか (Y/N)?」(Terminate batch job) と表示されたら Y を押してください。'
    } else {
        Write-Host ''
        Write-Host ">> $name ($($Instance.InstanceId)) に接続します..." -ForegroundColor Green
    }
    $exitCode = Invoke-AwsInteractive -Arguments (Get-SsmcSessionArgument -InstanceId $Instance.InstanceId -Region $Region -Request $Request)
    if ($exitCode -ne 0) {
        throw (New-SsmcException -Message "セッションの開始に失敗しました（終了コード: $exitCode）。" -ExitCode 3)
    }
}
#endregion

#region Help
function Format-SsmcPresetSummary {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Preset
    )
    $target = $Preset.TargetName
    if (-not $target) { $target = $Preset.TargetInstanceId }
    $summary = "$($Config.Environments[$Preset.EnvKey].DisplayName) / $target / $($Preset.Type)"
    if ($Preset.Type -eq 'portForward') {
        $remote = $target
        if ($Preset.RemoteHost) { $remote = $Preset.RemoteHost }
        $summary += " $($Preset.LocalPort) -> ${remote}:$($Preset.RemotePort)"
    }
    return $summary
}

function Get-SsmcHelpText {
    param($Config)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('使い方: ssmc [プリセット名] [-Env <環境>] [-Target <Name|InstanceId>]')
    $lines.Add('            [-LocalPort <n> -RemotePort <n> [-RemoteHost <host>]]')
    $lines.Add('            [-NoCache] [-ClearCache] [-Verbose] [-Help]')
    $lines.Add('')
    $lines.Add('例:')
    $lines.Add('  ssmc                          対話モードで環境とサーバーを選んで接続')
    $lines.Add('  ssmc prod-web01               プリセットで接続')
    $lines.Add('  ssmc -Env prod -Target web01  環境と接続先を指定して接続')
    $lines.Add('  ssmc -Env prod -LocalPort 15432 -RemotePort 5432 -RemoteHost mydb.example.internal')
    $lines.Add('                                踏み台を選んでポートフォワードを開始')
    $lines.Add('  ssmc -NoCache                 キャッシュを使わず MFA から取り直す')
    $lines.Add('  ssmc -ClearCache              キャッシュを削除')
    $lines.Add('')
    $lines.Add('詳細: Get-Help <ssmc.ps1 のパス> -Detailed')
    if ($null -ne $Config) {
        $lines.Add('')
        $lines.Add('環境:')
        foreach ($environment in $Config.Environments.Values) {
            $lines.Add(('  {0,-14} {1}' -f $environment.Key, $environment.DisplayName))
        }
        $lines.Add('')
        $lines.Add('プリセット:')
        if ($Config.Presets.Count -eq 0) { $lines.Add('  （なし）') }
        foreach ($name in $Config.Presets.Keys) {
            $lines.Add(('  {0,-14} {1}' -f $name, (Format-SsmcPresetSummary -Config $Config -Preset $Config.Presets[$name])))
        }
    }
    return ($lines -join [Environment]::NewLine)
}
#endregion
