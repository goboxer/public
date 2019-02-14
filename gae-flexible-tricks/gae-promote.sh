#!/bin/bash

# This script:
# -> Promotes AppEngine Flexible environment deployments cleaning up prior deployments

fn_exit_on_error ()
{
  # Exit script if you try to use an uninitialized variable.
  set -o nounset

  # Exit script if a statement returns a non-true return value.
  set -o errexit

  # Use the error status of the first failure, rather than that of the last item in a pipeline.
  set -o pipefail
}

fn_exit_on_error_off ()
{
  set +o nounset
  set +o errexit
  set +o pipefail
}

log ()
{
  fn_exit_on_error_off
  if [ "${TEST_MODE}" == true ]; then
    echo "${SCRIPT_NAME} -> TEST MODE -> ${1}"
  else
    echo "${SCRIPT_NAME} -> ${1}"
  fi
  fn_exit_on_error
}

on_exit ()
{
  echo
  log "Cleaning up..."
}
trap on_exit EXIT INT TERM

exit_with_code ()
{
  on_exit

  echo
  log "END `date '+%Y-%m-%d %H:%M:%S'`"
  exit ${1}
}

fn_exit_on_error

SCRIPT_DIR="$( cd "$(dirname "${0}")" ; pwd -P )"
SCRIPT_DIR_NAME=${SCRIPT_DIR##*/}
SCRIPT_NAME=`basename ${0}`
SCRIPT_NAME_NO_SUFFIX=${SCRIPT_NAME%.*}

WHOAMI=`whoami`
log "START `date '+%Y-%m-%d %H:%M:%S'`"
log "ENTER as user ${WHOAMI}..."
echo

if [ $# -lt 3 ]; then
  log "Usage: gae-promote ENV GCP_PROJECT_ID CIRCLE_PROJECT_REPONAME"
  exit_with_code 2

  else
    export ENV=${1}
    export GCP_PROJECT_ID=${2}
    export CIRCLE_PROJECT_REPONAME=${3}
fi

TEST_MODE=false

echo
log "TEST_MODE=${TEST_MODE}"
log "ENV=${ENV}"
log "GCP_PROJECT_ID=${GCP_PROJECT_ID}"
log "CIRCLE_PROJECT_REPONAME=${CIRCLE_PROJECT_REPONAME}"
echo

# -> FUNCTIONS ----------------------------------------
# Usage: fn_gae_version_as_timestamp <GAE_VERSION_NUMBER> <Name of variable to fill with timestamp>
fn_gae_version_as_timestamp ()
{
  log "Parameter 1 - <GAE_VERSION_NUMBER>=${1}"
  log "Parameter 2 - Variable which will be set to a TIMESTAMP representation of <GAE_VERSION_NUMBER>=${2}"

  log "Parsing GAE version '${1}' as date..."

  local YEAR=${1:0:4}
  local MONTH=${1:4:2}
  local DAY=${1:6:2}
  local HOURS=${1:9:2}
  local MINUTES=${1:11:2}
  local SECONDS=${1:13:2}

  log "YEAR=${YEAR}"
  log "MONTH=${MONTH}"
  log "DAY=${DAY}"
  log "HOURS=${HOURS}"
  log "MINUTES=${MINUTES}"
  log "SECONDS=${SECONDS}"

  if [ -z "${YEAR}" ] || [ -z "${MONTH}" ] || [ -z "${DAY}" ] || [ -z "${HOURS}" ] || [ -z "${MINUTES}" ] || [ -z "${SECONDS}" ]; then
    log "'${1}' not recognized as timestamp so cleanup should be skipped"

  else
    local TIMESTAMP_AS_STRING="${YEAR}-${MONTH}-${DAY} ${HOURS}:${MINUTES}:${SECONDS}"
    log "TIMESTAMP_AS_STRING=${TIMESTAMP_AS_STRING}"

    local TIMESTAMP_AS_DATE=$(date -d "${TIMESTAMP_AS_STRING}" "+%s")
    log "TIMESTAMP_AS_DATE=${TIMESTAMP_AS_DATE}"

    eval "${2}='${TIMESTAMP_AS_DATE}'"
  fi
}
# <- FUNCTIONS ----------------------------------------

# >---------- DEPLOYING
echo
log "Deploying container to GAE..."
# DO NOT ADD flags '--verbosity=debug --log-http' to this command, it will break 'jq' processing of the resulting deployment metadata captured in 'gcloud-app-deploy.log'
gcloud app deploy --bucket gs://${GCP_PROJECT_ID}-lc-api-stage-appengine --no-promote --no-stop-previous-version --format=json --quiet > gcloud-app-deploy.log
log "Deployed container to GAE"

ls -al
cat gcloud-app-deploy.log

if [ ${ENV} == "prd" ]; then
  # Only in prd do we need to wait in order to guard again 503s errors
  # -> It is OK to have 503s errors in dev and uat in order that the client learns to handle them
  # -> In all environments the clean up to stop the previous deployment provides enough time to ensure integration tests will not fail due to 503s
  DEPLOYMENT_WAIT_TIME=180
  log "Waiting for '${DEPLOYMENT_WAIT_TIME}' seconds for GAE deployment to become available see https://cloud.google.com/appengine/docs/flexible/known-issues"
  sleep ${DEPLOYMENT_WAIT_TIME}
  log "Finished waiting for GAE deployment to become available"

else
  log "Skipping wait in environment '${ENV}'"
fi
# <----------

# >---------- PROMOTING
echo
GAE_DEPLOYED_VERSION=$(jq -r '.versions | .[0] | .id' gcloud-app-deploy.log)
log "Promoting GAE version '${GAE_DEPLOYED_VERSION}'..."
gcloud app services set-traffic ${CIRCLE_PROJECT_REPONAME} --splits ${GAE_DEPLOYED_VERSION}=1 --quiet
log "Promoted GAE version '${GAE_DEPLOYED_VERSION}'"
# <----------

# >---------- GATHERING METADATA FOR CLEANUP
echo
GAE_DEPLOYED_VERSION_AS_TIMESTAMP=""
fn_gae_version_as_timestamp ${GAE_DEPLOYED_VERSION} GAE_DEPLOYED_VERSION_AS_TIMESTAMP

SHOULD_ATTEMPT_CLEANUP=true
if [ -z "${GAE_DEPLOYED_VERSION_AS_TIMESTAMP}" ]; then
  log "'${GAE_DEPLOYED_VERSION}' not recognized as timestamp so cleanup should be skipped"
  SHOULD_ATTEMPT_CLEANUP=false

else
  log "GAE_DEPLOYED_VERSION_AS_TIMESTAMP=${GAE_DEPLOYED_VERSION_AS_TIMESTAMP}"
fi
log "SHOULD_ATTEMPT_CLEANUP=${SHOULD_ATTEMPT_CLEANUP}"
# <----------

# >---------- CLEANING UP
echo
if [ ${SHOULD_ATTEMPT_CLEANUP} == true ]; then
  log "Attempting cleanup..."

  echo
  log "Looking for previous GAE redundant versions to stop i.e. those running with no traffic..."

  log "Listing GAE versions..."
  gcloud app services list --filter="${CIRCLE_PROJECT_REPONAME}" --format=json > gcloud-app-services-list.log
  log "Listed GAE versions"

  ls -al
  cat gcloud-app-services-list.log

  # >---------- CLEANING UP - Stopping PREVIOUS 'SERVING' versions with no traffic
  GAE_SERVING_NO_TRAFFIC_VERSIONS=$(jq '.[0] | .versions | .[] | {id: .id, date: .last_deployed_time.datetime, servingStatus: .version.servingStatus, traffic_split: .traffic_split} | select(.traffic_split | contains(0)) | select(.servingStatus | contains("SERVING"))' gcloud-app-services-list.log)
  log "GAE_SERVING_NO_TRAFFIC_VERSIONS=${GAE_SERVING_NO_TRAFFIC_VERSIONS}"

  GAE_SERVING_NO_TRAFFIC_VERSION_IDS=$(echo ${GAE_SERVING_NO_TRAFFIC_VERSIONS} | jq -r '.id')
  log "GAE_SERVING_NO_TRAFFIC_VERSION_IDS=${GAE_SERVING_NO_TRAFFIC_VERSION_IDS}"

  GAE_REDUNDANT_SERVING_NO_TRAFFIC_VERSION_IDS=""
  for i in ${GAE_SERVING_NO_TRAFFIC_VERSION_IDS}
  do
    echo
    log "Checking if GAE version '${i}' was deployed before this version '${GAE_DEPLOYED_VERSION}'"

    I_AS_TIMESTAMP=""
    fn_gae_version_as_timestamp ${i} I_AS_TIMESTAMP

    if [ ${I_AS_TIMESTAMP} -le "${GAE_DEPLOYED_VERSION_AS_TIMESTAMP}" ]; then
      log "GAE version '${i}' was deployed at '${I_AS_TIMESTAMP}' which is BEFORE this version '${GAE_DEPLOYED_VERSION}' deployed at '${GAE_DEPLOYED_VERSION_AS_TIMESTAMP}'"
      GAE_REDUNDANT_SERVING_NO_TRAFFIC_VERSION_IDS="${GAE_REDUNDANT_SERVING_NO_TRAFFIC_VERSION_IDS} ${i}"

    else
      log "Ignoring version '${i}' deployed at '${I_AS_TIMESTAMP}' which is AFTER this version '${GAE_DEPLOYED_VERSION}' deployed at '${GAE_DEPLOYED_VERSION_AS_TIMESTAMP}'"
    fi
  done

  if [ `echo ${GAE_REDUNDANT_SERVING_NO_TRAFFIC_VERSION_IDS} | wc -w` -eq 0 ]; then
    log "Skipping stop of previous GAE redundant versions -> There are no GAE redundant versions to stop i.e. those running with no traffic..."

  else
    log "Stopping previous GAE redundant versions i.e. those running with no traffic..."
    gcloud app versions stop --service ${CIRCLE_PROJECT_REPONAME} ${GAE_REDUNDANT_SERVING_NO_TRAFFIC_VERSION_IDS} --quiet
    log "Stopped previous GAE redundant versions i.e. those running with no traffic"
  fi

  # >---------- CLEANING UP - Deleting PREVIOUS 'STOPPED' versions with no traffic
  if [ ${ENV} == "prd" ]; then
    log "Running in environment '${ENV}' and will SKIP the delete of GAE redundant versions that can be deleted i.e. those PRIOR and 'STOPPED' with no traffic..."

  else
    echo
    log "Looking for previous GAE redundant versions to delete i.e. those stopped with no traffic..."

    log "Listing GAE versions..."
    gcloud app services list --filter="${CIRCLE_PROJECT_REPONAME}" --format=json > gcloud-app-services-list.log
    log "Listed GAE versions"

    GAE_STOPPED_NO_TRAFFIC_VERSIONS=$(jq '.[0] | .versions | .[] | {id: .id, date: .last_deployed_time.datetime, servingStatus: .version.servingStatus, traffic_split: .traffic_split} | select(.traffic_split | contains(0)) | select(.servingStatus | contains("STOPPED"))' gcloud-app-services-list.log)
    log "GAE_STOPPED_NO_TRAFFIC_VERSIONS=${GAE_STOPPED_NO_TRAFFIC_VERSIONS}"

    GAE_REDUNDANT_STOPPED_VERSION_IDS=$(echo ${GAE_STOPPED_NO_TRAFFIC_VERSIONS} | jq -r '.id')
    log "GAE_REDUNDANT_STOPPED_VERSION_IDS=${GAE_REDUNDANT_STOPPED_VERSION_IDS}"

    GAE_REDUNDANT_STOPPED_NO_TRAFFIC_VERSION_IDS=""
    for i in ${GAE_REDUNDANT_STOPPED_VERSION_IDS}
    do
      echo
      log "Checking if GAE version '${i}' was deployed before this version '${GAE_DEPLOYED_VERSION}'"

      I_AS_TIMESTAMP=""
      fn_gae_version_as_timestamp ${i} I_AS_TIMESTAMP

      if [ ${I_AS_TIMESTAMP} -le "${GAE_DEPLOYED_VERSION_AS_TIMESTAMP}" ]; then
        log "GAE version '${i}' was deployed at '${I_AS_TIMESTAMP}' which is BEFORE this version '${GAE_DEPLOYED_VERSION}' deployed at '${GAE_DEPLOYED_VERSION_AS_TIMESTAMP}'"
        GAE_REDUNDANT_STOPPED_NO_TRAFFIC_VERSION_IDS="${GAE_REDUNDANT_STOPPED_NO_TRAFFIC_VERSION_IDS} ${i}"

      else
        log "Ignoring version '${i}' deployed at '${I_AS_TIMESTAMP}' which is AFTER this version '${GAE_DEPLOYED_VERSION}' deployed at '${GAE_DEPLOYED_VERSION_AS_TIMESTAMP}'"
      fi
    done

    if [ `echo ${GAE_REDUNDANT_STOPPED_NO_TRAFFIC_VERSION_IDS} | wc -w` -le 1 ]; then
      log "Skipping delete of previous GAE redundant versions i.e. those stopped with no traffic -> There are less than two previous GAE redundant versions to delete and we want to keep at least one"

    else
      log "Sorting previous GAE redundant versions..."
      SORTED_GAE_REDUNDANT_STOPPED_NO_TRAFFIC_VERSION_IDS=$(echo ${GAE_REDUNDANT_STOPPED_NO_TRAFFIC_VERSION_IDS} | tr " " "\n" | sort -r -s |  tr "\n" " ")
      log "SORTED_GAE_REDUNDANT_STOPPED_NO_TRAFFIC_VERSION_IDS=${SORTED_GAE_REDUNDANT_STOPPED_NO_TRAFFIC_VERSION_IDS}"

      log "Splitting list of previous GAE redundant versions, we don't want to delete the latest in case it needs to be used for a manual rollback..."
      SPLIT_GAE_REDUNDANT_STOPPED_NO_TRAFFIC_VERSION_IDS=("${SORTED_GAE_REDUNDANT_STOPPED_NO_TRAFFIC_VERSION_IDS[@]:1}")
      log "SPLIT_GAE_REDUNDANT_STOPPED_NO_TRAFFIC_VERSION_IDS=${SPLIT_GAE_REDUNDANT_STOPPED_NO_TRAFFIC_VERSION_IDS}"

      log "Deleting all except the latest previous GAE redundant versions i.e. those stopped with no traffic..."
      gcloud app versions delete --service ${CIRCLE_PROJECT_REPONAME} ${SPLIT_GAE_REDUNDANT_STOPPED_NO_TRAFFIC_VERSION_IDS} --quiet
      log "Deleted all except the latest previous GAE redundant versions i.e. those stopped with no traffic"
    fi
  fi

  else
    log "Skipping cleanup"
fi
# <----------
