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
