# SSM Connector 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `aws login` → MFA → `SSMSessionRunAs` タグ付き AssumeRole → サーバー選択 → SSM セッション開始を自動化する PowerShell 製 CLI（`ssmc`）を作る。

**Architecture:** AWS CLI v2 をラップする。入口 `ssmc.ps1` が流れを制御し、AWS とのやり取りは `lib/SsmcCore.psm1`（region で 7 区分）、矢印キーの選択 UI は `lib/SsmcMenu.psm1` に分ける。AWS 呼び出しはすべて `Invoke-Aws` / `Invoke-AwsInteractive` を通し、テストではこれをモックする。

**Tech Stack:** Windows PowerShell 5.1 / PowerShell 7、AWS CLI v2（2.32.0 以上）、Session Manager Plugin、Pester 5.5 以上

**設計書:** [ssm-connector-design.md](ssm-connector-design.md)

## Global Constraints

- Windows PowerShell 5.1 と PowerShell 7 の両方で動作すること。三項演算子、`??`、`?.`、`ConvertFrom-Json -AsHashtable`、`ProcessStartInfo.ArgumentList` は使わない。
- `.ps1` / `.psm1` はすべて **UTF-8 (BOM 付き)** で保存する。ファイルを作成・編集したら、次のコマンドで BOM を付ける（BOM が付いていれば何も変わらない）。`tests/Encoding.Tests.ps1` が BOM の有無を検査する。
  ```powershell
  $p = '<ファイルのフルパス>'; [IO.File]::WriteAllText($p, [IO.File]::ReadAllText($p), [Text.UTF8Encoding]::new($true))
  ```
- セッションタグは `Key=SSMSessionRunAs,Value=<IAMユーザー名>` に固定する。MFA シリアルは `arn:aws:iam::<Account>:mfa/<UserName>`、ロールセッション名は `<UserName>`。
- AWS CLI の最低バージョンは `2.32.0`（`aws login` に対応するため）。
- `credentialTtlMinutes` は全体で 1 つの値（既定 60、15 以上）。AssumeRole の `--duration-seconds` に `TTL × 60` を指定する。
- キャッシュは `%LOCALAPPDATA%\ssmc\cache\<roleArn の SHA-256 先頭 16 桁>.dat` に保存し、DPAPI（CurrentUser）で暗号化する。有効期限まで 5 分以上残っている場合だけ再利用する。
- 終了コードは 0 = 正常、1 = 事前チェック・設定のエラー、2 = 認証失敗、3 = 接続失敗。
- MFA コードとクレデンシャルは画面にもログにも出力しない。`-Verbose` で表示するコマンドラインでは `--token-code` の値を `******` に置き換える。
- 利用者向けのメッセージは日本語、関数名・変数名は英語。
- aws コマンドの出力を取り込むときは、子プロセスに `PYTHONUTF8=1` を設定する（設定しないと日本語が cp932 で出力され文字化けする。確認済み）。
- `--parameters` は JSON ではなく shorthand 構文（`portNumber=5432,localPortNumber=15432`）で渡す。
- テストの実行コマンド（以降「テスト実行（7）」「テスト実行（5.1）」と呼ぶ。`<path>` はテストファイルまたは `tests`）:
  - 7: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path <path> -Output Detailed"`
  - 5.1: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path <path> -Output Detailed"`
- コマンドはすべてリポジトリのルート `S:\03_Development\99_others\ssm-connector` で実行する。
- コミットメッセージの末尾には `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` を付ける。

## ファイル構成

| ファイル | 責務 | 作成タスク |
|---|---|---|
| `ssmc.ps1` | 入口。引数解析、ヘルプ、全体の流れ、終了コード | Task 9 |
| `ssmc.bat` | ダブルクリック用ラッパー。異常終了時だけ `pause` | Task 9 |
| `ssmc.shared.json` | 共通設定（環境定義・共通プリセット） | Task 9 |
| `lib/SsmcCore.psm1` | region: Common / AwsCli / Prereq / Config / CredCache / Auth / Inventory / Session / Help | Task 1〜7 |
| `lib/SsmcMenu.psm1` | 矢印キー選択 UI、番号入力方式、y/N 確認 | Task 8 |
| `tests/Encoding.Tests.ps1` | `.ps1` / `.psm1` の BOM 検査 | Task 1 |
| `tests/SsmcCore.Tests.ps1` | SsmcCore の単体テスト | Task 1〜7 |
| `tests/SsmcMenu.Tests.ps1` | SsmcMenu の単体テスト | Task 8 |

設計書 §3 の Help 処理は、テストしやすいよう `SsmcCore.psm1` の `Help` region（`Get-SsmcHelpText`）に置き、`ssmc.ps1` は表示だけを行う。テストファイルは設計書の 2 つに加え、文字コード検査用の `tests/Encoding.Tests.ps1` を追加する。

## 関数一覧（タスク間の契約）

| 関数 | 定義タスク | シグネチャ / 戻り値 |
|---|---|---|
| `New-SsmcException` | 1 | `-Message <string> -ExitCode <int>` → `[Exception]`（`Data['SsmcExitCode']` 付き） |
| `Get-SsmcExitCode` | 1 | `-ErrorRecord <ErrorRecord>` → `int`（なければ 1） |
| `Enable-SsmcVerbose` / `Write-SsmcVerbose` | 1 | `Write-SsmcVerbose <string>` |
| `ConvertTo-SsmcArgumentString` | 1 | `<string[]>` → `string` |
| `Format-SsmcAwsCommandLine` | 1 | `<string[]>` → `string`（`aws ...`、token 伏せ字） |
| `Get-SsmcAwsPath` | 1 | → `string` または `$null` |
| `Invoke-Aws` | 1 | `-Arguments <string[]>` → `[pscustomobject]@{ExitCode;StdOut;StdErr}` |
| `Invoke-AwsInteractive` | 1 | `-Arguments <string[]>` → `int`（終了コード） |
| `Get-SsmcAwsErrorKind` | 1 | `<string StdErr>` → `'InvalidMfa' \| 'LoginRequired' \| 'AccessDenied' \| 'Other'` |
| `ConvertFrom-SsmcAwsJson` | 1 | `<string>` → オブジェクトまたは `$null` |
| `ConvertTo-SsmcDateTimeOffset` | 1 | `<string \| DateTime \| DateTimeOffset>` → `DateTimeOffset` |
| `Get-SsmcAwsCliVersion` | 2 | → `[version]` または `$null` |
| `Find-SsmcSessionManagerPlugin` | 2 | → `string` または `$null` |
| `Test-SsmcPrerequisite` | 2 | `-SharedConfigPath <string>` → 問題メッセージ（0 件以上の string） |
| `Add-SsmcPluginToPath` | 2 | → なし（Plugin のフォルダーをプロセスの PATH に追加） |
| `Get-SsmcUserConfigPath` / `Get-SsmcCacheDirectory` | 3 | → `string` |
| `Read-SsmcJsonFile` | 3 | `-Path` → `OrderedDictionary` または `$null` |
| `Merge-SsmcConfig` | 3 | `-Shared <IDictionary> -User <IDictionary>` → Config |
| `Get-SsmcConfig` | 3 | `-SharedConfigPath -UserConfigPath` → Config |
| `Save-SsmcLoginProfile` | 3 | `-UserConfigPath -LoginProfile` |
| `Resolve-SsmcRequest` | 3 | `-Config [-Preset] [-Environment] [-Target] [-LocalPort] [-RemotePort] [-RemoteHost]` → Request |
| `Get-SsmcCachePath` | 4 | `-RoleArn -CacheDirectory` → `string` |
| `Test-SsmcCredentialUsable` | 4 | `-Credential -RoleArn -Now <DateTimeOffset>` → `bool` |
| `Save-SsmcCredential` | 4 | `-Credential -CacheDirectory` |
| `Read-SsmcCredential` | 4 | `-RoleArn -CacheDirectory [-Now]` → Credential または `$null` |
| `Clear-SsmcCredentialCache` | 4 | `-CacheDirectory` |
| `Get-SsmcCallerIdentity` | 5 | `-LoginProfile` → `@{Account;Arn;UserName}` または `$null` |
| `Get-SsmcMfaSerial` | 5 | `-Account -UserName` → `string` |
| `Connect-SsmcLoginProfile` | 5 | `-LoginProfile` → Identity（失敗時は終了コード 2 で throw） |
| `Read-SsmcMfaCode` | 5 | → 6 桁の `string` |
| `Invoke-SsmcAssumeRole` | 5 | `-LoginProfile -RoleArn -Identity -TtlMinutes -MfaCode` → `Invoke-Aws` の結果 |
| `ConvertFrom-SsmcAssumeRoleOutput` | 5 | `-Json -RoleArn -UserName` → Credential |
| `Get-SsmcRoleCredential` | 5 | `-LoginProfile -RoleArn -TtlMinutes -CacheDirectory [-NoCache]` → Credential |
| `Invoke-SsmcWithCredential` | 5 | `-Credential -Region -ScriptBlock` → ScriptBlock の出力 |
| `Get-SsmcInstance` | 6 | `-Region` → Instance（0 件以上） |
| `Merge-SsmcInstanceStatus` | 6 | `-Instances <object[]> -StatusMap <hashtable \| $null>` → Instance（並べ替え済み） |
| `Select-SsmcInstanceByTarget` | 6 | `-Instances -TargetName -TargetInstanceId` → Instance |
| `Get-SsmcInstanceDisplayName` | 6 | `<Instance>` → `string` |
| `ConvertTo-SsmcInstanceMenuItem` | 6 | `-Instances` → MenuItem |
| `Get-SsmcSessionArgument` | 7 | `-InstanceId -Region -Request` → `string[]` |
| `Test-SsmcLocalPortAvailable` | 7 | `-Port <int>` → `bool` |
| `Start-SsmcSession` | 7 | `-Instance -Region -Request`（失敗時は終了コード 3 で throw） |
| `Get-SsmcHelpText` | 7 | `-Config <Config \| $null>` → `string` |
| `Get-SsmcMenuFilteredIndex` | 8 | `-Items -Filter` → `int`（0 件以上） |
| `New-SsmcMenuState` / `Update-SsmcMenuState` | 8 | `-State -Items -KeyName -KeyChar -PageSize` → State |
| `Format-SsmcMenuText` | 8 | `-Text -Width` → 表示幅に合わせた `string` |
| `Show-SsmcMenu` | 8 | `-Title -Items` → 選ばれた項目の `Value` または `$null` |
| `Show-SsmcNumberMenu` | 8 | `-Title -Items` → `Value` または `$null` |
| `Read-SsmcConfirmation` | 8 | `-Message` → `bool` |

**データの形:**

- **Config**: `[pscustomobject]@{ CredentialTtlMinutes = [int]; LoginProfile = [string|null]; Environments = [ordered]@{ <key> = Environment }; Presets = [ordered]@{ <name> = Request } }`
- **Environment**: `[pscustomobject]@{ Key; DisplayName; RoleArn; Region }`
- **Request**（プリセットも同じ形）: `[pscustomobject]@{ EnvKey; TargetName; TargetInstanceId; Type ('shell'|'portForward'); RemoteHost; RemotePort; LocalPort }`
- **Credential**: `[pscustomobject]@{ AccessKeyId; SecretAccessKey; SessionToken; Expiration = [DateTimeOffset]; RoleArn; UserName }`
- **Instance**: `[pscustomobject]@{ Name; InstanceId; PrivateIp; PingStatus }`。`PingStatus` は `Online` などの値、`未登録`、または `$null`（取得権限がない場合）。
- **MenuItem**: `[pscustomobject]@{ Label = [string]; SearchText = [string]; Dim = [bool]; Value = [object] }`
- **State**（メニュー）: `[pscustomobject]@{ Filter = [string]; Cursor = [int]; Top = [int]; Action ('None'|'Select'|'Cancel') }`

