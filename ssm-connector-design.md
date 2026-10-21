# SSM Connector 設計書

- 作成日: 2026-10-21
- 対象: AWS SSM Session Manager 接続自動化スクリプト（Windows / PowerShell）

---

## 1. 概要

### 1.1 背景

- **認証基盤の制約**
  - AWS Organizations が利用できず、IAM Identity Center (SSO) による権限委任が行えない。
  - 利用者は各アカウントの IAM ユーザー（アクセスキー非保持）で、初期認証はブラウザベースの `aws login --profile <profile>` を使用する。このコマンドでプロファイル自体も作成される。
  - 作業時は各環境（開発・検証・本番等）の IAM ロールへ AssumeRole（スイッチロール）する。
- **接続方式とセキュリティ要件**
  - EC2 への接続には SSM Session Manager を使用する。
  - Session Manager Run As が有効化されており、AssumeRole 時にセッションタグ `SSMSessionRunAs=<IAMユーザー名>` を付与することが必須。
  - スイッチ元 IAM ユーザーには MFA が強制されている。

### 1.2 目的

- 「ブラウザログイン確認 → MFA 入力 → セッションタグ付き AssumeRole → 一時クレデンシャル設定 → サーバー指定 → SSM セッション開始」を半自動化する。
- 次の 2 種類の利用者がどちらもストレスなく使えるようにする。
  - **初見・不定期ユーザー**: サーバー一覧から対話的に選んで接続する。
  - **定常運用者**: 決まったサーバーへ最短手数（ショートカットのダブルクリック等）で接続する。

### 1.3 前提となる環境上の事実

| 項目 | 内容 |
|---|---|
| MFA デバイス名 | IAM ユーザー名と同一。シリアルは `arn:aws:iam::<Account>:mfa/<UserName>` |
| セッションタグ | キー `SSMSessionRunAs`（固定）、値 = IAM ユーザー名 |
| ロールセッション名 | IAM ユーザー名（検証スクリプトでの実績に合わせる） |
| ロール権限 | `ec2:DescribeInstances` は付与済み（実績あり）。`ssm:DescribeInstanceInformation` は任意 |
| 信頼ポリシー | `sts:AssumeRole` と `sts:TagSession` の許可が必要 |

---

## 2. 方針・決定事項

| 項目 | 決定内容 |
|---|---|
| 実装方式 | PowerShell で AWS CLI v2 をラップする |
| 対応バージョン | Windows PowerShell 5.1 と PowerShell 7 のどちらでも動作すること |
| 文字コード | `.ps1` / `.psm1` は UTF-8 (BOM 付き) で保存する（5.1 の文字化け対策） |
| 必須の外部ツール | AWS CLI v2（`aws login` 対応版）、Session Manager Plugin |
| サーバー一覧 | AssumeRole 後に API で動的に取得する。running のインスタンスをすべて表示し、SSM の状態を横に添える |
| 最短接続 | プリセット名を引数で指定する（`ssmc prod-web01`） |
| 一時クレデンシャル | DPAPI で暗号化した専用キャッシュに保存し、有効期限内は再利用する |
| TTL | 全体で 1 つの値（既定 60 分）。AssumeRole の `--duration-seconds` にも同じ値を指定する |
| セッション種別 | シェル接続とポートフォワード |
| 設定 | 共通設定（チーム配布）と個人設定の 2 層 |
| 選択 UI | 矢印キーで選択し、文字入力で絞り込む |

### 2.1 対象外（今回は実装しない）

- ポートフォワード開始後のクライアントアプリ（mstsc 等）の自動起動
- 環境ごとの TTL 設定
- ファイルへのログ出力
- `~/.aws/credentials` へのクレデンシャル書き出し

---

## 3. 全体構成

