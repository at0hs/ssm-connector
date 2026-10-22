#!/usr/bin/env bash
# ssmc 実機確認環境の操作（Git Bash で実行）
# 使い方: bash test-env.sh up|down|status|destroy
#   up      EC2 2 台を作る（初回はロールなども一緒に作る）。ssmc.shared.test.json がなければ作る
#   down    EC2 だけ削除する（ロール・SG・Session Manager の設定は残す）
#   status  スタックと EC2・SSM の状態を表示する
#   destroy スタックごと全部削除する
set -euo pipefail
export MSYS_NO_PATHCONV=1
export AWS_CLI_FILE_ENCODING=UTF-8
cd "$(dirname "$0")"
PROFILE=${SSMC_TEST_PROFILE:-ssmc-admin}
REGION=ap-northeast-1
STACK=ssmc-test
P="--profile $PROFILE --region $REGION"

deploy() {
  local vpc subnet
  vpc=$(aws ec2 describe-vpcs $P --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
  subnet=$(aws ec2 describe-subnets $P --filters Name=vpc-id,Values="$vpc" Name=availability-zone,Values=${REGION}a \
    --query 'Subnets[0].SubnetId' --output text)
  aws cloudformation deploy $P --stack-name $STACK --template-file template.yaml \
    --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND --no-fail-on-empty-changeset --tags Project=ssmc-test \
    --parameter-overrides Instances="$1" VpcId="$vpc" SubnetId="$subnet"
}

# ssmc が優先して読むテスト用の共通設定を作る（既にあれば手を加えない）
write_config() {
  local out=../ssmc.shared.test.json account
  [ -f "$out" ] && return 0
  account=$(aws sts get-caller-identity $P --query Account --output text)
  cat > "$out" <<JSON
{
  "version": 1,
  "defaults": {
    "region": "$REGION",
    "credentialTtlMinutes": 60
  },
  "environments": {
    "dev":  { "displayName": "開発", "roleArn": "arn:aws:iam::$account:role/ssmc-dev" },
    "stg":  { "displayName": "検証", "roleArn": "arn:aws:iam::$account:role/ssmc-stg" },
    "prod": { "displayName": "本番", "roleArn": "arn:aws:iam::$account:role/ssmc-prod" }
  },
  "presets": {
    "dev-web01": { "env": "dev", "target": { "name": "ssmc-web01" } }
  }
}
JSON
  echo "ssmc.shared.test.json を作成しました。"
}

status() {
  aws cloudformation describe-stacks $P --stack-name $STACK \
    --query 'Stacks[0].[StackStatus,Outputs[].[OutputKey,OutputValue]]' --output text
  aws ec2 describe-instances $P --filters Name=tag:aws:cloudformation:stack-name,Values=$STACK \
    Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,InstanceId,State.Name,PrivateIpAddress]" --output table
  aws ssm describe-instance-information $P --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output table
}

case "${1:-}" in
  up)      deploy true; write_config; status; echo "SSM への登録まで数分かかります。" ;;
  down)    deploy false; status ;;
  status)  status ;;
  destroy) aws cloudformation delete-stack $P --stack-name $STACK
           aws cloudformation wait stack-delete-complete $P --stack-name $STACK && echo "deleted" ;;
  *)       sed -n '2,7p' "$0"; exit 1 ;;
esac