**配列の扱い:** 0 件以上の要素を返す関数は、普通にパイプラインへ出力する（配列を包まない）。呼び出し側は必ず `@(...)` で受ける。

---

### Task 1: 開発環境の準備と、SsmcCore の Common / AwsCli region

**Files:**
- Create: `lib/SsmcCore.psm1`
- Create: `tests/SsmcCore.Tests.ps1`
- Create: `tests/Encoding.Tests.ps1`

**Interfaces:**
- Consumes: なし
- Produces: `New-SsmcException`, `Get-SsmcExitCode`, `Enable-SsmcVerbose`, `Write-SsmcVerbose`, `ConvertTo-SsmcArgumentString`, `Format-SsmcAwsCommandLine`, `Get-SsmcAwsPath`, `Invoke-Aws`, `Invoke-AwsInteractive`, `Get-SsmcAwsErrorKind`, `ConvertFrom-SsmcAwsJson`, `ConvertTo-SsmcDateTimeOffset`（シグネチャは関数一覧を参照）

- [ ] **Step 1: Pester 5 を導入する（PowerShell 7 と 5.1 の両方）**

```powershell
pwsh -NoProfile -Command "Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force"
powershell.exe -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null; Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck"
```

確認: `pwsh -NoProfile -Command "(Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()"` の結果が 5.5.0 以上であること。`powershell.exe` でも同じコマンドを実行して確認する。

- [ ] **Step 2: git リポジトリを初期化する**

```powershell
git init
```

- [ ] **Step 3: 文字コード検査のテストを書く**

`tests/Encoding.Tests.ps1`:

```powershell
BeforeDiscovery {
    $root = Split-Path -Parent $PSScriptRoot
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -Include '*.ps1', '*.psm1' |
        ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } })
}

Describe 'ファイルの文字コード' {
    It '<Name> は UTF-8 (BOM 付き) で保存されている' -ForEach $files {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        ($bytes[0..2] -join ',') | Should -Be '239,187,191'
    }
}
```

- [ ] **Step 4: AwsCli region のテストを書く**

`tests/SsmcCore.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\lib\SsmcCore.psm1') -Force
}

Describe 'Common: New-SsmcException / Get-SsmcExitCode' {
    It '終了コード付きの例外から終了コードを取り出せる' {
        try { throw (New-SsmcException -Message 'x' -ExitCode 3) } catch { Get-SsmcExitCode -ErrorRecord $_ | Should -Be 3 }
    }
    It '終了コードのない例外は 1 とみなす' {
        try { throw 'plain error' } catch { Get-SsmcExitCode -ErrorRecord $_ | Should -Be 1 }
    }
}

Describe 'AwsCli: ConvertTo-SsmcArgumentString' {
    It 'スペースや引用符を含まない引数はそのまま連結する' {
        ConvertTo-SsmcArgumentString @('sts', 'get-caller-identity') | Should -Be 'sts get-caller-identity'
    }
    It 'スペースを含む引数は引用符で囲む' {
        ConvertTo-SsmcArgumentString @('a b', 'c') | Should -Be '"a b" c'
    }
    It '引用符はバックスラッシュでエスケープする' {
        ConvertTo-SsmcArgumentString @('say "hi"') | Should -Be '"say \"hi\""'
    }
    It '空文字は "" にする' {
        ConvertTo-SsmcArgumentString @('') | Should -Be '""'
    }
}

Describe 'AwsCli: Format-SsmcAwsCommandLine' {
    It '--token-code の値を伏せ字にする' {
        Format-SsmcAwsCommandLine @('sts', 'assume-role', '--token-code', '123456', '--output', 'json') |
            Should -Be 'aws sts assume-role --token-code ****** --output json'
    }
}

Describe 'AwsCli: Get-SsmcAwsErrorKind' {
    It 'MFA コードの誤りを InvalidMfa と判定する' {
        Get-SsmcAwsErrorKind 'An error occurred (AccessDenied) when calling the AssumeRole operation: MultiFactorAuthentication failed with invalid MFA one time pass code.' |
            Should -Be 'InvalidMfa'
    }
    It 'プロファイルがない場合を LoginRequired と判定する' {
        Get-SsmcAwsErrorKind 'The config profile (my-login) could not be found' | Should -Be 'LoginRequired'
    }
    It 'トークン期限切れを LoginRequired と判定する' {
        Get-SsmcAwsErrorKind 'An error occurred (ExpiredToken) when calling the GetCallerIdentity operation: The security token included in the request is expired' |
            Should -Be 'LoginRequired'
    }
    It '権限不足を AccessDenied と判定する' {
        Get-SsmcAwsErrorKind 'An error occurred (AccessDenied) when calling the AssumeRole operation: User: arn:aws:iam::111111111111:user/taro is not authorized to perform: sts:TagSession' |
            Should -Be 'AccessDenied'
    }
    It 'EC2 の権限不足を AccessDenied と判定する' {
        Get-SsmcAwsErrorKind 'An error occurred (UnauthorizedOperation) when calling the DescribeInstances operation' |
            Should -Be 'AccessDenied'
    }
    It 'それ以外は Other' {
        Get-SsmcAwsErrorKind 'Could not connect to the endpoint URL' | Should -Be 'Other'
    }
}

Describe 'AwsCli: ConvertTo-SsmcDateTimeOffset' {
    It 'ISO 8601 文字列を変換する' {
        (ConvertTo-SsmcDateTimeOffset '2026-10-21T03:00:00+00:00').UtcDateTime |
            Should -Be ([datetime]::new(2026, 10, 21, 3, 0, 0, [DateTimeKind]::Utc))
    }
    It 'DateTime を変換する' {
        $value = [datetime]::new(2026, 10, 21, 3, 0, 0, [DateTimeKind]::Utc)
        (ConvertTo-SsmcDateTimeOffset $value).UtcDateTime | Should -Be $value
    }
}

Describe 'AwsCli: ConvertFrom-SsmcAwsJson' {
    It '空文字は $null を返す' {
        ConvertFrom-SsmcAwsJson '' | Should -BeNullOrEmpty
    }
    It 'JSON をオブジェクトに変換する' {
        (ConvertFrom-SsmcAwsJson '{"Account":"111111111111"}').Account | Should -Be '111111111111'
    }
}

Describe 'AwsCli: Invoke-Aws（実際の aws.exe を使用）' {
    It '標準出力と終了コードを回収する' {
        $result = Invoke-Aws -Arguments @('--version')
        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -Match 'aws-cli/2\.'
    }
    It '標準エラーを日本語を壊さずに回収する' {
        $result = Invoke-Aws -Arguments @('sts', 'get-caller-identity', '--profile', 'ssmc存在しないプロファイル')
        $result.ExitCode | Should -Not -Be 0
        $result.StdErr | Should -Match 'ssmc存在しないプロファイル'
    }
}
```

- [ ] **Step 5: テストを実行して失敗を確認する**

テスト実行（7）: `tests/SsmcCore.Tests.ps1`
Expected: FAIL。BeforeAll の `Import-Module` で「`lib\SsmcCore.psm1` が見つからない」というエラーになり、すべてのテストが失敗する。

- [ ] **Step 6: Common / AwsCli region を実装する**

`lib/SsmcCore.psm1`:

```powershell
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
    $masked = for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($i -gt 0 -and $Arguments[$i - 1] -eq '--token-code') { '******' } else { $Arguments[$i] }
    }
    return 'aws ' + ($masked -join ' ')
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
```

- [ ] **Step 7: 3 ファイルに BOM を付ける**

Global Constraints のコマンドを `lib\SsmcCore.psm1`、`tests\SsmcCore.Tests.ps1`、`tests\Encoding.Tests.ps1` に対して実行する。

- [ ] **Step 8: テストを実行して成功を確認する**

テスト実行（7）: `tests`
テスト実行（5.1）: `tests`
Expected: どちらも全件 PASS（Encoding 3 件を含む）。

- [ ] **Step 9: コミットする**

```powershell
git add lib/SsmcCore.psm1 tests/SsmcCore.Tests.ps1 tests/Encoding.Tests.ps1 ssm-connector-design.md ssm-connector-plan.md
git commit -m "feat: add aws cli wrapper and common helpers" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Prereq region（事前チェック）

**Files:**
- Modify: `lib/SsmcCore.psm1`（末尾に Prereq region を追記）
- Modify: `tests/SsmcCore.Tests.ps1`（末尾に追記）

**Interfaces:**
- Consumes: `Invoke-Aws`, `Get-SsmcAwsPath`（Task 1）
- Produces: `Get-SsmcAwsCliVersion`, `Find-SsmcSessionManagerPlugin`, `Test-SsmcPrerequisite -SharedConfigPath`, `Add-SsmcPluginToPath`

- [ ] **Step 1: テストを書く**

`tests/SsmcCore.Tests.ps1` の末尾に追記する:

```powershell
Describe 'Prereq: Get-SsmcAwsCliVersion' {
    It 'aws --version の出力からバージョンを取り出す' {
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 0; StdOut = 'aws-cli/2.33.12 Python/3.13.11 Windows/11 exe/AMD64'; StdErr = '' } }
        Get-SsmcAwsCliVersion | Should -Be ([version]'2.33.12')
    }
    It '実行に失敗したら $null' {
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'error' } }
        Get-SsmcAwsCliVersion | Should -BeNullOrEmpty
    }
}

Describe 'Prereq: Test-SsmcPrerequisite' {
    BeforeAll {
        $sharedPath = Join-Path $TestDrive 'ssmc.shared.json'
        Set-Content -LiteralPath $sharedPath -Value '{}'
    }
    BeforeEach {
        Mock -ModuleName SsmcCore Get-SsmcAwsPath { 'C:\Program Files\Amazon\AWSCLIV2\aws.exe' }
        Mock -ModuleName SsmcCore Get-SsmcAwsCliVersion { [version]'2.33.12' }
        Mock -ModuleName SsmcCore Find-SsmcSessionManagerPlugin { 'C:\Program Files\Amazon\SessionManagerPlugin\bin\session-manager-plugin.exe' }
    }
    It 'すべてそろっていれば問題なし' {
        @(Test-SsmcPrerequisite -SharedConfigPath $sharedPath).Count | Should -Be 0
    }
    It 'AWS CLI がなければ案内を返す' {
        Mock -ModuleName SsmcCore Get-SsmcAwsPath { $null }
        (@(Test-SsmcPrerequisite -SharedConfigPath $sharedPath) -join "`n") | Should -Match 'AWS CLI v2 が見つかりません'
    }
    It 'AWS CLI が古ければ案内を返す' {
        Mock -ModuleName SsmcCore Get-SsmcAwsCliVersion { [version]'2.31.0' }
        (@(Test-SsmcPrerequisite -SharedConfigPath $sharedPath) -join "`n") | Should -Match '2\.32\.0 以上が必要'
    }
    It 'Session Manager Plugin がなければ案内を返す' {
        Mock -ModuleName SsmcCore Find-SsmcSessionManagerPlugin { $null }
        (@(Test-SsmcPrerequisite -SharedConfigPath $sharedPath) -join "`n") | Should -Match 'Session Manager Plugin が見つかりません'
    }
    It '共通設定ファイルがなければ案内を返す' {
        (@(Test-SsmcPrerequisite -SharedConfigPath (Join-Path $TestDrive 'none.json')) -join "`n") | Should -Match '共通設定ファイルが見つかりません'
    }
}

