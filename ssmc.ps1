<#
.SYNOPSIS
    AWS SSM Session Manager でサーバーへ接続します。
.DESCRIPTION
    aws login によるログイン確認、MFA 入力、セッションタグ（SSMSessionRunAs）付き AssumeRole、
    サーバーの選択、SSM セッションの開始までを行います。
    引数なしで起動すると、環境とサーバーを対話的に選択します。
.PARAMETER Preset
    設定ファイルに定義したプリセット名。指定すると、その環境・サーバーへ接続します。
.PARAMETER Environment
    接続する環境のキー（例: prod）。-Env でも指定できます。
.PARAMETER Target
    接続先サーバーの Name タグ、またはインスタンス ID。
.PARAMETER LocalPort
    ポートフォワードのローカル待ち受けポート。-RemotePort と一緒に指定します。
.PARAMETER RemotePort
    ポートフォワードの転送先ポート。
.PARAMETER RemoteHost
    ポートフォワードの転送先ホスト。省略すると接続先サーバー自身へ転送します。
.PARAMETER NoCache
    キャッシュ済みの認証情報を使わず、MFA から取り直します。
.PARAMETER ClearCache
    キャッシュ済みの認証情報をすべて削除して終了します。
.PARAMETER Help
    使い方と、定義済みの環境・プリセット一覧を表示します。
.EXAMPLE
    ssmc
    環境とサーバーを対話的に選んで接続します。
.EXAMPLE
    ssmc prod-web01
    プリセット prod-web01 で接続します。
.EXAMPLE
    ssmc -Env prod -Target web01
    本番環境の web01 に接続します。
.EXAMPLE
    ssmc -Env prod -LocalPort 15432 -RemotePort 5432 -RemoteHost mydb.example.internal
    踏み台を選び、localhost:15432 から mydb.example.internal:5432 へのポートフォワードを開始します。
#>
# NOTE: Windows PowerShell 5.1 の文字化け防止のため、このファイルは UTF-8 (BOM 付き) で保存すること。
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Preset,
    [Alias('Env')][string]$Environment,
    [string]$Target,
    [int]$LocalPort,
    [int]$RemotePort,
    [string]$RemoteHost,
    [switch]$NoCache,
    [switch]$ClearCache,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\SsmcCore.psm1') -Force -Verbose:$false
Import-Module (Join-Path $PSScriptRoot 'lib\SsmcMenu.psm1') -Force -Verbose:$false

$sharedConfigPath = Join-Path $PSScriptRoot 'ssmc.shared.json'
$userConfigPath = Get-SsmcUserConfigPath
$cacheDirectory = Get-SsmcCacheDirectory

# PowerShell から直接実行すると --help はプリセット名として渡されるため、ここで判定する
if ($Help -or $Preset -in @('--help', '-h', '/?', 'help')) {
    $config = $null
    try { $config = Get-SsmcConfig -SharedConfigPath $sharedConfigPath -UserConfigPath $userConfigPath } catch { }
    Write-Host (Get-SsmcHelpText -Config $config)
    exit 0
}

try {
    if ($PSBoundParameters.ContainsKey('Verbose')) { Enable-SsmcVerbose }

    if ($ClearCache) {
        Clear-SsmcCredentialCache -CacheDirectory $cacheDirectory
        Write-Host 'キャッシュを削除しました。' -ForegroundColor Green
        exit 0
    }

    $problems = @(Test-SsmcPrerequisite -SharedConfigPath $sharedConfigPath)
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) { Write-Host $problem -ForegroundColor Red }
        Write-Host '処理を終了します。' -ForegroundColor Red
        exit 1
    }
    Add-SsmcPluginToPath

    $config = Get-SsmcConfig -SharedConfigPath $sharedConfigPath -UserConfigPath $userConfigPath

    # 引数の誤りは、プロファイル名や MFA の入力を求める前に知らせる
    $request = Resolve-SsmcRequest -Config $config -Preset $Preset -Environment $Environment -Target $Target `
        -LocalPort $LocalPort -RemotePort $RemotePort -RemoteHost $RemoteHost
    if ($request.Type -eq 'portForward' -and -not (Test-SsmcLocalPortAvailable -Port $request.LocalPort)) {
        throw (New-SsmcException -Message "ローカルポート $($request.LocalPort) は使用中です。別のポートを指定してください。" -ExitCode 3)
    }

    if ([string]::IsNullOrWhiteSpace($config.LoginProfile)) {
        $loginProfile = ([string](Read-Host 'aws login で使用するプロファイル名を入力してください')).Trim()
        if (-not $loginProfile) { throw (New-SsmcException -Message 'プロファイル名が入力されませんでした。' -ExitCode 1) }
        Save-SsmcLoginProfile -UserConfigPath $userConfigPath -LoginProfile $loginProfile
        $config.LoginProfile = $loginProfile
    }

    if (-not $request.EnvKey) {
        $environmentItems = @(foreach ($definition in $config.Environments.Values) {
                [pscustomobject]@{
                    Label      = "$($definition.Key)  $($definition.DisplayName)"
                    SearchText = "$($definition.Key) $($definition.DisplayName)"
                    Dim        = $false
                    Value      = $definition.Key
                }
            })
        $request.EnvKey = Show-SsmcMenu -Title '接続する環境を選択' -Items $environmentItems
        if (-not $request.EnvKey) { exit 0 }
    }
    $selectedEnvironment = $config.Environments[$request.EnvKey]
    Write-Host ">> 環境: $($selectedEnvironment.DisplayName)" -ForegroundColor Green

    $credential = Get-SsmcRoleCredential -LoginProfile $config.LoginProfile -RoleArn $selectedEnvironment.RoleArn `
        -TtlMinutes $config.CredentialTtlMinutes -CacheDirectory $cacheDirectory -NoCache:$NoCache

    Invoke-SsmcWithCredential -Credential $credential -Region $selectedEnvironment.Region -ScriptBlock {
        Write-Host '稼働中のサーバー一覧を取得しています...' -ForegroundColor Yellow
        $instances = @(Get-SsmcInstance -Region $selectedEnvironment.Region)
        if ($instances.Count -eq 0) {
            throw (New-SsmcException -Message '稼働中のインスタンスが見つかりませんでした。' -ExitCode 3)
        }
        $candidates = @(Select-SsmcInstanceByTarget -Instances $instances -TargetName $request.TargetName -TargetInstanceId $request.TargetInstanceId)
        if ($candidates.Count -eq 0) {
            throw (New-SsmcException -Message "接続先 '$($request.TargetName)$($request.TargetInstanceId)' に該当する稼働中のインスタンスがありません。" -ExitCode 3)
        }

        if ($candidates.Count -eq 1 -and ($request.TargetName -or $request.TargetInstanceId)) {
            # 接続先を明示的に指定しているので、1 件に決まれば確認せずに接続する
            $selected = $candidates[0]
        } else {
            $selected = Show-SsmcMenu -Title "[$($selectedEnvironment.DisplayName)] 接続先を選択" -Items @(ConvertTo-SsmcInstanceMenuItem -Instances $candidates)
            if ($null -eq $selected) { return }
        }

        if ($null -ne $selected.PingStatus -and $selected.PingStatus -ne 'Online') {
            if (-not (Read-SsmcConfirmation -Message "SSM の状態が $($selected.PingStatus) です。接続できない可能性があります。続行しますか？")) { return }
        }
        Start-SsmcSession -Instance $selected -Region $selectedEnvironment.Region -Request $request
    }
    exit 0
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit (Get-SsmcExitCode -ErrorRecord $_)
}