```
ssm-connector/
├─ ssmc.ps1                  # エントリポイント（引数解析 → モード振り分け）
├─ ssmc.bat                  # ダブルクリック／ショートカット用ラッパー
├─ ssmc.shared.json          # 共通設定（環境定義・共通プリセット）
├─ lib/
│   ├─ SsmcCore.psm1         # aws ラッパー・事前チェック・設定・認証・キャッシュ・一覧取得・接続
│   └─ SsmcMenu.psm1         # 矢印キー選択 UI（AWS に依存しない汎用部品）
├─ tests/                    # Pester 5
└─ ssm-connector-design.md   # 本書
```

個人設定は `%APPDATA%\ssmc\ssmc.user.json` に、キャッシュは `%LOCALAPPDATA%\ssmc\cache\` に置く。

### 3.1 各ファイルの責務

| ファイル | 責務 | 依存先 |
|---|---|---|
| `ssmc.ps1` | 引数を解析し、§3.2 の流れに沿って Core と Menu の関数を呼ぶ。終了コードを決める | SsmcCore, SsmcMenu |
| `lib/SsmcCore.psm1` | AWS とのやり取りと、それを支える処理をまとめる（下表） | なし |
| `lib/SsmcMenu.psm1` | 選択 UI。キー入力に対する状態遷移は純粋関数とし、描画とは分ける | なし |

`SsmcCore.psm1` は `#region` で次のように区切る。

| region | 内容 |
|---|---|
| AwsCli | `Invoke-Aws`：`aws` を実行し、終了コード・stdout・stderr を回収して JSON を解析する。エラーを分類する |
| Prereq | 必須ツールと共通設定の存在確認 |
| Config | 設定の読み込み・マージ・検証、プリセットの解決、`loginProfile` の初回保存 |
| CredCache | 暗号化した保存・読み出し、有効期限の判定、削除 |
| Auth | ログイン確認、MFA 入力、AssumeRole。キャッシュがあれば利用する |
| Inventory | `describe-instances` と `describe-instance-information` を呼び、結果を結合して並べ替える |
| Session | `start-session` の組み立てと実行、ローカルポートの空き確認 |

### 3.2 処理の流れ

1. 事前チェックを行う（§5.1）。
2. 設定を読み込み、引数からプリセット・環境・接続先を解決する。
3. 環境が決まっていなければ、環境選択メニューを表示する。
4. 対象ロールのキャッシュが有効なら、ステップ 7 へ進む。
5. ログインを確認する。ログインが切れていれば `aws login` を実行する（§5.2）。
6. MFA コードを入力してもらい、タグ付き AssumeRole を実行して、結果をキャッシュに保存する。
7. 一時クレデンシャルを環境変数に設定する。
8. 接続先が決まっていなければ、一覧を取得してサーバー選択メニューを表示する。
9. `start-session` を実行する。
10. 終了時に環境変数を元に戻す。

---

## 4. 利用方法（コマンドライン仕様）

```
ssmc [[-Preset] <名前>] [-Env <環境キー>] [-Target <Name または InstanceId>]
     [-LocalPort <n> -RemotePort <n> [-RemoteHost <host>]]
     [-NoCache] [-ClearCache] [-Verbose] [-Help]
```

| 用途 | 例 | 動作 |
|---|---|---|
| 対話モード | `ssmc` | 環境を選び、サーバーを選んでシェル接続する |
| プリセット | `ssmc prod-web01` | MFA を入力するだけで接続する（キャッシュが有効なら入力も不要） |
| 環境だけ指定 | `ssmc -Env prod` | サーバーをメニューで選ぶ |
| 接続先も指定 | `ssmc -Env prod -Target web01` | 該当が 1 件なら確認のうえ接続し、複数件ならメニューを出す |
| ポートフォワード | `ssmc -Env prod -LocalPort 15432 -RemotePort 5432 -RemoteHost mydb.xxx` | 接続先（踏み台）をメニューで選んでから転送を開始する |
| キャッシュを使わない | `ssmc prod-web01 -NoCache` | 必ず MFA から取り直す |
| キャッシュを削除 | `ssmc -ClearCache` | キャッシュをすべて削除して終了する |
| ヘルプ | `ssmc --help` | 使い方と、定義済みの環境・プリセット一覧を表示する（§4.1） |