Describe 'Prereq: Add-SsmcPluginToPath' {
    BeforeEach { $script:originalPath = $env:PATH }
    AfterEach { $env:PATH = $script:originalPath }
    It 'Plugin のフォルダーが PATH になければ追加する' {
        Mock -ModuleName SsmcCore Find-SsmcSessionManagerPlugin { 'C:\ssmc-test-plugin\bin\session-manager-plugin.exe' }
        Add-SsmcPluginToPath
        ($env:PATH -split ';') | Should -Contain 'C:\ssmc-test-plugin\bin'
    }
    It 'すでに PATH にあれば重複して追加しない' {
        $env:PATH = "$env:PATH;C:\ssmc-test-plugin\bin"
        Mock -ModuleName SsmcCore Find-SsmcSessionManagerPlugin { 'C:\ssmc-test-plugin\bin\session-manager-plugin.exe' }
        Add-SsmcPluginToPath
        @($env:PATH -split ';' | Where-Object { $_ -eq 'C:\ssmc-test-plugin\bin' }).Count | Should -Be 1
    }
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

テスト実行（7）: `tests/SsmcCore.Tests.ps1`
Expected: FAIL。Prereq のテストが「`Get-SsmcAwsCliVersion` が見つからない」（CommandNotFoundException）で失敗する。Task 1 のテストは PASS のまま。

- [ ] **Step 3: Prereq region を実装する**

`lib/SsmcCore.psm1` の末尾に追記する:

```powershell
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
```

- [ ] **Step 4: BOM を付けてテストを実行し、成功を確認する**

`lib\SsmcCore.psm1` と `tests\SsmcCore.Tests.ps1` に BOM 付与コマンドを実行する。
テスト実行（7）: `tests`
テスト実行（5.1）: `tests`
Expected: 全件 PASS。

- [ ] **Step 5: コミットする**

```powershell
git add lib/SsmcCore.psm1 tests/SsmcCore.Tests.ps1
git commit -m "feat: add prerequisite checks" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Config region（設定の読み込み・マージ・リクエスト解決）

**Files:**
- Modify: `lib/SsmcCore.psm1`（末尾に Config region を追記）
- Modify: `tests/SsmcCore.Tests.ps1`（末尾に追記）

**Interfaces:**
- Consumes: `New-SsmcException`（Task 1）
- Produces: `Get-SsmcUserConfigPath`, `Get-SsmcCacheDirectory`, `Read-SsmcJsonFile`, `Merge-SsmcConfig`, `Get-SsmcConfig`, `Save-SsmcLoginProfile`, `Resolve-SsmcRequest`。Config / Environment / Request の形は「データの形」を参照。

- [ ] **Step 1: テストを書く**

`tests/SsmcCore.Tests.ps1` の末尾に追記する:

```powershell
Describe 'Config: Merge-SsmcConfig' {
    BeforeAll {
        function New-TestShared {
            [ordered]@{
                version      = 1
                defaults     = [ordered]@{ region = 'ap-northeast-1'; credentialTtlMinutes = 60 }
                environments = [ordered]@{
                    dev  = [ordered]@{ displayName = '開発'; roleArn = 'arn:aws:iam::111111111111:role/Operator' }
                    prod = [ordered]@{ displayName = '本番'; roleArn = 'arn:aws:iam::333333333333:role/Operator'; region = 'us-east-1' }
                }
                presets      = [ordered]@{
                    'shared-web' = [ordered]@{ env = 'dev'; target = [ordered]@{ name = 'web01' } }
                }
            }
        }
    }
    It '環境ごとの region を省略すると defaults.region を使う' {
        $config = Merge-SsmcConfig -Shared (New-TestShared) -User ([ordered]@{})
        $config.Environments['dev'].Region | Should -Be 'ap-northeast-1'
        $config.Environments['prod'].Region | Should -Be 'us-east-1'
    }
    It '個人設定の credentialTtlMinutes が共通設定を上書きする' {
        $config = Merge-SsmcConfig -Shared (New-TestShared) -User ([ordered]@{ credentialTtlMinutes = 30 })
        $config.CredentialTtlMinutes | Should -Be 30
    }
    It '個人設定の environments は同じキーを上書きし、新しいキーを追加する' {
        $user = [ordered]@{ environments = [ordered]@{
            dev = [ordered]@{ displayName = '開発(個人)'; roleArn = 'arn:aws:iam::111111111111:role/Other' }
            sbx = [ordered]@{ displayName = '砂場'; roleArn = 'arn:aws:iam::444444444444:role/Operator' }
        } }
        $config = Merge-SsmcConfig -Shared (New-TestShared) -User $user
        $config.Environments['dev'].DisplayName | Should -Be '開発(個人)'
        $config.Environments.Keys | Should -Contain 'sbx'
    }
    It '個人設定の presets は同名の共通プリセットを上書きする' {
        $user = [ordered]@{ presets = [ordered]@{ 'shared-web' = [ordered]@{ env = 'prod'; target = [ordered]@{ instanceId = 'i-0123456789abcdef0' } } } }
        $config = Merge-SsmcConfig -Shared (New-TestShared) -User $user
        $config.Presets['shared-web'].EnvKey | Should -Be 'prod'
        $config.Presets['shared-web'].TargetInstanceId | Should -Be 'i-0123456789abcdef0'
        $config.Presets['shared-web'].Type | Should -Be 'shell'
    }
    It 'loginProfile を個人設定から読む' {
        (Merge-SsmcConfig -Shared (New-TestShared) -User ([ordered]@{ loginProfile = 'my-login' })).LoginProfile | Should -Be 'my-login'
    }
    It 'version が 1 でなければ終了コード 1 で失敗する' {
        $shared = New-TestShared; $shared['version'] = 2
        $err = { Merge-SsmcConfig -Shared $shared -User ([ordered]@{}) } | Should -Throw -ExpectedMessage '*version*' -PassThru
        $err.Exception.Data['SsmcExitCode'] | Should -Be 1
    }
    It 'credentialTtlMinutes が 15 未満なら失敗する' {
        { Merge-SsmcConfig -Shared (New-TestShared) -User ([ordered]@{ credentialTtlMinutes = 14 }) } | Should -Throw -ExpectedMessage '*15 以上*'
    }
    It 'roleArn の形式が不正なら失敗する' {
        $shared = New-TestShared; $shared['environments']['dev']['roleArn'] = 'Operator'
        { Merge-SsmcConfig -Shared $shared -User ([ordered]@{}) } | Should -Throw -ExpectedMessage "*'dev'*roleArn*"
    }
    It 'プリセットの env が存在しなければ失敗する' {
        $user = [ordered]@{ presets = [ordered]@{ p = [ordered]@{ env = 'none'; target = [ordered]@{ name = 'web01' } } } }
        { Merge-SsmcConfig -Shared (New-TestShared) -User $user } | Should -Throw -ExpectedMessage "*'p'*env*"
    }
    It 'プリセットに target.name と target.instanceId の両方があれば失敗する' {
        $user = [ordered]@{ presets = [ordered]@{ p = [ordered]@{ env = 'dev'; target = [ordered]@{ name = 'web01'; instanceId = 'i-0123456789abcdef0' } } } }
        { Merge-SsmcConfig -Shared (New-TestShared) -User $user } | Should -Throw -ExpectedMessage '*どちらか一方*'
    }
    It 'portForward のプリセットに localPort がなければ失敗する' {
        $user = [ordered]@{ presets = [ordered]@{ p = [ordered]@{ env = 'dev'; target = [ordered]@{ name = 'web01' }; type = 'portForward'; remotePort = 5432 } } }
        { Merge-SsmcConfig -Shared (New-TestShared) -User $user } | Should -Throw -ExpectedMessage '*localPort*'
    }
    It 'portForward のプリセットを読み込める' {
        $user = [ordered]@{ presets = [ordered]@{ db = [ordered]@{ env = 'prod'; target = [ordered]@{ name = 'bastion01' }; type = 'portForward'; remoteHost = 'mydb'; remotePort = 5432; localPort = 15432 } } }
        $preset = (Merge-SsmcConfig -Shared (New-TestShared) -User $user).Presets['db']
        $preset.Type | Should -Be 'portForward'
        $preset.RemoteHost | Should -Be 'mydb'
        $preset.RemotePort | Should -Be 5432
        $preset.LocalPort | Should -Be 15432
    }
}

Describe 'Config: Get-SsmcConfig / Save-SsmcLoginProfile' {
    BeforeAll {
        $sharedPath = Join-Path $TestDrive 'ssmc.shared.json'
        $sharedJson = @'
{
  "version": 1,
  "defaults": { "region": "ap-northeast-1", "credentialTtlMinutes": 60 },
  "environments": { "dev": { "displayName": "開発", "roleArn": "arn:aws:iam::111111111111:role/Operator" } },
  "presets": {}
}
'@
        [System.IO.File]::WriteAllText($sharedPath, $sharedJson, [System.Text.UTF8Encoding]::new($false))
    }
    It '個人設定ファイルがなくても読み込める' {
        $config = Get-SsmcConfig -SharedConfigPath $sharedPath -UserConfigPath (Join-Path $TestDrive 'none\ssmc.user.json')
        $config.Environments['dev'].DisplayName | Should -Be '開発'
        $config.LoginProfile | Should -BeNullOrEmpty
    }
    It 'JSON が壊れていれば終了コード 1 で失敗する' {
        $broken = Join-Path $TestDrive 'broken.json'
        Set-Content -LiteralPath $broken -Value '{ "version": '
        $err = { Get-SsmcConfig -SharedConfigPath $broken -UserConfigPath (Join-Path $TestDrive 'none.json') } | Should -Throw -ExpectedMessage '*broken.json*' -PassThru
        $err.Exception.Data['SsmcExitCode'] | Should -Be 1
    }
    It 'loginProfile を保存し、既存の設定は残す' {
        $userPath = Join-Path $TestDrive 'user\ssmc.user.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $userPath) -Force | Out-Null
        Set-Content -LiteralPath $userPath -Value '{ "credentialTtlMinutes": 30 }'
        Save-SsmcLoginProfile -UserConfigPath $userPath -LoginProfile 'my-login'
        $config = Get-SsmcConfig -SharedConfigPath $sharedPath -UserConfigPath $userPath
        $config.LoginProfile | Should -Be 'my-login'
        $config.CredentialTtlMinutes | Should -Be 30
    }
    It '個人設定のフォルダーがなければ作成して保存する' {
        $userPath = Join-Path $TestDrive 'new\dir\ssmc.user.json'
        Save-SsmcLoginProfile -UserConfigPath $userPath -LoginProfile 'my-login'
        Test-Path -LiteralPath $userPath | Should -BeTrue
    }
}

Describe 'Config: Resolve-SsmcRequest' {
    BeforeAll {
        $shared = [ordered]@{
            version      = 1
            defaults     = [ordered]@{ region = 'ap-northeast-1'; credentialTtlMinutes = 60 }
            environments = [ordered]@{
                dev  = [ordered]@{ displayName = '開発'; roleArn = 'arn:aws:iam::111111111111:role/Operator' }
                prod = [ordered]@{ displayName = '本番'; roleArn = 'arn:aws:iam::333333333333:role/Operator' }
            }
        }
        $user = [ordered]@{ presets = [ordered]@{ 'prod-web01' = [ordered]@{ env = 'prod'; target = [ordered]@{ name = 'web01' } } } }
        $config = Merge-SsmcConfig -Shared $shared -User $user
    }
    It '引数なしなら空のリクエストを返す' {
        $request = Resolve-SsmcRequest -Config $config
        $request.EnvKey | Should -BeNullOrEmpty
        $request.Type | Should -Be 'shell'
    }
    It 'プリセットを解決する' {
        $request = Resolve-SsmcRequest -Config $config -Preset 'prod-web01'
        $request.EnvKey | Should -Be 'prod'
        $request.TargetName | Should -Be 'web01'
    }
    It 'プリセットを解決しても元のプリセットは変更されない' {
        $null = Resolve-SsmcRequest -Config $config -Preset 'prod-web01' -Target 'web02'
        $config.Presets['prod-web01'].TargetName | Should -Be 'web01'
    }
    It '存在しないプリセットは終了コード 1 で失敗する' {
        $err = { Resolve-SsmcRequest -Config $config -Preset 'none' } | Should -Throw -ExpectedMessage "*'none'*" -PassThru
        $err.Exception.Data['SsmcExitCode'] | Should -Be 1
    }
    It '存在しない環境は失敗する' {
        { Resolve-SsmcRequest -Config $config -Environment 'none' } | Should -Throw -ExpectedMessage "*環境 'none'*"
    }
    It 'インスタンス ID 形式の -Target は TargetInstanceId になる' {
        $request = Resolve-SsmcRequest -Config $config -Environment 'dev' -Target 'i-0123456789abcdef0'
        $request.TargetInstanceId | Should -Be 'i-0123456789abcdef0'
        $request.TargetName | Should -BeNullOrEmpty
    }
    It 'それ以外の -Target は TargetName になる' {
        (Resolve-SsmcRequest -Config $config -Environment 'dev' -Target 'web01').TargetName | Should -Be 'web01'
    }
    It '-Target はプリセットの接続先を上書きする' {
        $request = Resolve-SsmcRequest -Config $config -Preset 'prod-web01' -Target 'i-0123456789abcdef0'
        $request.TargetInstanceId | Should -Be 'i-0123456789abcdef0'
        $request.TargetName | Should -BeNullOrEmpty
    }
    It '-LocalPort と -RemotePort でポートフォワードになる' {
        $request = Resolve-SsmcRequest -Config $config -Environment 'prod' -LocalPort 15432 -RemotePort 5432 -RemoteHost 'mydb'
        $request.Type | Should -Be 'portForward'
        $request.LocalPort | Should -Be 15432
        $request.RemotePort | Should -Be 5432
        $request.RemoteHost | Should -Be 'mydb'
    }
    It '-LocalPort だけでは失敗する' {
        { Resolve-SsmcRequest -Config $config -Environment 'prod' -LocalPort 15432 } | Should -Throw -ExpectedMessage '*-LocalPort と -RemotePort*'
    }
    It '-RemoteHost だけでは失敗する' {
        { Resolve-SsmcRequest -Config $config -Environment 'prod' -RemoteHost 'mydb' } | Should -Throw -ExpectedMessage '*-RemoteHost*'
    }
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

テスト実行（7）: `tests/SsmcCore.Tests.ps1`
Expected: FAIL。Config のテストが「`Merge-SsmcConfig` が見つからない」で失敗する。

- [ ] **Step 3: Config region を実装する**

`lib/SsmcCore.psm1` の末尾に追記する:

```powershell
#region Config
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
```

- [ ] **Step 4: BOM を付けてテストを実行し、成功を確認する**

`lib\SsmcCore.psm1` と `tests\SsmcCore.Tests.ps1` に BOM 付与コマンドを実行する。
テスト実行（7）: `tests`
テスト実行（5.1）: `tests`
Expected: 全件 PASS。

- [ ] **Step 5: コミットする**

```powershell
git add lib/SsmcCore.psm1 tests/SsmcCore.Tests.ps1
git commit -m "feat: add config loading, merging and request resolution" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: CredCache region（DPAPI キャッシュ）

**Files:**
- Modify: `lib/SsmcCore.psm1`（末尾に CredCache region を追記）
- Modify: `tests/SsmcCore.Tests.ps1`（末尾に追記）

**Interfaces:**
- Consumes: `ConvertTo-SsmcDateTimeOffset`（Task 1）
- Produces: `Get-SsmcCachePath`, `Test-SsmcCredentialUsable`, `Save-SsmcCredential`, `Read-SsmcCredential`, `Clear-SsmcCredentialCache`。Credential の形は「データの形」を参照。

- [ ] **Step 1: テストを書く**

`tests/SsmcCore.Tests.ps1` の末尾に追記する:

```powershell
Describe 'CredCache' {
    BeforeAll {
        $roleArn = 'arn:aws:iam::111111111111:role/Operator'
        function New-TestCredential {
            param([DateTimeOffset]$Expiration, [string]$RoleArn = 'arn:aws:iam::111111111111:role/Operator')
            [pscustomobject]@{
                AccessKeyId     = 'ASIAEXAMPLE'
                SecretAccessKey = 'secret'
                SessionToken    = 'token'
                Expiration      = $Expiration
                RoleArn         = $RoleArn
                UserName        = 'taro'
            }
        }
    }
    BeforeEach {
        $cacheDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    }
    It '同じロール ARN からは同じパス、違う ARN からは違うパスを作る' {
        $a = Get-SsmcCachePath -RoleArn $roleArn -CacheDirectory $cacheDirectory
        $b = Get-SsmcCachePath -RoleArn $roleArn -CacheDirectory $cacheDirectory
        $c = Get-SsmcCachePath -RoleArn 'arn:aws:iam::333333333333:role/Operator' -CacheDirectory $cacheDirectory
        $a | Should -Be $b
        $a | Should -Not -Be $c
        (Split-Path -Leaf $a) | Should -Match '^[0-9a-f]{16}\.dat$'
    }
    It '保存した認証情報を読み出せる' {
        $now = [DateTimeOffset]::UtcNow
        Save-SsmcCredential -Credential (New-TestCredential -Expiration $now.AddMinutes(60)) -CacheDirectory $cacheDirectory
        $loaded = Read-SsmcCredential -RoleArn $roleArn -CacheDirectory $cacheDirectory -Now $now
        $loaded.SessionToken | Should -Be 'token'
        $loaded.UserName | Should -Be 'taro'
        [int]($loaded.Expiration - $now).TotalMinutes | Should -Be 60
    }
    It 'キャッシュファイルに平文の秘密情報が含まれない' {
        Save-SsmcCredential -Credential (New-TestCredential -Expiration ([DateTimeOffset]::UtcNow.AddMinutes(60))) -CacheDirectory $cacheDirectory
        $text = [System.IO.File]::ReadAllText((Get-SsmcCachePath -RoleArn $roleArn -CacheDirectory $cacheDirectory))
        $text | Should -Not -Match 'secret'
        $text | Should -Not -Match 'ASIAEXAMPLE'
    }
    It '残り 5 分未満なら $null を返し、ファイルを削除する' {
        $now = [DateTimeOffset]::UtcNow
        Save-SsmcCredential -Credential (New-TestCredential -Expiration $now.AddMinutes(4)) -CacheDirectory $cacheDirectory
        Read-SsmcCredential -RoleArn $roleArn -CacheDirectory $cacheDirectory -Now $now | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Get-SsmcCachePath -RoleArn $roleArn -CacheDirectory $cacheDirectory) | Should -BeFalse
    }
    It '壊れたファイルは $null を返し、削除する' {
        New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
        $path = Get-SsmcCachePath -RoleArn $roleArn -CacheDirectory $cacheDirectory
        Set-Content -LiteralPath $path -Value 'broken'
        Read-SsmcCredential -RoleArn $roleArn -CacheDirectory $cacheDirectory | Should -BeNullOrEmpty
        Test-Path -LiteralPath $path | Should -BeFalse
    }
    It 'ファイルがなければ $null を返す' {
        Read-SsmcCredential -RoleArn $roleArn -CacheDirectory $cacheDirectory | Should -BeNullOrEmpty
    }
    It 'RoleArn が一致しなければ使えないと判定する' {
        $now = [DateTimeOffset]::UtcNow
        $credential = New-TestCredential -Expiration $now.AddMinutes(60) -RoleArn 'arn:aws:iam::333333333333:role/Operator'
        Test-SsmcCredentialUsable -Credential $credential -RoleArn $roleArn -Now $now | Should -BeFalse
    }
    It 'Clear-SsmcCredentialCache はキャッシュファイルをすべて削除する' {
        Save-SsmcCredential -Credential (New-TestCredential -Expiration ([DateTimeOffset]::UtcNow.AddMinutes(60))) -CacheDirectory $cacheDirectory
        Clear-SsmcCredentialCache -CacheDirectory $cacheDirectory
        @(Get-ChildItem -LiteralPath $cacheDirectory -Filter '*.dat').Count | Should -Be 0
    }
    It 'キャッシュフォルダーがなくても Clear-SsmcCredentialCache は失敗しない' {
        { Clear-SsmcCredentialCache -CacheDirectory $cacheDirectory } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

テスト実行（7）: `tests/SsmcCore.Tests.ps1`
Expected: FAIL。CredCache のテストが「`Get-SsmcCachePath` が見つからない」で失敗する。

- [ ] **Step 3: CredCache region を実装する**

`lib/SsmcCore.psm1` の末尾に追記する:

```powershell
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
```

- [ ] **Step 4: BOM を付けてテストを実行し、成功を確認する**

`lib\SsmcCore.psm1` と `tests\SsmcCore.Tests.ps1` に BOM 付与コマンドを実行する。
テスト実行（7）: `tests`
テスト実行（5.1）: `tests`
Expected: 全件 PASS。

- [ ] **Step 5: コミットする**

```powershell
git add lib/SsmcCore.psm1 tests/SsmcCore.Tests.ps1
git commit -m "feat: add DPAPI-encrypted credential cache" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Auth region（ログイン確認・MFA・AssumeRole・認証情報の受け渡し）

**Files:**
- Modify: `lib/SsmcCore.psm1`（末尾に Auth region を追記）
- Modify: `tests/SsmcCore.Tests.ps1`（末尾に追記）

**Interfaces:**
- Consumes: `Invoke-Aws`, `Invoke-AwsInteractive`, `Get-SsmcAwsErrorKind`, `ConvertFrom-SsmcAwsJson`, `ConvertTo-SsmcDateTimeOffset`, `New-SsmcException`（Task 1）、`Read-SsmcCredential`, `Save-SsmcCredential`（Task 4）
- Produces: `Get-SsmcCallerIdentity`, `Get-SsmcMfaSerial`, `Connect-SsmcLoginProfile`, `Read-SsmcMfaCode`, `Invoke-SsmcAssumeRole`, `ConvertFrom-SsmcAssumeRoleOutput`, `Get-SsmcRoleCredential`, `Invoke-SsmcWithCredential`

- [ ] **Step 1: テストを書く**

`tests/SsmcCore.Tests.ps1` の末尾に追記する:

```powershell
Describe 'Auth: Get-SsmcMfaSerial / Get-SsmcCallerIdentity' {
    It 'MFA シリアルをアカウント ID とユーザー名から組み立てる' {
        Get-SsmcMfaSerial -Account '111111111111' -UserName 'taro' | Should -Be 'arn:aws:iam::111111111111:mfa/taro'
    }
    It 'get-caller-identity の結果からユーザー名を取り出す' {
        Mock -ModuleName SsmcCore Invoke-Aws {
            [pscustomobject]@{ ExitCode = 0; StdOut = '{"UserId":"AIDA","Account":"111111111111","Arn":"arn:aws:iam::111111111111:user/taro"}'; StdErr = '' }
        }
        $identity = Get-SsmcCallerIdentity -LoginProfile 'my-login'
        $identity.Account | Should -Be '111111111111'
        $identity.UserName | Should -Be 'taro'
        Should -Invoke -ModuleName SsmcCore Invoke-Aws -Times 1 -ParameterFilter { ($Arguments -join ' ') -eq 'sts get-caller-identity --profile my-login --output json' }
    }
    It '失敗したら $null を返す' {
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 255; StdOut = ''; StdErr = 'The config profile (my-login) could not be found' } }
        Get-SsmcCallerIdentity -LoginProfile 'my-login' | Should -BeNullOrEmpty
    }
}

Describe 'Auth: Connect-SsmcLoginProfile' {
    BeforeEach {
        Mock -ModuleName SsmcCore Write-Host { }
        Mock -ModuleName SsmcCore Invoke-AwsInteractive { 0 }
    }
    It 'ログイン済みなら aws login を実行しない' {
        Mock -ModuleName SsmcCore Get-SsmcCallerIdentity { [pscustomobject]@{ Account = '111111111111'; Arn = 'arn'; UserName = 'taro' } }
        (Connect-SsmcLoginProfile -LoginProfile 'my-login').UserName | Should -Be 'taro'
        Should -Invoke -ModuleName SsmcCore Invoke-AwsInteractive -Times 0
    }
    It '未ログインなら aws login を実行して再確認する' {
        $identities = [System.Collections.Queue]::new()
        $identities.Enqueue($null)
        $identities.Enqueue([pscustomobject]@{ Account = '111111111111'; Arn = 'arn'; UserName = 'taro' })
        Mock -ModuleName SsmcCore Get-SsmcCallerIdentity { $identities.Dequeue() }
        (Connect-SsmcLoginProfile -LoginProfile 'my-login').UserName | Should -Be 'taro'
        Should -Invoke -ModuleName SsmcCore Invoke-AwsInteractive -Times 1 -ParameterFilter { ($Arguments -join ' ') -eq 'login --profile my-login' }
    }
    It 'aws login 後も確認できなければ終了コード 2 で失敗する' {
        Mock -ModuleName SsmcCore Get-SsmcCallerIdentity { $null }
        $err = { Connect-SsmcLoginProfile -LoginProfile 'my-login' } | Should -Throw -ExpectedMessage '*ログインに失敗*' -PassThru
        $err.Exception.Data['SsmcExitCode'] | Should -Be 2
    }
}

Describe 'Auth: Get-SsmcRoleCredential' {
    BeforeAll {
        $roleArn = 'arn:aws:iam::333333333333:role/Operator'
        $successJson = '{"Credentials":{"AccessKeyId":"ASIAEXAMPLE","SecretAccessKey":"secret","SessionToken":"token","Expiration":"2026-10-21T04:00:00+00:00"},"AssumedRoleUser":{}}'
    }
    BeforeEach {
        Mock -ModuleName SsmcCore Write-Host { }
        Mock -ModuleName SsmcCore Read-SsmcCredential { $null }
        Mock -ModuleName SsmcCore Save-SsmcCredential { }
        Mock -ModuleName SsmcCore Connect-SsmcLoginProfile { [pscustomobject]@{ Account = '111111111111'; Arn = 'arn:aws:iam::111111111111:user/taro'; UserName = 'taro' } }
        Mock -ModuleName SsmcCore Read-SsmcMfaCode { '123456' }
    }
    It '有効なキャッシュがあれば AssumeRole しない' {
        Mock -ModuleName SsmcCore Read-SsmcCredential { [pscustomobject]@{ SessionToken = 'cached'; Expiration = [DateTimeOffset]::UtcNow.AddMinutes(30) } }
        Mock -ModuleName SsmcCore Invoke-Aws { throw 'should not be called' }
        (Get-SsmcRoleCredential -LoginProfile 'my-login' -RoleArn $roleArn -TtlMinutes 60 -CacheDirectory $TestDrive).SessionToken | Should -Be 'cached'
        Should -Invoke -ModuleName SsmcCore Connect-SsmcLoginProfile -Times 0
    }
    It '-NoCache ならキャッシュを読まない' {
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 0; StdOut = $successJson; StdErr = '' } }
        $null = Get-SsmcRoleCredential -LoginProfile 'my-login' -RoleArn $roleArn -TtlMinutes 60 -CacheDirectory $TestDrive -NoCache
        Should -Invoke -ModuleName SsmcCore Read-SsmcCredential -Times 0
    }
    It 'セッションタグ・MFA・有効時間を指定して AssumeRole し、結果を保存する' {
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 0; StdOut = $successJson; StdErr = '' } }
        $credential = Get-SsmcRoleCredential -LoginProfile 'my-login' -RoleArn $roleArn -TtlMinutes 30 -CacheDirectory $TestDrive
        $credential.AccessKeyId | Should -Be 'ASIAEXAMPLE'
        $credential.RoleArn | Should -Be $roleArn
        $credential.UserName | Should -Be 'taro'
        $credential.Expiration | Should -BeOfType [DateTimeOffset]
        Should -Invoke -ModuleName SsmcCore Invoke-Aws -Times 1 -ParameterFilter {
            $line = $Arguments -join ' '
            $line -like 'sts assume-role --profile my-login --role-arn arn:aws:iam::333333333333:role/Operator*' -and
            $line -like '*--role-session-name taro *' -and
            $line -like '*--serial-number arn:aws:iam::111111111111:mfa/taro --token-code 123456*' -and
            $line -like '*--duration-seconds 1800*' -and
            $line -like '*--tags Key=SSMSessionRunAs,Value=taro*'
        }
        Should -Invoke -ModuleName SsmcCore Save-SsmcCredential -Times 1
    }
    It 'MFA コードを誤ったら再入力させる' {
        $codes = [System.Collections.Queue]::new(@('111111', '222222', '333333'))
        Mock -ModuleName SsmcCore Read-SsmcMfaCode { $codes.Dequeue() }
        Mock -ModuleName SsmcCore Invoke-SsmcAssumeRole { [pscustomobject]@{ ExitCode = 254; StdOut = ''; StdErr = 'MultiFactorAuthentication failed with invalid MFA one time pass code.' } }
        Mock -ModuleName SsmcCore Invoke-SsmcAssumeRole { [pscustomobject]@{ ExitCode = 0; StdOut = $successJson; StdErr = '' } } -ParameterFilter { $MfaCode -eq '333333' }
        (Get-SsmcRoleCredential -LoginProfile 'my-login' -RoleArn $roleArn -TtlMinutes 60 -CacheDirectory $TestDrive).AccessKeyId | Should -Be 'ASIAEXAMPLE'
        Should -Invoke -ModuleName SsmcCore Read-SsmcMfaCode -Times 3 -Exactly
    }
    It 'MFA コードを 3 回誤ったら終了コード 2 で失敗する' {
        Mock -ModuleName SsmcCore Invoke-SsmcAssumeRole { [pscustomobject]@{ ExitCode = 254; StdOut = ''; StdErr = 'MultiFactorAuthentication failed with invalid MFA one time pass code.' } }
        $err = { Get-SsmcRoleCredential -LoginProfile 'my-login' -RoleArn $roleArn -TtlMinutes 60 -CacheDirectory $TestDrive } | Should -Throw -ExpectedMessage '*3 回*' -PassThru
        $err.Exception.Data['SsmcExitCode'] | Should -Be 2
        Should -Invoke -ModuleName SsmcCore Read-SsmcMfaCode -Times 3 -Exactly
    }
    It '権限不足はすぐに終了コード 2 で失敗する' {
        Mock -ModuleName SsmcCore Invoke-SsmcAssumeRole { [pscustomobject]@{ ExitCode = 254; StdOut = ''; StdErr = 'An error occurred (AccessDenied) when calling the AssumeRole operation: User is not authorized to perform: sts:TagSession' } }
        $err = { Get-SsmcRoleCredential -LoginProfile 'my-login' -RoleArn $roleArn -TtlMinutes 60 -CacheDirectory $TestDrive } | Should -Throw -ExpectedMessage '*sts:TagSession*' -PassThru
        $err.Exception.Data['SsmcExitCode'] | Should -Be 2
        Should -Invoke -ModuleName SsmcCore Read-SsmcMfaCode -Times 1 -Exactly
    }
    It '有効時間がロールの上限を超えたら設定の見直しを案内する' {
        Mock -ModuleName SsmcCore Invoke-SsmcAssumeRole { [pscustomobject]@{ ExitCode = 254; StdOut = ''; StdErr = 'An error occurred (ValidationError) when calling the AssumeRole operation: The requested DurationSeconds exceeds the MaxSessionDuration set for this role.' } }
        { Get-SsmcRoleCredential -LoginProfile 'my-login' -RoleArn $roleArn -TtlMinutes 120 -CacheDirectory $TestDrive } | Should -Throw -ExpectedMessage '*credentialTtlMinutes*'
    }
}

