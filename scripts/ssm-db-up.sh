#!/usr/bin/env bash

# exit on error
set -eux

# s3://vcard-releases/accessman
PROJECT=accessman
S3_BUCKET=s3://vcard-releases/$PROJECT/

# must be run inside the project. this is a hack for codeship
if [ ! -z ${1+x} ]; then
  cd $1
fi

sh db/create-conf.sh ${DB_DRIVER} ${DB_OPEN} > db/dbconf.yml

PKG_NAME=`echo -e "$(tar -cf - db/migrations db/dbconf.yml | md5sum)" | tr -d '[[:space:]]'`
FULL_PKG_NAME=${PKG_NAME}db.tar.gz
S3_PKG_PATH=${S3_BUCKET}${FULL_PKG_NAME}

# Skipping if checksum was uploaded
if [ 0 -e $(aws s3 ls $S3_PKG_PATH | wc -l) ]; then
 echo "[Skipping] No Database change."
 exit 0
fi

# installed from s3://vcard-releases/_scripts/goose-deploy.sh
CMD_SSM='{"commands":["sh goose-deploy.sh '$PROJECT' '$S3_PKG_PATH'"],"executionTimeout":["3600"]}'

tar -czvf $FULL_PKG_NAME db/migrations db/dbconf.yml
aws s3 cp $FULL_PKG_NAME $S3_PKG_PATH
rm -rf $FULL_PKG_NAME

CMD_ID=`\
aws ssm send-command --document-name "AWS-RunShellScript" \
 --instance-ids "${AWS_SSM_INSTANCE}" \
 --comment "build: ${CI_BUILD_ID}; artifact: ${FULL_PKG_NAME}" \
 --parameters "$CMD_SSM" \
 --output text \
 --timeout-seconds 600 \
 --region ${AWS_DEFAULT_REGION} \
 --query "Command.CommandId"`

while true; do
 CMD_OUT=`\
  aws ssm list-command-invocations --command-id $CMD_ID --details \
  --output text --query "CommandInvocations[*].Status"`

 if [ "$CMD_OUT" != "Pending" ] && [ "$CMD_OUT" != "InProgress"  ]; then
  if [ "$CMD_OUT" != "Success" ]; then
    aws ssm list-command-invocations --command-id $CMD_ID --details \
     --output text --query "CommandInvocations[*].CommandPlugins[*].Output"
    exit 1
  fi
  break
 fi

 echo "[STATUS] $CMD_OUT ..."
 sleep 5s
done

echo "[STATUS] $CMD_OUT:"
aws ssm list-command-invocations --command-id $CMD_ID --details \
 --output text --query "CommandInvocations[*].CommandPlugins[*].Output"