- 対話モードは常にシェル接続とする。ポートフォワードはプリセットか引数で指定する。
- `ssmc.bat` は `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssmc.ps1" %*` を実行する。終了コードが 0 以外のときだけ `pause` する。
- 定常運用者は、`ssmc.bat prod-web01` を実行するショートカットを作り、ダブルクリックで使う。

### 4.1 ヘルプ

ヘルプは次の 2 つの仕組みで提供する。

1. **コメントベースヘルプ**: `ssmc.ps1` の先頭に `.SYNOPSIS` / `.DESCRIPTION` / `.PARAMETER` / `.EXAMPLE` を記述する。`ssmc -?` や `Get-Help .\ssmc.ps1 -Detailed` で表示される。
2. **独自ヘルプ**: `-Help` スイッチ、またはプリセット名（第 1 位置引数）が `--help` / `-h` / `/?` / `help` のいずれかである場合に表示する。PowerShell では `--help` がプリセット名として受け取られるため、入口でこの値を判定する。

独自ヘルプの表示例:

```
使い方: ssmc [プリセット名] [-Env <環境>] [-Target <Name|InstanceId>]
            [-LocalPort <n> -RemotePort <n> [-RemoteHost <host>]]
            [-NoCache] [-ClearCache] [-Verbose] [-Help]

例:
  ssmc                       対話モードで環境とサーバーを選んで接続
  ssmc prod-web01            プリセットで接続
  ssmc -Env prod -Target web01
  ssmc -ClearCache           キャッシュを削除

環境:
  dev   開発
  prod  本番

プリセット:
  prod-web01  本番 / web01 / shell
  prod-db     本番 / bastion01 / portForward 15432 -> mydb.xxxx...:5432
```

- 環境とプリセットの一覧は、マージ後の設定（共通設定と個人設定）から作る。
- 設定ファイルが読めない場合は一覧を省き、使い方だけを表示する（ヘルプ表示ではエラーにしない）。
- ヘルプ表示時は、事前チェック（§5.1）を行わない。
- 終了コードは 0 とする。

---

## 5. 機能詳細

### 5.1 事前チェック

どれか 1 つでも満たさなければ案内を表示して、終了コード 1 で終了する。

