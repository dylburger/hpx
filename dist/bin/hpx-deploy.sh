#!/bin/bash
set -u
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPTNAME=$(basename "${BASH_SOURCE[0]}")
LUSER=$(whoami)
RELEASEBUCKET=${RELEASEBUCKET:-"hpx-release-us-west-2"}

usage() {
    cat 1>&2 <<EOF
cf-deploy build 1.0.0

USAGE:
  [VARIABLE=<string> ...] hpx-deploy [OPTIONS] <stack-name>

ARGUMENTS:
  stack-name                    Name of the stack you wish to create or update.
                                Defaults to "hpx-<AWS REGION>"

OPTIONS:
  -V,--version <version>        Select the version of HPX to deploy.
                                Defaults to the latest version.

  -c,--custom  <S3URI>          Deploy HPX from a custom s3 location.
                                Set to the root of your custom HPX instance.
                                (--version is ignored)
                                EXAMPLE: 's3://hpx-dev-us-west-2/master'

  -x,--execute                  If deploying to an existing stack, immediately
                                execute any changes. If not set, a changeset is
                                created for review before execution.

ENVIRONMENT VARIABLES:
  VPC_CIDR                      The IP block to use when creating VPC resources.
                                Example: '10.0.55/24' or 'fc00:100::/32'
                                Defaults to 172.16.0.0/16

  REDSHIFT_PASSWORD (required)  The Redshift master password to set.

  REDSHIFT_USER     (optional)  The Redshift root user to create.
                                Defaults to 'turbo'

  PREFIX   (optional)           The prefix to use when naming AWS resources.
                                Defaults to 'hpx'
EOF
}

main() {
  validate_environment_variables

  [ -z $(which aws) ] && err "AWS Cli not found!"
  REGION=$(aws configure get region)

  while [[ $# > 0 ]]; do
    case "$1" in
      -V|--version)
        VERSION=${2:-}
        [ -z $VERSION ] && err "(--version) Version string expected!"
        shift 2
        ;;
      -c|--custom)
        DIST=${2:-}
        [ -z $DIST ] && err "(--custom) S3 location expected!"
        shift 2
        ;;
      -x|--execute)
        EXECUTE_CHANGESET="TRUE"
        shift
        ;;
      *)
        STACKNAME=$@
        validate_stackname $STACKNAME
        shift $#
    esac
  done

  VERSION=${VERSION:-$(latest_version)}
  validate_version $VERSION

  DIST=${DIST:-"s3://$RELEASEBUCKET/$VERSION"}
  validate_s3uri $DIST
  DISTS3BUCKET=$(s3uri_bucket $DIST)
  DISTS3ROOT=$(s3uri_key $DIST)

  PREFIX=${PREFIX:-"hpx"}
  validate_prefix $PREFIX

  STACKNAME=${STACKNAME:-"$PREFIX-$REGION"}
  validate_stackname $STACKNAME

  REDSHIFT_USER=${REDSHIFT_USER:-"hpx"}
  validate_redshift_user $REDSHIFT_USER

  VPC_CIDR=${VPC_CIDR:-"172.31.0.0/16"}
  validate_ipv4_cidr $VPC_CIDR

  PARAMETERS=$(cat <<-EOF
  ParameterKey="Prefix",ParameterValue="$PREFIX"
  ParameterKey="DistS3Bucket",ParameterValue="$DISTS3BUCKET"
  ParameterKey="DistS3Root",ParameterValue="$DISTS3ROOT"
  ParameterKey="RedshiftUser",ParameterValue="$REDSHIFT_USER"
  ParameterKey="RedshiftPassword",ParameterValue="$REDSHIFT_PASSWORD"
  ParameterKey="VpcCidrBlock",ParameterValue="$VPC_CIDR"
EOF
)
  if ! aws cloudformation describe-stacks --stack-name $STACKNAME > /dev/null 2>&1; then
    info "Creating new stack: $STACKNAME"
    aws cloudformation create-stack \
      --capabilities CAPABILITY_NAMED_IAM \
      --stack-name "$STACKNAME" \
      --template-url "$(s3uri_to_s3url $DIST/cloudformation/hpx.yaml)" \
      --parameters $PARAMETERS
  else
    info "Creating changeset for existing stack: $STACKNAME"
    aws cloudformation create-change-set \
      --capabilities CAPABILITY_NAMED_IAM \
      --stack-name "$STACKNAME" \
      --template-url "$(s3uri_to_s3url $DIST/cloudformation/hpx.yaml)" \
      --change-set-name "$PREFIX-changeset-$LUSER-$REGION" \
      --parameters $PARAMETERS

    if [ ${EXECUTE_CHANGESET:-FALSE} = TRUE ]; then
      aws cloudformation execute-change-set \
        --change-set-name "$PREFIX-changeset-$LUSER-$REGION"
    fi
  fi


}

latest_version() {
  aws s3 cp s3://$RELEASEBUCKET/LATEST - 2> /dev/null
}

validate_version() {
  [[ ! $1 =~ ^[0-9]+\.[0-9]+(\.[0-9]+)*$ ]] && err "Invalid Version ($1). Version must match ^[0-9]+\.[0-9]+(\.[0-9]+)*$"
}

validate_stackname() {
  [ -z "$1" ] && err "Stack name must be set!"
  [[ ! "$1" =~ ^[a-zA-Z0-9._\-]{1,255}$ ]] && err "Invalid stack name ($1). Stackname must match ^[a-zA-Z0-9._\-]{1,255}$"
}

validate_s3uri() {
  [[ ! "$1" =~ ^s3://[a-zA-Z0-9.\-_]{1,255}/?.*$ ]] && err "Invalid S3URI ($1). S3URI must match ^s3://[a-zA-Z0-9.\-_]{1,255}/?.*$"
  ! aws s3 ls "$1" 2>&1 >/dev/null && err "Cannot access S3URI ($1)"
}

s3uri_to_s3url() {
  local awsregion=${REGION:-$(aws configure get region)}
  printf "https://s3-${awsregion}.amazonaws.com/${1:5}"
}

validate_prefix() {
  [[ ! "$1" =~ ^[a-zA-Z0-9]{1,16}$ ]] && err "Invalid prefix ($1). Prefix must match ^[a-zA-Z0-9]{1,16}$"
}

validate_redshift_user() {
  [ -z "$1" ] && err "Redshift user must be set!"
  [[ ! "$1" =~ ^[a-z]{1}[a-z0-9]{0,127}$ ]] && err "Invalid redshift user ($1). Redshift user must match ^[a-z]{1}[a-z0-9]{0,127}$"
}

validate_ipv4_cidr() {
  [[ ! "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(\/([0-9]|[1-2][0-9]|3[0-2]))?$ ]] && \
  err "Invalid CIDR ($1)"
}

s3uri_bucket() {
  local strip_prefix=${1:5}
  local as_array=(${strip_prefix/\// })
  printf ${as_array}
}

s3uri_key() {
  local strip_prefix=${1:5}
  local as_array=(${strip_prefix/\// })
  printf ${as_array[1]}
}

validate_environment_variables() {
  REQUIRED=(REDSHIFT_PASSWORD)
  for envvar in ${REQUIRED[@]}; do
    if [ -z "${!envvar:-}" ]; then
      err "Environment variable ${envvar} must be set!"
    fi
  done
}

info() {
  printf "[${SCRIPTNAME}] INFO: $1\n"
}

err() {
  printf "[${SCRIPTNAME}] ERROR: ${1:-Unknown Error!}\n"
  usage
  exit ${2:--1}
}

main "$@" || exit 1
