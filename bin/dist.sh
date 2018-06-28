#!/bin/bash -x
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HPXDIR=`dirname $SCRIPTDIR`

cd $HPXDIR
mkdir -p ./dist
[ -a "./dist/hpx.zip" ] && rm ./dist/hpx.zip

zip -r hpx . -x ./dist/\*
mv hpx.zip ./dist

aws s3 sync $HPXDIR s3://hpx-code-pipeline-repo-us-east-1/`git rev-parse --abbrev-ref HEAD` --delete