| チェック | 判定方法 | 失敗時の案内 |
|---|---|---|
| AWS CLI v2 | `Get-Command aws` で存在を確認し、`aws --version` で `aws login` に対応するバージョンか確認する | インストール／更新手順の URL |
| Session Manager Plugin | `Get-Command session-manager-plugin`。PATH になければ `C:\Program Files\Amazon\SessionManagerPlugin\bin\` も確認する | インストール手順の URL と「処理を終了します」 |
| 共通設定ファイル | 存在すること、JSON として正しいこと、必須項目がそろっていること | 問題のあるファイル名と項目名 |

### 5.2 認証

1. `aws sts get-caller-identity --profile <loginProfile>` を実行する。
   - 失敗した場合（プロファイルがない／ログインが切れている）は「ブラウザでログインします」と表示して `aws login --profile <loginProfile>` を実行し、もう一度確認する。2 回目も失敗したら終了コード 2 で終了する。
2. 結果の `Arn` から末尾をユーザー名として取り出し、`Account` と組み合わせて MFA シリアル `arn:aws:iam::<Account>:mfa/<UserName>` を組み立てる。
3. MFA コードを入力してもらう。6 桁の数字でなければその場で再入力させる。入力は画面に表示しない。
4. 次のコマンドで AssumeRole する。

   ```
   aws sts assume-role --profile <loginProfile>
     --role-arn <roleArn>
     --role-session-name <UserName>
     --serial-number arn:aws:iam::<Account>:mfa/<UserName>
     --token-code <code>
     --duration-seconds <credentialTtlMinutes × 60>
     --tags "Key=SSMSessionRunAs,Value=<UserName>"
   ```

   - MFA コードが誤っている、または期限切れの場合は再入力させる（最大 3 回）。
   - それ以外の AccessDenied（信頼ポリシーの不備、TagSession の権限不足など）は、内容を表示して終了コード 2 で終了する。
   - `--duration-seconds` がロールの最大セッション時間を超えて拒否された場合は、TTL の設定を見直すよう案内する。

### 5.3 一時クレデンシャルのキャッシュ

- **保存先**: `%LOCALAPPDATA%\ssmc\cache\<roleArn の SHA-256 先頭 16 文字>.dat`。環境名ではなくロール ARN から作ることで、設定変更後に別ロールのクレデンシャルを誤って使うことを防ぐ。
- **中身**: `{AccessKeyId, SecretAccessKey, SessionToken, Expiration, RoleArn, UserName}` を JSON にし、`ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString` で暗号化する（DPAPI、CurrentUser スコープ）。
- **再利用の条件**: 復号でき、`RoleArn` が一致し、有効期限まで 5 分以上残っていること。条件を満たさないキャッシュは削除して、MFA から取り直す。
- `Expiration` は文字列のまま保存し、読み出し時に `[DateTimeOffset]` へ変換する（PowerShell 7 の `ConvertFrom-Json` は日時文字列を自動で DateTime に変換するため、5.1 と動作を揃える）。
- `-NoCache` でキャッシュを使わず、`-ClearCache` でキャッシュをすべて削除する。

### 5.4 クレデンシャルの受け渡し

- `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY`、`AWS_SESSION_TOKEN`、`AWS_REGION` をプロセスの環境変数に設定し、`AWS_PROFILE` を一時的に外してから `aws ec2` / `aws ssm` を実行する。
- `try/finally` で、実行前の値に必ず戻す（未設定だった変数は削除する）。既存の PowerShell から `.\ssmc.ps1` を直接実行しても、呼び出し元にクレデンシャルが残らないようにするため。

### 5.5 サーバー一覧の取得

1. `aws ec2 describe-instances --filters Name=instance-state-name,Values=running` で、Name タグ・InstanceId・PrivateIp を取得する。
2. `aws ssm describe-instance-information` で、各インスタンスの `PingStatus` を取得する。
   - 結果に含まれないインスタンスは「未登録」とする。
   - この API が AccessDenied になった場合は状態を表示しないだけにして、処理は続ける。
3. Name の昇順で並べる。Name タグがないものは末尾に置き、`<Nameタグなし>` と表示する。
4. running のインスタンスが 0 件なら、その旨を表示して終了コード 3 で終了する。

- aws コマンドの結果は `Out-String | ConvertFrom-Json` で解析し、1 件だけの場合も `@()` で配列に揃える。

### 5.6 選択メニュー

```
[本番] 接続先を選択  ↑↓:移動  Enter:決定  文字入力:絞り込み  Esc:終了
 絞り込み: web_
   app01    i-0abc...  10.0.1.10  Online
 > web01    i-0def...  10.0.1.20  Online
   web02    i-0456...  10.0.1.21  ConnectionLost