Describe 'Auth: Invoke-SsmcWithCredential' {
    BeforeAll {
        $names = @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_REGION', 'AWS_PROFILE', 'AWS_DEFAULT_PROFILE')
        $credential = [pscustomobject]@{ AccessKeyId = 'ASIAEXAMPLE'; SecretAccessKey = 'secret'; SessionToken = 'token' }
    }
    BeforeEach {
        $script:savedEnvironment = @{}
        foreach ($name in $names) { $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
        $env:AWS_PROFILE = 'original-profile'
    }
    AfterEach {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name], 'Process') }
    }
    It '実行中は認証情報を環境変数に設定し、AWS_PROFILE を外す' {
        $inside = Invoke-SsmcWithCredential -Credential $credential -Region 'ap-northeast-1' -ScriptBlock {
            [pscustomobject]@{ Key = $env:AWS_ACCESS_KEY_ID; Token = $env:AWS_SESSION_TOKEN; Region = $env:AWS_REGION; Profile = $env:AWS_PROFILE }
        }
        $inside.Key | Should -Be 'ASIAEXAMPLE'
        $inside.Token | Should -Be 'token'
        $inside.Region | Should -Be 'ap-northeast-1'
        $inside.Profile | Should -BeNullOrEmpty
    }
    It '終了後は元の値に戻す' {
        Invoke-SsmcWithCredential -Credential $credential -Region 'ap-northeast-1' -ScriptBlock { }
        $env:AWS_ACCESS_KEY_ID | Should -BeNullOrEmpty
        $env:AWS_PROFILE | Should -Be 'original-profile'
    }
    It '例外が起きても元の値に戻す' {
        { Invoke-SsmcWithCredential -Credential $credential -Region 'ap-northeast-1' -ScriptBlock { throw 'boom' } } | Should -Throw
        $env:AWS_SECRET_ACCESS_KEY | Should -BeNullOrEmpty
        $env:AWS_PROFILE | Should -Be 'original-profile'
    }
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

