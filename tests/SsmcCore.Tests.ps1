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
