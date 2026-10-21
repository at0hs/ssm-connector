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