テスト実行（7）: `tests/SsmcCore.Tests.ps1`
Expected: FAIL。Auth のテストが「`Get-SsmcMfaSerial` が見つからない」などで失敗する。

- [ ] **Step 3: Auth region を実装する**

`lib/SsmcCore.psm1` の末尾に追記する:

```powershell
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
        $secure = Read-Host -Prompt 'MFAコード（6桁）' -AsSecureString
        $code = [System.Net.NetworkCredential]::new('', $secure).Password
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
        [Environment]::SetEnvironmentVariable('AWS_ACCESS_KEY_ID', $Credential.AccessKeyId, 'Process')
        [Environment]::SetEnvironmentVariable('AWS_SECRET_ACCESS_KEY', $Credential.SecretAccessKey, 'Process')
        [Environment]::SetEnvironmentVariable('AWS_SESSION_TOKEN', $Credential.SessionToken, 'Process')
        [Environment]::SetEnvironmentVariable('AWS_REGION', $Region, 'Process')
        # プロファイル指定が残っていると、そちらの認証情報が使われるおそれがあるため外す
        [Environment]::SetEnvironmentVariable('AWS_PROFILE', $null, 'Process')
        [Environment]::SetEnvironmentVariable('AWS_DEFAULT_PROFILE', $null, 'Process')
        & $ScriptBlock
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}
#endregion
```

- [ ] **Step 4: BOM を付けてテストを実行し、成功を確認する**

`lib\SsmcCore.psm1` と `tests\SsmcCore.Tests.ps1` に BOM 付与コマンドを実行する。
テスト実行（7）: `tests`
テスト実行（5.1）: `tests`
Expected: 全件 PASS。

- [ ] **Step 5: コミットする**