```

| 操作 | 動作 |
|---|---|
| ↑ / ↓ | カーソルを移動する |
| PageUp / PageDown | 1 画面分移動する |
| Enter | 決定する |
| Esc | 終了する（終了コード 0） |
| 文字入力 / Backspace | その場で絞り込む（Name・InstanceId・IP の部分一致、大文字小文字を区別しない） |

- 画面の高さを超える場合は、カーソル位置に合わせてスクロールする。
- 状態が Online 以外の行は灰色で表示する。選ぶことはでき、その場合は接続前に警告して確認する。
- 実装は `[Console]::ReadKey($true)` でキー入力を受け取り、`[Console]::SetCursorPosition` でメニュー部分だけを描き直す。
- 「キー入力 → 状態（絞り込み文字列、カーソル位置、表示開始位置）の更新」は純粋関数として実装し、描画とは分ける。
- キー入力を受け取れない環境（`$Host.Name -ne 'ConsoleHost'`、または `[Console]::IsInputRedirected`）では、番号入力方式に自動で切り替える。
- 環境選択メニューでも同じ部品を使う。
- 候補が 1 件だけでも自動では接続せず、確認する（本番への誤接続を防ぐため）。

### 5.7 接続実行

| 種別 | コマンド |
|---|---|
| シェル | `aws ssm start-session --target <id>` |
| ポートフォワード（インスタンス自身） | `aws ssm start-session --target <id> --document-name AWS-StartPortForwardingSession --parameters portNumber=<p>,localPortNumber=<lp>` |
| ポートフォワード（別ホスト経由） | `aws ssm start-session --target <id> --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters host=<h>,portNumber=<p>,localPortNumber=<lp>` |

- `--parameters` は JSON ではなく shorthand 構文で渡す。PowerShell 5.1 はネイティブコマンドに渡す引数の `"` を正しく扱えないため。
- ポートフォワードの前に、`System.Net.Sockets.TcpListener` でローカルポートが空いているか確認する。使用中なら案内を表示して終了コード 3 で終了する。
- ポートフォワード開始時は次のように案内する。
  - `localhost:<lp>` で待ち受け中であること
  - 接続は別のアプリ（mstsc、ブラウザ、DB クライアント等）から行うこと
  - このウィンドウを閉じる、または Ctrl+C を押すとトンネルが切れること
- プリセットの `target.name` に該当するインスタンスが 0 件ならエラー（終了コード 3）とし、複数件ならそれらに絞ったメニューを表示する。
- セッションが終わったら、スクリプトも終了する。

---

## 6. 設定ファイル

### 6.1 共通設定 `ssmc.shared.json`（`ssmc.ps1` と同じフォルダ）

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

| 項目 | 必須 | 説明 |
|---|---|---|
| `version` | ○ | スキーマのバージョン。現在は `1` |
| `defaults.region` | ○ | 既定のリージョン |
| `defaults.credentialTtlMinutes` | ○ | 一時クレデンシャルの有効時間（分）。15 以上 |
| `environments.<key>.displayName` | ○ | メニューに表示する名前 |
| `environments.<key>.roleArn` | ○ | スイッチ先ロールの ARN |
| `environments.<key>.region` | − | その環境のリージョン（省略時は `defaults.region`） |
| `presets` | − | チームで共有するプリセット（形式は §6.3） |

### 6.2 個人設定 `%APPDATA%\ssmc\ssmc.user.json`

```json
{
  "loginProfile": "my-login",
  "credentialTtlMinutes": 30,
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
}
```

| 項目 | 必須 | 説明 |
|---|---|---|
| `loginProfile` | ○ | `aws login --profile` に渡すプロファイル名。未設定なら初回起動時に入力してもらい保存する |
| `credentialTtlMinutes` | − | 共通設定の値を上書きする |
| `presets` | − | 個人のプリセット |

### 6.3 プリセットの形式

| 項目 | 必須 | 説明 |
|---|---|---|
| `env` | ○ | `environments` のキー |
| `target.name` / `target.instanceId` | ○ | どちらか一方。インスタンスの入れ替えに強い `name` を推奨 |
| `type` | − | `shell`（既定）または `portForward` |
| `remotePort` | portForward 時 ○ | 転送先のポート |
| `localPort` | portForward 時 ○ | ローカルの待ち受けポート |
| `remoteHost` | − | 指定すると、インスタンスを経由してこのホストへ転送する |

### 6.4 マージ規則

