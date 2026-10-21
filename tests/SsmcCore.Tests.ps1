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