```powershell
git add lib/SsmcCore.psm1 tests/SsmcCore.Tests.ps1
git commit -m "feat: add login check, MFA and tagged assume-role" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Inventory region（サーバー一覧）

**Files:**
- Modify: `lib/SsmcCore.psm1`（末尾に Inventory region を追記）
- Modify: `tests/SsmcCore.Tests.ps1`（末尾に追記）

**Interfaces:**
- Consumes: `Invoke-Aws`, `ConvertFrom-SsmcAwsJson`, `Get-SsmcAwsErrorKind`, `New-SsmcException`（Task 1）
- Produces: `Get-SsmcInstance`, `Merge-SsmcInstanceStatus`, `Select-SsmcInstanceByTarget`, `Get-SsmcInstanceDisplayName`, `ConvertTo-SsmcInstanceMenuItem`。Instance / MenuItem の形は「データの形」を参照。

- [ ] **Step 1: テストを書く**

`tests/SsmcCore.Tests.ps1` の末尾に追記する:

```powershell
Describe 'Inventory: Merge-SsmcInstanceStatus' {
    BeforeAll {
        $instances = @(
            [pscustomobject]@{ Name = 'web01'; InstanceId = 'i-0000000000000000b'; PrivateIp = '10.0.1.20'; PingStatus = $null }
            [pscustomobject]@{ Name = $null; InstanceId = 'i-0000000000000000c'; PrivateIp = '10.0.1.30'; PingStatus = $null }
            [pscustomobject]@{ Name = 'app01'; InstanceId = 'i-0000000000000000a'; PrivateIp = '10.0.1.10'; PingStatus = $null }
        )
    }
    It 'Name の昇順に並べ、Name のないものは末尾に置く' {
        $result = @(Merge-SsmcInstanceStatus -Instances $instances -StatusMap @{})
        ($result | ForEach-Object { $_.InstanceId }) -join ',' | Should -Be 'i-0000000000000000a,i-0000000000000000b,i-0000000000000000c'
    }
    It 'SSM の状態を付け、含まれないものは未登録にする' {
        $result = @(Merge-SsmcInstanceStatus -Instances $instances -StatusMap @{ 'i-0000000000000000a' = 'Online'; 'i-0000000000000000b' = 'ConnectionLost' })
        $result[0].PingStatus | Should -Be 'Online'
        $result[1].PingStatus | Should -Be 'ConnectionLost'
        $result[2].PingStatus | Should -Be '未登録'
    }
    It 'StatusMap が $null なら状態は $null のまま' {
        $result = @(Merge-SsmcInstanceStatus -Instances $instances -StatusMap $null)
        $result[0].PingStatus | Should -BeNullOrEmpty
    }
    It '0 件なら何も返さない' {
        @(Merge-SsmcInstanceStatus -Instances @() -StatusMap @{}).Count | Should -Be 0
    }
}

Describe 'Inventory: Get-SsmcInstance' {
    BeforeAll {
        $ec2Json = @'
{"Reservations":[
  {"Instances":[{"InstanceId":"i-0000000000000000b","PrivateIpAddress":"10.0.1.20","Tags":[{"Key":"Name","Value":"web01"},{"Key":"Env","Value":"prod"}]}]},
  {"Instances":[{"InstanceId":"i-0000000000000000c","PrivateIpAddress":"10.0.1.30"}]}
]}
'@
        $ssmJson = '{"InstanceInformationList":[{"InstanceId":"i-0000000000000000b","PingStatus":"Online"}]}'
    }
    It 'EC2 と SSM の情報を結合する' {
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 0; StdOut = $ec2Json; StdErr = '' } } -ParameterFilter { $Arguments[0] -eq 'ec2' }
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 0; StdOut = $ssmJson; StdErr = '' } } -ParameterFilter { $Arguments[0] -eq 'ssm' }
        $result = @(Get-SsmcInstance -Region 'ap-northeast-1')
        $result.Count | Should -Be 2
        $result[0].Name | Should -Be 'web01'
        $result[0].PingStatus | Should -Be 'Online'
        $result[1].Name | Should -BeNullOrEmpty
        $result[1].PingStatus | Should -Be '未登録'
        Should -Invoke -ModuleName SsmcCore Invoke-Aws -ParameterFilter { ($Arguments -join ' ') -eq 'ec2 describe-instances --region ap-northeast-1 --filters Name=instance-state-name,Values=running --output json' }
    }
    It '1 件だけでも配列として扱える' {
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 0; StdOut = '{"Reservations":[{"Instances":[{"InstanceId":"i-0000000000000000b","PrivateIpAddress":"10.0.1.20"}]}]}'; StdErr = '' } } -ParameterFilter { $Arguments[0] -eq 'ec2' }
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 0; StdOut = $ssmJson; StdErr = '' } } -ParameterFilter { $Arguments[0] -eq 'ssm' }
        @(Get-SsmcInstance -Region 'ap-northeast-1').Count | Should -Be 1
    }
    It '稼働中のインスタンスがなければ何も返さない' {
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 0; StdOut = '{"Reservations":[]}'; StdErr = '' } } -ParameterFilter { $Arguments[0] -eq 'ec2' }
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 0; StdOut = '{"InstanceInformationList":[]}'; StdErr = '' } } -ParameterFilter { $Arguments[0] -eq 'ssm' }
        @(Get-SsmcInstance -Region 'ap-northeast-1').Count | Should -Be 0
    }
    It 'SSM の権限がなければ状態なしで続行する' {
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 0; StdOut = $ec2Json; StdErr = '' } } -ParameterFilter { $Arguments[0] -eq 'ec2' }
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 254; StdOut = ''; StdErr = 'An error occurred (AccessDeniedException) when calling the DescribeInstanceInformation operation' } } -ParameterFilter { $Arguments[0] -eq 'ssm' }
        $result = @(Get-SsmcInstance -Region 'ap-northeast-1')
        $result.Count | Should -Be 2
        $result[0].PingStatus | Should -BeNullOrEmpty
    }
    It 'SSM がそれ以外の理由で失敗したら終了コード 3 で失敗する' {
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 0; StdOut = $ec2Json; StdErr = '' } } -ParameterFilter { $Arguments[0] -eq 'ec2' }
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 255; StdOut = ''; StdErr = 'Could not connect to the endpoint URL' } } -ParameterFilter { $Arguments[0] -eq 'ssm' }
        $err = { Get-SsmcInstance -Region 'ap-northeast-1' } | Should -Throw -ExpectedMessage '*SSM*' -PassThru
        $err.Exception.Data['SsmcExitCode'] | Should -Be 3
    }
    It 'EC2 の取得に失敗したら終了コード 3 で失敗する' {
        Mock -ModuleName SsmcCore Invoke-Aws { [pscustomobject]@{ ExitCode = 254; StdOut = ''; StdErr = 'An error occurred (UnauthorizedOperation)' } } -ParameterFilter { $Arguments[0] -eq 'ec2' }
        $err = { Get-SsmcInstance -Region 'ap-northeast-1' } | Should -Throw -ExpectedMessage '*EC2*UnauthorizedOperation*' -PassThru
        $err.Exception.Data['SsmcExitCode'] | Should -Be 3
    }
}

Describe 'Inventory: Select-SsmcInstanceByTarget / ConvertTo-SsmcInstanceMenuItem' {
    BeforeAll {
        $instances = @(
            [pscustomobject]@{ Name = 'web01'; InstanceId = 'i-0000000000000000a'; PrivateIp = '10.0.1.10'; PingStatus = 'Online' }
            [pscustomobject]@{ Name = 'web01'; InstanceId = 'i-0000000000000000b'; PrivateIp = '10.0.1.11'; PingStatus = 'ConnectionLost' }
            [pscustomobject]@{ Name = $null; InstanceId = 'i-0000000000000000c'; PrivateIp = '10.0.1.12'; PingStatus = $null }
        )
    }
    It 'Name で絞り込む（大文字小文字を区別しない）' {
        @(Select-SsmcInstanceByTarget -Instances $instances -TargetName 'WEB01').Count | Should -Be 2
    }
    It 'インスタンス ID で絞り込む' {
        @(Select-SsmcInstanceByTarget -Instances $instances -TargetInstanceId 'i-0000000000000000c').Count | Should -Be 1
    }
    It '指定がなければすべて返す' {
        @(Select-SsmcInstanceByTarget -Instances $instances).Count | Should -Be 3
    }
    It 'メニュー項目に変換する' {
        $items = @(ConvertTo-SsmcInstanceMenuItem -Instances $instances)
        $items[0].Label | Should -Match 'web01\s+i-0000000000000000a\s+10\.0\.1\.10\s+Online'
        $items[0].Dim | Should -BeFalse
        $items[1].Dim | Should -BeTrue
        $items[2].Label | Should -Match '<Nameタグなし>'
        $items[2].Label | Should -Not -Match 'Online|ConnectionLost'
        $items[2].Dim | Should -BeFalse
        $items[0].SearchText | Should -Match '10\.0\.1\.10'
        $items[0].Value.InstanceId | Should -Be 'i-0000000000000000a'
    }
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

テスト実行（7）: `tests/SsmcCore.Tests.ps1`
Expected: FAIL。Inventory のテストが「`Merge-SsmcInstanceStatus` が見つからない」などで失敗する。

- [ ] **Step 3: Inventory region を実装する**

`lib/SsmcCore.psm1` の末尾に追記する:

```powershell
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
```

- [ ] **Step 4: BOM を付けてテストを実行し、成功を確認する**

`lib\SsmcCore.psm1` と `tests\SsmcCore.Tests.ps1` に BOM 付与コマンドを実行する。
テスト実行（7）: `tests`
テスト実行（5.1）: `tests`
Expected: 全件 PASS。

- [ ] **Step 5: コミットする**

```powershell
git add lib/SsmcCore.psm1 tests/SsmcCore.Tests.ps1
git commit -m "feat: add instance inventory with SSM ping status" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Session region（接続実行）と Help region

**Files:**
- Modify: `lib/SsmcCore.psm1`（末尾に Session / Help region を追記）
- Modify: `tests/SsmcCore.Tests.ps1`（末尾に追記）

**Interfaces:**
- Consumes: `Invoke-AwsInteractive`, `New-SsmcException`（Task 1）、Request / Config の形（Task 3）、`Get-SsmcInstanceDisplayName`（Task 6）
- Produces: `Get-SsmcSessionArgument`, `Test-SsmcLocalPortAvailable`, `Start-SsmcSession`, `Get-SsmcHelpText`

- [ ] **Step 1: テストを書く**

`tests/SsmcCore.Tests.ps1` の末尾に追記する:

```powershell
Describe 'Session: Get-SsmcSessionArgument' {
    BeforeAll {
        function New-TestRequest {
            param([string]$Type = 'shell', $RemoteHost = $null, $RemotePort = $null, $LocalPort = $null)
            [pscustomobject]@{ EnvKey = 'prod'; TargetName = $null; TargetInstanceId = $null; Type = $Type; RemoteHost = $RemoteHost; RemotePort = $RemotePort; LocalPort = $LocalPort }
        }
    }
    It 'シェル接続の引数を作る' {
        (Get-SsmcSessionArgument -InstanceId 'i-0000000000000000a' -Region 'ap-northeast-1' -Request (New-TestRequest)) -join ' ' |
            Should -Be 'ssm start-session --target i-0000000000000000a --region ap-northeast-1'
    }
    It 'インスタンス自身へのポートフォワードの引数を作る' {
        (Get-SsmcSessionArgument -InstanceId 'i-0000000000000000a' -Region 'ap-northeast-1' -Request (New-TestRequest -Type 'portForward' -RemotePort 3389 -LocalPort 13389)) -join ' ' |
            Should -Be 'ssm start-session --target i-0000000000000000a --region ap-northeast-1 --document-name AWS-StartPortForwardingSession --parameters portNumber=3389,localPortNumber=13389'
    }
    It '別ホストへのポートフォワードの引数を作る' {
        (Get-SsmcSessionArgument -InstanceId 'i-0000000000000000a' -Region 'ap-northeast-1' -Request (New-TestRequest -Type 'portForward' -RemoteHost 'mydb' -RemotePort 5432 -LocalPort 15432)) -join ' ' |
            Should -Be 'ssm start-session --target i-0000000000000000a --region ap-northeast-1 --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters host=mydb,portNumber=5432,localPortNumber=15432'
    }
}

Describe 'Session: Test-SsmcLocalPortAvailable' {
    It '使用中のポートは false、解放後は true' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        try {
            Test-SsmcLocalPortAvailable -Port $port | Should -BeFalse
        } finally {
            $listener.Stop()
        }
        Test-SsmcLocalPortAvailable -Port $port | Should -BeTrue
    }
}