- 優先順位（後のものほど優先）: `defaults` → 環境ごとの設定 → 個人設定。
- `environments` と `presets` はキーごとにマージし、同じキーがあれば個人設定を優先する。

---

## 7. エラー処理とログ

### 7.1 終了コード

| コード | 意味 |
|---|---|
| 0 | 正常終了（利用者が Esc で終了した場合を含む） |
| 1 | 事前チェックまたは設定のエラー |
| 2 | 認証の失敗 |
| 3 | 接続の失敗（対象なし、ポート使用中、start-session の失敗） |

### 7.2 aws コマンドの実行ラッパー（`Invoke-Aws`）

- すべての aws コマンドはこのラッパーを通して呼び出す。
- `$LASTEXITCODE` と stderr を回収し、stderr の内容から次のように分類して、利用者向けのメッセージに置き換える。
  - ログイン切れ／プロファイルなし
  - MFA コードの誤り
  - AccessDenied
  - その他（元のメッセージをそのまま表示する）
- `start-session` は対話的に実行するため、出力を取り込まずに直接実行し、終了コードだけを確認する。

### 7.3 秘密情報とログ

- MFA コードとクレデンシャルは画面にもログにも出力しない。
- `-Verbose` 指定時だけ、実行した aws コマンドを表示する。その際 `--token-code` の値は伏せ字にする。
- ファイルへのログ出力は行わない（作業の監査は SSM 側のログで担保されているため）。

---

## 8. テスト

### 8.1 自動テスト（Pester 5）

`Invoke-Aws` を `Mock -ModuleName SsmcCore` で差し替え、AWS に接続せずに次をテストする。テストファイルは `tests/SsmcCore.Tests.ps1` と `tests/SsmcMenu.Tests.ps1` の 2 つとする。

| 対象（region / ファイル） | 主な観点 |
|---|---|
| Config | マージの優先順位、必須項目がない場合のエラー、プリセットの解決 |
| CredCache | 保存して読み出せること、期限切れ・残り 5 分未満・RoleArn 不一致のときに再利用しないこと |
| Auth | MFA シリアルの組み立て、assume-role の引数、MFA 誤りでの再入力、AccessDenied での終了 |
| AwsCli | stderr の分類 |
| Inventory | 2 つの API 結果の結合、並び順、1 件だけの場合の配列化、SSM API が AccessDenied のときも続行すること |
| Menu | キー入力に対する状態遷移（移動、ページ送り、絞り込み、スクロール） |
| Session | 種別ごとの引数の組み立て、ポート使用中の判定 |

### 8.2 手動確認チェックリスト（実 AWS 環境）

- [ ] 初回起動で `loginProfile` を入力し、個人設定に保存される
- [ ] ログインが切れた状態で起動すると `aws login` が実行され、そのまま続行できる
- [ ] MFA を誤入力すると再入力でき、3 回誤ると終了する
- [ ] 2 回目の接続でキャッシュが使われ、MFA の入力を求められない
- [ ] TTL を過ぎると、再び MFA の入力を求められる
- [ ] 接続先の OS 上で Run As のユーザーとしてログインしている
- [ ] 矢印キー選択と絞り込みが Windows Terminal と conhost の両方で動く
- [ ] PowerShell ISE では番号入力方式に切り替わる
- [ ] Session Manager Plugin がない環境では、案内を表示して終了する
- [ ] プリセットのショートカットをダブルクリックして接続できる
- [ ] `ssmc --help` / `ssmc -?` / `ssmc.bat --help` でヘルプが表示される（設定ファイルがない状態でも表示される）
- [ ] ポートフォワード（インスタンス自身／別ホスト経由）で、別のアプリから接続できる
- [ ] ローカルポートが使用中だと、案内を表示して終了する
- [ ] PowerShell 5.1 と 7 の両方で上記が動く
- [ ] 終了後、呼び出し元の PowerShell に AWS の環境変数が残っていない
