# ssmc — SSM Connector

AWS SSM Session Manager で EC2 に接続するまでの手順を半自動化する、Windows 用の PowerShell ツールです。

```
aws login のログイン確認 → MFA 入力 → セッションタグ付き AssumeRole → サーバー選択 → SSM セッション開始
```

- サーバーは一覧から矢印キーで選べます。文字を入力すると絞り込めます。
- よく使う接続先はプリセットとして登録でき、ショートカットのダブルクリックで接続できます。
- 一時的な認証情報は暗号化（DPAPI）して保存し、有効期限内は MFA の入力を省略します。
- シェル接続と、ポートフォワード（インスタンス自身、またはインスタンス経由で別ホストへ）に対応しています。

## 動作環境

| 必要なもの | 備考 |
|---|---|
| Windows PowerShell 5.1 または PowerShell 7 | どちらでも動作します |
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) 2.32.0 以上 | `aws login` を使うため |
| [Session Manager Plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) | |

起動時にこれらを確認し、足りないものがあればインストール先を案内して終了します。

## はじめて使うとき

1. このフォルダを任意の場所に置きます。
2. `ssmc.shared.json` に、接続する環境（ロール ARN）が設定されていることを確認します。通常は管理者が配布します（[設定ファイル](#設定ファイル)）。
3. `ssmc.bat` をダブルクリックするか、PowerShell で `.\ssmc.ps1` を実行します。
4. 初回だけ、`aws login` で使うプロファイル名を聞かれます。入力した名前は `%APPDATA%\ssmc\ssmc.user.json` に保存されます。
   プロファイルがまだない、またはログインが切れている場合は、自動で `aws login` が実行されてブラウザが開きます。
5. 環境を選び、MFA コードを入力し、サーバーを選ぶと接続します。

> どこからでも `ssmc` と打って起動したい場合は、このフォルダを環境変数 `PATH` に追加してください（`ssmc.bat` が呼ばれます）。

## 使い方

```
ssmc [プリセット名] [-Env <環境>] [-Target <Name|InstanceId>]
     [-LocalPort <n> -RemotePort <n> [-RemoteHost <host>]]
     [-NoCache] [-ClearCache] [-Verbose] [-Help]
```

| やりたいこと | 例 | 動作 |
|---|---|---|
| 対話的に選んで接続する | `ssmc` | 環境とサーバーをメニューで選び、シェル接続します |
| プリセットで接続する | `ssmc prod-web01` | 確認なしで接続します（キャッシュが有効なら MFA も不要） |
| 環境だけ指定する | `ssmc -Env prod` | サーバーをメニューで選びます |
| 接続先まで指定する | `ssmc -Env prod -Target web01` | 該当が 1 件なら確認なしで接続し、複数件ならメニューを出します |
| ポートフォワードする | `ssmc -Env prod -LocalPort 15432 -RemotePort 5432 -RemoteHost mydb.example.internal` | 経由するサーバー（踏み台）を選び、`localhost:15432` から転送します |
| MFA から取り直す | `ssmc prod-web01 -NoCache` | キャッシュを使いません |
| キャッシュを削除する | `ssmc -ClearCache` | 保存した認証情報をすべて削除します |
| 実行する aws コマンドを表示する | `ssmc -Verbose` | MFA コードは `******` で伏せられます |
| ヘルプを表示する | `ssmc --help` | 使い方と、定義済みの環境・プリセットの一覧を表示します |

- `-RemoteHost` を省略すると、選んだサーバー自身の `-RemotePort` へ転送します。
- `-Target` には Name タグまたはインスタンス ID を指定できます。
- 選んだサーバーの SSM の状態が `Online` 以外の場合は、接続前に確認します。

### メニューの操作

| キー | 動作 |
|---|---|
| ↑ / ↓、PageUp / PageDown | 移動 |
| 文字入力 / Backspace | 絞り込み（Name・インスタンス ID・IP の部分一致） |
| Enter | 決定 |
| Esc | 終了 |

PowerShell ISE など、キー入力を直接受け取れない環境では、番号を入力して選ぶ方式に自動で切り替わります（`q` で終了）。

### ポートフォワードの終了

ウィンドウを閉じるか、Ctrl+C を押すとトンネルが切れます。

`ssmc.bat` から起動した場合は、Ctrl+C の後に「バッチ ジョブを終了しますか (Y/N)?」（Terminate batch job）と表示されます。`Y` を押して閉じてください。これは cmd の動作で、トンネルは正しく切断されています。

### ショートカットで接続する

よく使う接続先は、プリセットを登録してショートカットを作ると、ダブルクリックだけで接続できます。

1. 個人設定（または共通設定）の `presets` にプリセットを追加します（[プリセットの書き方](#プリセットの書き方)）。
2. `ssmc.bat` のショートカットを作り、プロパティの「リンク先」の末尾にプリセット名を付けます。
   ```
   "C:\tools\ssm-connector\ssmc.bat" prod-web01
   ```

正常に終了したウィンドウはそのまま閉じます。エラーで終了した場合だけ、メッセージを読めるよう `pause` します。

## 設定ファイル

設定は 2 つのファイルに分かれていて、起動時にマージされます。同じキーがある場合は個人設定が優先されます。

| ファイル | 置き場所 | 内容 |
|---|---|---|
| 共通設定 `ssmc.shared.json` | `ssmc.ps1` と同じフォルダ | 環境の定義、チームで共有するプリセット。管理者が配布します |
| 個人設定 `ssmc.user.json` | `%APPDATA%\ssmc\` | ログインプロファイル名、個人のプリセット |

### 共通設定 `ssmc.shared.json`

```json
{
  "version": 1,
  "defaults": {
    "region": "ap-northeast-1",
    "credentialTtlMinutes": 60
  },
  "environments": {
    "dev":  { "displayName": "開発", "roleArn": "arn:aws:iam::111111111111:role/Operator" },
    "prod": { "displayName": "本番", "roleArn": "arn:aws:iam::333333333333:role/Operator", "region": "ap-northeast-1" }
  },
  "presets": {}
}
```

| 項目 | 必須 | 説明 |
|---|---|---|
| `version` | ○ | `1` |
| `defaults.region` | ○ | 既定のリージョン |
| `defaults.credentialTtlMinutes` | ○ | 一時的な認証情報の有効時間（分）。15 以上。ロールの最大セッション時間以下にしてください |
| `environments.<キー>.displayName` | ○ | メニューに表示する名前 |
| `environments.<キー>.roleArn` | ○ | スイッチ先のロール ARN |
| `environments.<キー>.region` | − | その環境のリージョン（省略時は `defaults.region`） |
| `presets` | − | チームで共有するプリセット |

### 個人設定 `%APPDATA%\ssmc\ssmc.user.json`

```json
{
  "loginProfile": "my-login",
  "credentialTtlMinutes": 30,
  "presets": {
    "prod-web01": { "env": "prod", "target": { "name": "web01" } }
  }
}
```

| 項目 | 必須 | 説明 |
|---|---|---|
| `loginProfile` | ○ | `aws login --profile` に渡すプロファイル名。初回起動時に入力すると自動で保存されます |
| `credentialTtlMinutes` | − | 共通設定の値を上書きします |
| `presets` | − | 個人のプリセット |

### プリセットの書き方

```json
"presets": {
  "prod-web01": { "env": "prod", "target": { "name": "web01" } },
  "prod-db": {
    "env": "prod",
    "target": { "name": "bastion01" },
    "type": "portForward",
    "remoteHost": "mydb.xxxx.ap-northeast-1.rds.amazonaws.com",
    "remotePort": 5432,
    "localPort": 15432
  }
}
```

| 項目 | 必須 | 説明 |
|---|---|---|
| `env` | ○ | `environments` のキー |
| `target.name` または `target.instanceId` | ○ | どちらか一方。インスタンスを作り直しても使える `name`（Name タグ）がお勧めです |
| `type` | − | `shell`（既定）または `portForward` |
| `remotePort` / `localPort` | portForward のとき ○ | 転送先のポートと、ローカルで待ち受けるポート |
| `remoteHost` | − | 指定すると、インスタンスを経由してこのホストへ転送します |

## 終了コード

| コード | 意味 |
|---|---|
| 0 | 正常終了（Esc やキャンセルで終了した場合を含む） |
| 1 | 事前チェックまたは設定のエラー |
| 2 | 認証の失敗（ログイン、MFA、AssumeRole） |
| 3 | 接続の失敗（対象のサーバーがない、ローカルポートが使用中、セッションの開始に失敗） |

## 困ったとき

| 症状 | 対処 |
|---|---|
| MFA コードが通らない | MFA デバイス名が IAM ユーザー名と同じである必要があります（[AWS 側の準備](#aws-側の準備管理者向け)）。3 回失敗すると終了コード 2 で終了します |
| ロールへのスイッチに失敗する（AccessDenied） | ロールの信頼ポリシーで `sts:AssumeRole` と `sts:TagSession` が許可されているか、管理者に確認してください |
| `DurationSeconds` に関するエラーが出る | `credentialTtlMinutes` がロールの最大セッション時間を超えています。値を小さくしてください |
| 古い認証情報が使われる | `ssmc -NoCache` で取り直すか、`ssmc -ClearCache` で削除してください |
| サーバーの状態が「未登録」になる | そのインスタンスが SSM に登録されていません（SSM Agent、インスタンスプロファイル、ネットワークを確認） |
| 原因が分からない | `-Verbose` を付けて実行すると、実行した aws コマンドが表示されます |

`powershell.exe -File .\ssmc.ps1 -?` は Windows PowerShell 5.1 の仕様で何も表示されません。ヘルプは `ssmc --help`、詳細は `Get-Help .\ssmc.ps1 -Detailed` で見てください。

## AWS 側の準備（管理者向け）

ssmc は次の構成を前提にしています。

- 利用者は IAM ユーザーで、`aws login`（ブラウザでのサインイン）を使います。アクセスキーは不要です。
- IAM ユーザーには MFA が必須で、**MFA デバイス名は IAM ユーザー名と同じ**にします。ssmc は MFA の ARN を `arn:aws:iam::<アカウント>:mfa/<ユーザー名>` と組み立てます。
- 各環境のロールへ AssumeRole するときに、セッションタグ `SSMSessionRunAs=<IAM ユーザー名>` を付けます。ロールセッション名も IAM ユーザー名です。
- Session Manager の Run As を有効にし、接続先の OS には IAM ユーザー名と同じ名前のユーザーを作っておきます。

### 環境ロールの信頼ポリシー（例）

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::<アカウント>:user/<ユーザー名>" },
      "Action": "sts:AssumeRole",
      "Condition": { "Bool": { "aws:MultiFactorAuthPresent": "true" } }
    },
    {
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::<アカウント>:user/<ユーザー名>" },
      "Action": "sts:TagSession",
      "Condition": {
        "Bool": { "aws:MultiFactorAuthPresent": "true" },
        "StringEquals": { "aws:RequestTag/SSMSessionRunAs": "${aws:username}" },
        "ForAllValues:StringEquals": { "aws:TagKeys": ["SSMSessionRunAs"] }
      }
    }
  ]
}
```

`aws:RequestTag/SSMSessionRunAs` を `${aws:username}` に限定すると、ほかのユーザーの名前で Run As することを防げます。

### 環境ロールの権限（例）

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["ec2:DescribeInstances", "ssm:DescribeInstanceInformation"], "Resource": "*" },
    {
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": [
        "arn:aws:ec2:<リージョン>:<アカウント>:instance/*",
        "arn:aws:ssm:<リージョン>:<アカウント>:document/SSM-SessionManagerRunShell",
        "arn:aws:ssm:<リージョン>::document/AWS-StartPortForwardingSession",
        "arn:aws:ssm:<リージョン>::document/AWS-StartPortForwardingSessionToRemoteHost"
      ]
    },
    { "Effect": "Allow", "Action": ["ssm:TerminateSession", "ssm:ResumeSession"], "Resource": "arn:aws:ssm:*:<アカウント>:session/*" }
  ]
}
```

`ssm:DescribeInstanceInformation` はなくても動きます。その場合、一覧に SSM の状態が表示されません。

### 接続先の EC2

- インスタンスプロファイルに `AmazonSSMManagedInstanceCore` を付けます。
- SSM のエンドポイントへ外向きに通信できるようにします（パブリック IP、NAT、または VPC エンドポイント）。インバウンドのポートを開ける必要はありません。
- OS に、IAM ユーザー名と同じ名前のユーザーを作ります。

## 開発者向け

```
ssm-connector/
├─ ssmc.ps1                # 入口。引数の解析、全体の流れ、終了コード
├─ ssmc.bat                # ダブルクリック／ショートカット用のラッパー
├─ ssmc.shared.json        # 共通設定（サンプル）
├─ lib/
│   ├─ SsmcCore.psm1       # aws の呼び出し、事前チェック、設定、キャッシュ、認証、一覧、接続、ヘルプ
│   └─ SsmcMenu.psm1       # 矢印キーの選択 UI、番号入力方式、y/N 確認
├─ tests/                  # Pester のテスト
└─ ssm-connector-design.md # 設計書
```

- `.ps1` / `.psm1` は **UTF-8（BOM 付き）** で保存してください。Windows PowerShell 5.1 での文字化けを防ぐためで、`tests/Encoding.Tests.ps1` が検査します。
- 三項演算子、`??`、`?.`、`ConvertFrom-Json -AsHashtable` など、PowerShell 7 だけの機能は使わないでください。
- AWS の呼び出しはすべて `Invoke-Aws` / `Invoke-AwsInteractive` を通し、テストではこれをモックします。

テストには Pester 5.5 以上が必要です。PowerShell 7 と 5.1 の両方で実行してください。

```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests -Output Detailed"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests -Output Detailed"
```