Describe 'Session: Start-SsmcSession' {
    BeforeAll {
        $instance = [pscustomobject]@{ Name = 'web01'; InstanceId = 'i-0000000000000000a'; PrivateIp = '10.0.1.10'; PingStatus = 'Online' }
        $request = [pscustomobject]@{ EnvKey = 'prod'; TargetName = $null; TargetInstanceId = $null; Type = 'shell'; RemoteHost = $null; RemotePort = $null; LocalPort = $null }
    }
    BeforeEach { Mock -ModuleName SsmcCore Write-Host { } }
    It 'start-session を対話モードで実行する' {
        Mock -ModuleName SsmcCore Invoke-AwsInteractive { 0 }
        { Start-SsmcSession -Instance $instance -Region 'ap-northeast-1' -Request $request } | Should -Not -Throw
        Should -Invoke -ModuleName SsmcCore Invoke-AwsInteractive -Times 1 -ParameterFilter { $Arguments[1] -eq 'start-session' }
    }
    It '失敗したら終了コード 3 で失敗する' {
        Mock -ModuleName SsmcCore Invoke-AwsInteractive { 255 }
        $err = { Start-SsmcSession -Instance $instance -Region 'ap-northeast-1' -Request $request } | Should -Throw -PassThru
        $err.Exception.Data['SsmcExitCode'] | Should -Be 3
    }
}

Describe 'Help: Get-SsmcHelpText' {
    It '設定がなければ使い方だけを返す' {
        $text = Get-SsmcHelpText -Config $null
        $text | Should -Match '使い方: ssmc'
        $text | Should -Not -Match '環境:'
    }
    It '環境とプリセットの一覧を含める' {
        $shared = [ordered]@{
            version      = 1
            defaults     = [ordered]@{ region = 'ap-northeast-1'; credentialTtlMinutes = 60 }
            environments = [ordered]@{ prod = [ordered]@{ displayName = '本番'; roleArn = 'arn:aws:iam::333333333333:role/Operator' } }
        }
        $user = [ordered]@{ presets = [ordered]@{
            'prod-web01' = [ordered]@{ env = 'prod'; target = [ordered]@{ name = 'web01' } }
            'prod-db'    = [ordered]@{ env = 'prod'; target = [ordered]@{ name = 'bastion01' }; type = 'portForward'; remoteHost = 'mydb'; remotePort = 5432; localPort = 15432 }
        } }
        $text = Get-SsmcHelpText -Config (Merge-SsmcConfig -Shared $shared -User $user)
        $text | Should -Match 'prod\s+本番'
        $text | Should -Match 'prod-web01\s+本番 / web01 / shell'
        $text | Should -Match 'prod-db\s+本番 / bastion01 / portForward 15432 -> mydb:5432'
    }
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

テスト実行（7）: `tests/SsmcCore.Tests.ps1`
Expected: FAIL。Session / Help のテストが「`Get-SsmcSessionArgument` が見つからない」などで失敗する。

- [ ] **Step 3: Session / Help region を実装する**

`lib/SsmcCore.psm1` の末尾に追記する:

```powershell
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
```

- [ ] **Step 4: BOM を付けてテストを実行し、成功を確認する**

`lib\SsmcCore.psm1` と `tests\SsmcCore.Tests.ps1` に BOM 付与コマンドを実行する。
テスト実行（7）: `tests`
テスト実行（5.1）: `tests`
Expected: 全件 PASS。

- [ ] **Step 5: コミットする**

```powershell
git add lib/SsmcCore.psm1 tests/SsmcCore.Tests.ps1
git commit -m "feat: add session start, port forwarding and help text" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: SsmcMenu.psm1（矢印キー選択 UI）

**Files:**
- Create: `lib/SsmcMenu.psm1`
- Create: `tests/SsmcMenu.Tests.ps1`

**Interfaces:**
- Consumes: MenuItem の形（`Label`, `SearchText`, `Dim`, `Value`）。SsmcCore には依存しない。
- Produces: `Get-SsmcMenuFilteredIndex`, `New-SsmcMenuState`, `Update-SsmcMenuState`, `Format-SsmcMenuText`, `Show-SsmcMenu -Title -Items`, `Show-SsmcNumberMenu -Title -Items`, `Read-SsmcConfirmation -Message`

- [ ] **Step 1: テストを書く**

`tests/SsmcMenu.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\lib\SsmcMenu.psm1') -Force
    function New-TestItems {
        param([int]$Count)
        foreach ($i in 1..$Count) {
            $name = 'srv{0:D2}' -f $i
            [pscustomobject]@{ Label = $name; SearchText = "$name i-$i 10.0.0.$i"; Dim = $false; Value = $name }
        }
    }
    function Invoke-Keys {
        param($Items, [string[]]$Keys, [int]$PageSize = 5)
        $state = New-SsmcMenuState
        foreach ($key in $Keys) {
            if ($key.Length -eq 1) {
                $state = Update-SsmcMenuState -State $state -Items $Items -KeyName 'A' -KeyChar $key -PageSize $PageSize
            } else {
                $state = Update-SsmcMenuState -State $state -Items $Items -KeyName $key -PageSize $PageSize
            }
        }
        return $state
    }
}

Describe 'Get-SsmcMenuFilteredIndex' {
    It '絞り込み文字列が空ならすべての添字を返す' {
        @(Get-SsmcMenuFilteredIndex -Items @(New-TestItems 3) -Filter '').Count | Should -Be 3
    }
    It 'SearchText を大文字小文字を区別せずに部分一致で絞り込む' {
        (@(Get-SsmcMenuFilteredIndex -Items @(New-TestItems 12) -Filter 'SRV1') -join ',') | Should -Be '9,10,11'
    }
    It 'IP でも絞り込める' {
        (@(Get-SsmcMenuFilteredIndex -Items @(New-TestItems 3) -Filter '10.0.0.2') -join ',') | Should -Be '1'
    }
}

Describe 'Update-SsmcMenuState' {
    BeforeAll { $items = @(New-TestItems 12) }
    It '下矢印で移動し、末尾で止まる' {
        (Invoke-Keys $items @('DownArrow', 'DownArrow')).Cursor | Should -Be 2
        (Invoke-Keys $items (@('DownArrow') * 20)).Cursor | Should -Be 11
    }
    It '上矢印で移動し、先頭で止まる' {
        (Invoke-Keys $items @('UpArrow')).Cursor | Should -Be 0
    }
    It 'PageDown / PageUp で 1 ページ分移動する' {
        (Invoke-Keys $items @('PageDown')).Cursor | Should -Be 5
        (Invoke-Keys $items @('PageDown', 'PageDown', 'PageUp')).Cursor | Should -Be 5
    }
    It 'End / Home で末尾・先頭へ移動する' {
        (Invoke-Keys $items @('End')).Cursor | Should -Be 11
        (Invoke-Keys $items @('End', 'Home')).Cursor | Should -Be 0
    }
    It 'カーソルが表示範囲を超えたらスクロールする' {
        $state = Invoke-Keys $items (@('DownArrow') * 6)
        $state.Cursor | Should -Be 6
        $state.Top | Should -Be 2
        (Invoke-Keys $items @('End')).Top | Should -Be 7
    }
    It '文字入力で絞り込み、カーソルを先頭に戻す' {
        $state = Invoke-Keys $items @('DownArrow', 'DownArrow', '1')
        $state.Filter | Should -Be '1'
        $state.Cursor | Should -Be 0
        $state.Top | Should -Be 0
    }
    It 'Backspace で 1 文字消す' {
        (Invoke-Keys $items @('s', 'r', 'Backspace')).Filter | Should -Be 's'
    }
    It 'Enter で Select になる' {
        (Invoke-Keys $items @('Enter')).Action | Should -Be 'Select'
    }
    It '該当がなければ Enter しても Select にならない' {
        (Invoke-Keys $items @('z', 'z', 'Enter')).Action | Should -Be 'None'
    }
    It 'Escape で Cancel になる' {
        (Invoke-Keys $items @('Escape')).Action | Should -Be 'Cancel'
    }
}

Describe 'Format-SsmcMenuText' {
    It '幅に足りない分を空白で埋める' {
        Format-SsmcMenuText -Text 'abc' -Width 5 | Should -Be 'abc  '
    }
    It '全角文字を幅 2 として切り詰める' {
        Format-SsmcMenuText -Text 'あいう' -Width 5 | Should -Be 'あい '
    }
}

Describe 'Show-SsmcMenu（番号入力方式）' {
    BeforeEach {
        Mock -ModuleName SsmcMenu Write-Host { }
    }
    It 'コンソールでなければ番号入力方式に切り替える' {
        Mock -ModuleName SsmcMenu Test-SsmcInteractiveConsole { $false }
        Mock -ModuleName SsmcMenu Show-SsmcNumberMenu { 'picked' }
        Show-SsmcMenu -Title 't' -Items @(New-TestItems 2) | Should -Be 'picked'
    }
    It '番号で選んだ項目の Value を返す（不正な入力は聞き直す）' {
        $answers = [System.Collections.Queue]::new(@('x', '9', '2'))
        Mock -ModuleName SsmcMenu Read-Host { $answers.Dequeue() }
        Show-SsmcNumberMenu -Title 't' -Items @(New-TestItems 3) | Should -Be 'srv02'
        Should -Invoke -ModuleName SsmcMenu Read-Host -Times 3 -Exactly
    }
    It 'q で $null を返す' {
        Mock -ModuleName SsmcMenu Read-Host { 'q' }
        Show-SsmcNumberMenu -Title 't' -Items @(New-TestItems 3) | Should -BeNullOrEmpty
    }
}

Describe 'Read-SsmcConfirmation' {
    It 'y なら true' {
        Mock -ModuleName SsmcMenu Read-Host { 'y' }
        Read-SsmcConfirmation -Message '接続しますか？' | Should -BeTrue
    }
    It '空入力なら false' {
        Mock -ModuleName SsmcMenu Read-Host { '' }
        Read-SsmcConfirmation -Message '接続しますか？' | Should -BeFalse
    }
}
```

- [ ] **Step 2: テストを実行して失敗を確認する**

テスト実行（7）: `tests/SsmcMenu.Tests.ps1`
Expected: FAIL。BeforeAll の `Import-Module` で「`lib\SsmcMenu.psm1` が見つからない」というエラーになる。

- [ ] **Step 3: SsmcMenu.psm1 を実装する**

`lib/SsmcMenu.psm1`:

```powershell
# NOTE: Windows PowerShell 5.1 の文字化け防止のため、このファイルは UTF-8 (BOM 付き) で保存すること。

#region State（純粋関数）
function Get-SsmcMenuFilteredIndex {
    param(
        [AllowEmptyCollection()][object[]]$Items = @(),
        [string]$Filter
    )
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ([string]::IsNullOrEmpty($Filter) -or $Items[$i].SearchText.IndexOf($Filter, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $i
        }
    }
}

function New-SsmcMenuState {
    return [pscustomobject]@{ Filter = ''; Cursor = 0; Top = 0; Action = 'None' }
}

function Update-SsmcMenuState {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][string]$KeyName,
        [char]$KeyChar = [char]0,
        [Parameter(Mandatory)][int]$PageSize
    )
    $filter = $State.Filter
    $cursor = $State.Cursor
    $action = 'None'
    switch ($KeyName) {
        'UpArrow' { $cursor-- }
        'DownArrow' { $cursor++ }
        'PageUp' { $cursor -= $PageSize }
        'PageDown' { $cursor += $PageSize }
        'Home' { $cursor = 0 }
        'End' { $cursor = [int]::MaxValue }
        'Enter' { $action = 'Select' }
        'Escape' { $action = 'Cancel' }
        'Backspace' {
            if ($filter.Length -gt 0) {
                $filter = $filter.Substring(0, $filter.Length - 1)
                $cursor = 0
            }
        }
        default {
            if ($KeyChar -ne [char]0 -and -not [char]::IsControl($KeyChar)) {
                $filter += $KeyChar
                $cursor = 0
            }
        }
    }
    $count = @(Get-SsmcMenuFilteredIndex -Items $Items -Filter $filter).Count
    if ($count -eq 0) {
        $cursor = 0
        if ($action -eq 'Select') { $action = 'None' }
    } else {
        $cursor = [Math]::Max(0, [Math]::Min($cursor, $count - 1))
    }
    $top = $State.Top
    if ($cursor -lt $top) { $top = $cursor }
    if ($cursor -ge $top + $PageSize) { $top = $cursor - $PageSize + 1 }
    $top = [Math]::Max(0, [Math]::Min($top, [Math]::Max(0, $count - $PageSize)))
    return [pscustomobject]@{ Filter = $filter; Cursor = $cursor; Top = $top; Action = $action }
}

function Get-SsmcCharWidth {
    param([char]$Char)
    $code = [int]$Char
    # 東アジアの全角文字はコンソール上で 2 桁を占める
    if (($code -ge 0x1100 -and $code -le 0x115F) -or ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
        ($code -ge 0xAC00 -and $code -le 0xD7A3) -or ($code -ge 0xF900 -and $code -le 0xFAFF) -or
        ($code -ge 0xFE30 -and $code -le 0xFE4F) -or ($code -ge 0xFF00 -and $code -le 0xFF60) -or
        ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
        return 2
    }
    return 1
}

function Format-SsmcMenuText {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Width
    )
    $builder = [System.Text.StringBuilder]::new()
    $used = 0
    foreach ($char in $Text.ToCharArray()) {
        $charWidth = Get-SsmcCharWidth $char
        if ($used + $charWidth -gt $Width) { break }
        [void]$builder.Append($char)
        $used += $charWidth
    }
    return $builder.ToString() + (' ' * ($Width - $used))
}
#endregion

#region Render
function Test-SsmcInteractiveConsole {
    return ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected)
}

function Write-SsmcMenuLine {
    param(
        [int]$Row,
        [int]$Width,
        [AllowEmptyString()][string]$Text,
        [ConsoleColor]$Color = [Console]::ForegroundColor,
        [switch]$Inverse
    )
    [Console]::SetCursorPosition(0, $Row)
    $line = Format-SsmcMenuText -Text $Text -Width $Width
    if ($Inverse) {
        Write-Host $line -NoNewline -ForegroundColor ([Console]::BackgroundColor) -BackgroundColor ([Console]::ForegroundColor)
    } else {
        Write-Host $line -NoNewline -ForegroundColor $Color
    }
}

function Write-SsmcMenuFrame {
    param([int]$Origin, [string]$Title, [object[]]$Items, $State, [int]$PageSize)
    # 最終桁まで書くと折り返して表示が崩れるため 1 桁残す
    $width = [Math]::Max(20, [Console]::WindowWidth - 1)
    $indexes = @(Get-SsmcMenuFilteredIndex -Items $Items -Filter $State.Filter)
    Write-SsmcMenuLine -Row $Origin -Width $width -Text "$Title  [上下:移動 Enter:決定 文字:絞り込み Esc:終了]" -Color Cyan
    Write-SsmcMenuLine -Row ($Origin + 1) -Width $width -Text " 絞り込み: $($State.Filter)_  ($($indexes.Count)/$($Items.Count) 件)"
    for ($row = 0; $row -lt $PageSize; $row++) {
        $position = $State.Top + $row
        $lineRow = $Origin + 2 + $row
        if ($position -ge $indexes.Count) {
            Write-SsmcMenuLine -Row $lineRow -Width $width -Text ''
            continue
        }
        $item = $Items[$indexes[$position]]
        if ($position -eq $State.Cursor) {
            Write-SsmcMenuLine -Row $lineRow -Width $width -Text " > $($item.Label)" -Inverse
        } elseif ($item.Dim) {
            Write-SsmcMenuLine -Row $lineRow -Width $width -Text "   $($item.Label)" -Color DarkGray
        } else {
            Write-SsmcMenuLine -Row $lineRow -Width $width -Text "   $($item.Label)"
        }
    }
}

function Show-SsmcMenu {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items
    )
    if (-not (Test-SsmcInteractiveConsole)) { return (Show-SsmcNumberMenu -Title $Title -Items $Items) }
    $pageSize = [Math]::Max(1, [Math]::Min($Items.Count, [Console]::WindowHeight - 4))
    $lineCount = $pageSize + 2
    # 先に描画領域を確保してから、その先頭行を基準に描き直す
    for ($i = 0; $i -lt $lineCount; $i++) { [Console]::WriteLine() }
    $origin = [Console]::CursorTop - $lineCount
    $state = New-SsmcMenuState
    $cursorVisible = [Console]::CursorVisible
    try {
        [Console]::CursorVisible = $false
        while ($true) {
            Write-SsmcMenuFrame -Origin $origin -Title $Title -Items $Items -State $state -PageSize $pageSize
            $key = [Console]::ReadKey($true)
            $state = Update-SsmcMenuState -State $state -Items $Items -KeyName $key.Key.ToString() -KeyChar $key.KeyChar -PageSize $pageSize
            if ($state.Action -eq 'Cancel') { return $null }
            if ($state.Action -eq 'Select') {
                $indexes = @(Get-SsmcMenuFilteredIndex -Items $Items -Filter $state.Filter)
                return $Items[$indexes[$state.Cursor]].Value
            }
        }
    } finally {
        [Console]::CursorVisible = $cursorVisible
        [Console]::SetCursorPosition(0, $origin + $lineCount)
    }
}

function Show-SsmcNumberMenu {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items
    )
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host (' [{0}] {1}' -f ($i + 1), $Items[$i].Label)
    }
    while ($true) {
        $answer = Read-Host "番号を入力してください (1-$($Items.Count), q:終了)"
        if ($answer -eq 'q') { return $null }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Items.Count) {
            return $Items[$number - 1].Value
        }
    }
}

function Read-SsmcConfirmation {
    param([Parameter(Mandatory)][string]$Message)
    $answer = Read-Host "$Message [y/N]"
    return ($answer -match '^(y|yes)$')
}
#endregion
```

- [ ] **Step 4: BOM を付けてテストを実行し、成功を確認する**

`lib\SsmcMenu.psm1` と `tests\SsmcMenu.Tests.ps1` に BOM 付与コマンドを実行する。
テスト実行（7）: `tests`
テスト実行（5.1）: `tests`
Expected: 全件 PASS。

- [ ] **Step 5: コミットする**

```powershell
git add lib/SsmcMenu.psm1 tests/SsmcMenu.Tests.ps1
git commit -m "feat: add arrow-key selection menu" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: 入口 `ssmc.ps1`・`ssmc.bat`・`ssmc.shared.json` と結合確認

**Files:**
- Create: `ssmc.ps1`
- Create: `ssmc.bat`
- Create: `ssmc.shared.json`

**Interfaces:**
- Consumes: Task 1〜8 のすべての公開関数
- Produces: 利用者向けの CLI（設計書 §4 の仕様）

- [ ] **Step 1: `ssmc.shared.json` を作る**

```json
{
  "version": 1,
  "defaults": {
    "region": "ap-northeast-1",
    "credentialTtlMinutes": 60
  },
  "environments": {
    "dev":  { "displayName": "開発", "roleArn": "arn:aws:iam::111111111111:role/Operator" },
    "stg":  { "displayName": "検証", "roleArn": "arn:aws:iam::222222222222:role/Operator" },
    "prod": { "displayName": "本番", "roleArn": "arn:aws:iam::333333333333:role/Operator" }
  },
  "presets": {}
}
```

アカウント ID とロール名はサンプルの値である。Step 8 の手動確認の前に、利用者が実際の値に置き換える。

- [ ] **Step 2: `ssmc.ps1` を作る**

```powershell
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
Import-Module (Join-Path $PSScriptRoot 'lib\SsmcCore.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\SsmcMenu.psm1') -Force

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
            # 本番への誤接続を防ぐため、1 件に決まっても確認する
            $selected = $candidates[0]
            if (-not (Read-SsmcConfirmation -Message "$(Get-SsmcInstanceDisplayName $selected) ($($selected.InstanceId)) に接続しますか？")) { return }
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
```

- [ ] **Step 3: `ssmc.bat` を作る**

```bat
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssmc.ps1" %*
set "SSMC_EXIT=%ERRORLEVEL%"
if not "%SSMC_EXIT%"=="0" pause
exit /b %SSMC_EXIT%
```

- [ ] **Step 4: `ssmc.ps1` に BOM を付け、全テストを実行する**

`ssmc.ps1` に BOM 付与コマンドを実行する。
テスト実行（7）: `tests`
テスト実行（5.1）: `tests`
Expected: 全件 PASS（Encoding のテストに `ssmc.ps1` が加わる）。

- [ ] **Step 5: ヘルプの動作を確認する（AWS 不要）**

```powershell
pwsh -NoProfile -File .\ssmc.ps1 --help; "exit=$LASTEXITCODE"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& .\ssmc.ps1 --help; 'exit=' + `$LASTEXITCODE"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ssmc.ps1 -?
cmd /c "ssmc.bat /?"
```

Expected:
- 1・2・4 行目: 「使い方: ssmc ...」と環境一覧（dev / stg / prod）、「プリセット: （なし）」が表示され、`exit=0`。4 行目は終了コード 0 なので `pause` しない。
- 3 行目: コメントベースヘルプ（SYNOPSIS・SYNTAX 等）が表示される。

- [ ] **Step 6: 異常系の動作を確認する（AWS 不要）**

```powershell
cmd /c "ssmc.bat no-such-preset < NUL"; "exit=$LASTEXITCODE"
```

Expected: 「プリセット 'no-such-preset' が見つかりません。」と表示され、`exit=1`。終了コードが 0 以外なので `pause` が実行される（`< NUL` によりすぐ抜ける）。Session Manager Plugin がない PC では、先に「Session Manager Plugin が見つかりません。…」「処理を終了します。」と表示されて `exit=1` になる。どちらも期待どおりの動作である。

- [ ] **Step 7: コミットする**

```powershell
git add ssmc.ps1 ssmc.bat ssmc.shared.json
git commit -m "feat: add ssmc entry point, launcher and shared config" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 8: 実環境での手動確認（利用者と一緒に実施）**

前提として、`ssmc.shared.json` を実際のアカウント ID とロール ARN に置き換え、Session Manager Plugin をインストールしておく。

設計書 §8.2 のチェックリストを、上から順に実施する。

- [ ] 初回起動で `loginProfile` を入力し、`%APPDATA%\ssmc\ssmc.user.json` に保存される
- [ ] ログインが切れた状態で起動すると `aws login` が実行され、そのまま続行できる
- [ ] MFA を誤入力すると再入力でき、3 回誤ると終了する（終了コード 2）
- [ ] 2 回目の接続でキャッシュが使われ、MFA の入力を求められない
- [ ] TTL を過ぎると、再び MFA の入力を求められる（`credentialTtlMinutes` を 15 にして確認）
- [ ] 接続先の OS 上で Run As のユーザーとしてログインしている（`whoami`）
- [ ] 矢印キー選択と絞り込みが Windows Terminal と conhost の両方で動く
- [ ] PowerShell ISE では番号入力方式に切り替わる
- [ ] Session Manager Plugin がない環境では、案内を表示して終了する
- [ ] プリセットのショートカット（`ssmc.bat prod-web01`）をダブルクリックして接続できる
- [ ] ポートフォワード（インスタンス自身／別ホスト経由）で、別のアプリから接続できる
- [ ] ローカルポートが使用中だと、MFA 入力の前に案内を表示して終了する
- [ ] `ssmc --help` / `ssmc -?` / `ssmc.bat --help` でヘルプが表示される（設定ファイルがない状態でも表示される）
- [ ] PowerShell 5.1 と 7 の両方で上記が動く
- [ ] 終了後、呼び出し元の PowerShell に AWS の環境変数が残っていない（`Get-ChildItem env:AWS_*`）

不具合が見つかったら、superpowers:systematic-debugging に沿って原因を特定し、再現するテストを追加してから修正する。
