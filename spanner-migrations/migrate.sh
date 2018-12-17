#!/bin/bash

# This script:
# -> Transforms .dml.sql files using their adjacent .json token file
# -> Applies DDL and DML migrations

# Exit when a command fails
set -o errexit
# Error when unset variables are found
set -o nounset

log ()
{
  set +o nounset
  if [ "${TEST_MODE}" == true ]; then
    echo "${SCRIPT_NAME} -> TEST MODE -> ${1}"
  else
    echo "${SCRIPT_NAME} -> ${1}"
  fi
  set -o nounset
}

on_exit ()
{
  echo
  log "Cleaning up..."
  find . -name "*.tmp.*" | xargs rm -f
  find . -name "*.tmp" | xargs rm -f
}
trap on_exit EXIT INT TERM

exit_with_code ()
{
  on_exit

  echo
  log "END `date '+%Y-%m-%d %H:%M:%S'`"
  exit ${1}
}

SCRIPT_DIR="$( cd "$(dirname "${0}")" ; pwd -P )"
SCRIPT_DIR_NAME=${SCRIPT_DIR##*/}
SCRIPT_NAME=`basename ${0}`
SCRIPT_NAME_NO_SUFFIX=${SCRIPT_NAME%.*}

WHOAMI=`whoami`
log "START `date '+%Y-%m-%d %H:%M:%S'`"
log "ENTER as user ${WHOAMI}..."
echo

if [ $# -lt 4 ]; then
  log "Usage: migrate ENV GCP_PROJECT_ID SPANNER_INSTANCE_ID SPANNER_DATABASE_ID"
  exit_with_code 2

  else
    export ENV=${1}
    export GCP_PROJECT_ID=${2}
    export SPANNER_INSTANCE_ID=${3}
    export SPANNER_DATABASE_ID=${4}
fi

TEST_MODE=false
TEST_MIGRATIONS="./008_bar_create_indexes.ddl.up.sql
./001_foo_create.ddl.up.sql
./007_foo_bar_load.dml.sql
./002_bar_create.ddl.up.sql
./006_foo_create_indexes.ddl.up.sql
./003_foo_load.all.dml.sql
./004_foo_load.dev.dml.sql
./005_bar_load.dev.dml.sql
./004_foo_load.uat.dml.sql"
TEST_LAST_MIGRATION_DDL="Version
2"
TEST_LAST_MIGRATION_DML="Version
1"
TEST_DML="SELECT * from
SchemaMigrations;

SELECT Version from SchemaMigrations;
"

echo
log "TEST_MODE=${TEST_MODE}"
log "ENV=${ENV}"
log "GCP_PROJECT_ID=${GCP_PROJECT_ID}"
log "SPANNER_INSTANCE_ID=${SPANNER_INSTANCE_ID}"
log "SPANNER_DATABASE_ID=${SPANNER_DATABASE_ID}"
echo

# -> FUNCTIONS ----------------------------------------
fn_replace_tokens ()
{
  echo
  log "ENTER fn_replace_tokens..."

  TOKEN_FILE=$(basename ${1} .tmp.dml.sql).json

  if [ -f ${TOKEN_FILE} ]; then
    log "Replacing tokens using token file ${TOKEN_FILE}"

    KEYS=()
    while IFS='' read -r line; do
      KEYS+=("$line")
    done < <(jq -r 'keys[]' ${TOKEN_FILE})

    for KEY in ${KEYS[@]}; do
      VALUE=$(jq -r --arg key "${KEY}" '.[$key]' ${TOKEN_FILE})
      log "Replacing '${KEY}' with '${VALUE}'"
      TMP_FILE=${1}.tmp
      sed "s/@${KEY}@/${VALUE}/g" "${1}" > "${TMP_FILE}" && mv ${TMP_FILE} ${1}
    done
  else
    log "Skipping replacing tokens, no token file ${TOKEN_FILE}"
  fi

  log "LEAVE fn_replace_tokens..."
}

fn_process_tmpl ()
{
  echo
  log "ENTER fn_process_tmpl..."

  DML_FILE=$(basename ${1} .dml.sql).tmp.dml.sql

  log "Will stage DML ${1} to ${DML_FILE} prior to replacing any tokens"

  if [ "${TEST_MODE}" == true ]; then
    log "Skipping"
  else
    cp -f ${1} ${DML_FILE}
    fn_replace_tokens ${DML_FILE}
  fi

  log "LEAVE fn_process_tmpl..."
}

fn_count_migrations ()
{
  echo
  log "ENTER fn_count_migrations..."

  if [ "${TEST_MODE}" == true ]; then
    MIGRATIONS=${TEST_MIGRATIONS}
  else
    MIGRATIONS=$(find . -name "*.ddl.up.sql" -o -name "*.all.dml.sql" -o -name "*.${ENV}.dml.sql")
  fi

  log "Processing unsorted ${MIGRATIONS}"

  # Apply 'basename' THEN apply 'sort' THEN convert newlines to spaces
  # -> 'sort' must come last
  # -> 'xargs -n 1' because 'basename'/'sort' cannot take more than one item as param
  MIGRATIONS=$(echo ${MIGRATIONS} | xargs -n1 basename | xargs -n1 | sort -g | xargs)

  log "MIGRATIONS=${MIGRATIONS}"

  MIGRATION_COUNT=$(echo "${MIGRATIONS}" | wc -w | tr -d '[:space:]')
  if [ -z "${MIGRATION_COUNT}" ]; then
    log "No migrations available"
    MIGRATION_COUNT=0
  fi
  log "MIGRATION_COUNT=${MIGRATION_COUNT}"

  MIGRATIONS_DDL=""
  MIGRATIONS_DML=""

  for i in ${MIGRATIONS}
  do
    log "  Checking ${i}"
    if [ ${i: -11} == ".ddl.up.sql" ]; then
      MIGRATIONS_DDL+="${i} "
    elif [ ${i: -8} == ".dml.sql" ]; then
      MIGRATIONS_DML+="${i} "
    else
      log "  Skipping ${i}"
    fi
  done

  if [ -z "${MIGRATIONS_DDL}" ]; then
    log "No DDL migrations available"
    MIGRATION_COUNT_DDL=0
  fi
  if [ -z "${MIGRATIONS_DML}" ]; then
    log "No DML migrations available"
    MIGRATION_COUNT_DML=0
  fi

  MIGRATION_COUNT_DDL=$(echo "${MIGRATIONS_DDL}" | wc -w | tr -d '[:space:]')
  MIGRATION_COUNT_DML=$(echo "${MIGRATIONS_DML}" | wc -w | tr -d '[:space:]')

  log "MIGRATIONS_DDL=${MIGRATIONS_DDL}"
  log "MIGRATION_COUNT_DDL=${MIGRATION_COUNT_DDL}"

  log "MIGRATIONS_DML=${MIGRATIONS_DML}"
  log "MIGRATION_COUNT_DML=${MIGRATION_COUNT_DML}"

  log "LEAVE fn_count_migrations..."
}

fn_last_migration ()
{
  echo
  log "ENTER fn_last_migration..."

  if [ "${TEST_MODE}" == true ]; then
    LAST_MIGRATION_DDL=$(echo "${TEST_LAST_MIGRATION_DDL}" | awk 'END{print $NF}')
    LAST_MIGRATION_DML=$(echo "${TEST_LAST_MIGRATION_DML}" | awk 'END{print $NF}')

  else
    log "Inspecting table SchemaMigrations for last revision"
    LAST_MIGRATION_DDL=$(gcloud spanner databases execute-sql ${SPANNER_DATABASE_ID} --instance=${SPANNER_INSTANCE_ID} --sql="SELECT Version from SchemaMigrations" | awk 'END{print $NF}')

    log "Inspecting table DataMigrations for last revision"
    LAST_MIGRATION_DML=$(gcloud spanner databases execute-sql ${SPANNER_DATABASE_ID} --instance=${SPANNER_INSTANCE_ID} --sql="SELECT Version from DataMigrations" | awk 'END{print $NF}')
  fi

  set +o nounset
  if [ -z "${LAST_MIGRATION_DDL}" ]; then
    log "No DDL migrations applied"
    LAST_MIGRATION_DDL=0
  fi
  if [ -z "${LAST_MIGRATION_DML}" ]; then
    log "No DML migrations applied"
    LAST_MIGRATION_DML=0
  fi
  set -o nounset

  log "LAST_MIGRATION_DDL=${LAST_MIGRATION_DDL}"
  log "LAST_MIGRATION_DML=${LAST_MIGRATION_DML}"

  if [ ${LAST_MIGRATION_DDL} -gt ${LAST_MIGRATION_DML} ]; then
    LAST_MIGRATION=${LAST_MIGRATION_DDL}
  else
    LAST_MIGRATION=${LAST_MIGRATION_DML}
  fi
  log "LAST_MIGRATION=${LAST_MIGRATION}"

  log "LEAVE fn_last_migration..."
}

fn_outstanding_migrations ()
{
  echo
  log "ENTER fn_outstanding_migrations..."

  OUTSTANDING_MIGRATIONS=""
  OUTSTANDING_MIGRATIONS_COUNT=0

  for i in ${MIGRATIONS_DDL}
  do
    log "  Checking DDL ${i}"
    n=$(echo ${i} | cut -c1-3 | awk 'END{print $NF}')
    log "    with prefix ${n}"
    if [ ${n} -gt ${LAST_MIGRATION} ]; then
      OUTSTANDING_MIGRATIONS+="${i} "
      OUTSTANDING_MIGRATIONS_COUNT=$((OUTSTANDING_MIGRATIONS_COUNT+1))
    fi
  done

  for i in ${MIGRATIONS_DML}
  do
    log "  Checking DML ${i}"
    n=$(echo ${i} | cut -c1-3 | awk 'END{print $NF}')
    log "    with prefix ${n}"
    if [ ${n} -gt ${LAST_MIGRATION} ]; then
      OUTSTANDING_MIGRATIONS+="${i} "
      OUTSTANDING_MIGRATIONS_COUNT=$((OUTSTANDING_MIGRATIONS_COUNT+1))
    fi
  done

  OUTSTANDING_MIGRATIONS=$(echo ${OUTSTANDING_MIGRATIONS} | tr " " "\n" | sort | tr "\n" " ")

  log "OUTSTANDING_MIGRATIONS=${OUTSTANDING_MIGRATIONS}"
  log "OUTSTANDING_MIGRATIONS_COUNT=${OUTSTANDING_MIGRATIONS_COUNT}"

  log "LEAVE fn_outstanding_migrations..."
}

fn_apply_all_ddl ()
{
  echo
  log "ENTER fn_apply_all_ddl..."

  if [ "${TEST_MODE}" == true ]; then
    log "Skipping"
  else
    migrate -path . -database spanner://projects/${GCP_PROJECT_ID}/instances/${SPANNER_INSTANCE_ID}/databases/${SPANNER_DATABASE_ID} up
  fi

  log "LEAVE fn_apply_all_ddl..."
}

fn_apply_ddl ()
{
  echo
  log "ENTER fn_apply_ddl..."

  log "Applying revision ${2} from file ${1}"

  if [ "${TEST_MODE}" == true ]; then
    log "Skipping"
  else
    migrate -path . -database spanner://projects/${GCP_PROJECT_ID}/instances/${SPANNER_INSTANCE_ID}/databases/${SPANNER_DATABASE_ID} up 1
  fi

  log "LEAVE fn_apply_ddl..."
}

fn_apply_dml ()
{
  echo
  log "ENTER fn_apply_dml..."

  log "Applying revision ${2} from file ${1}"

  if [ "${TEST_MODE}" == true ]; then
    echo "${TEST_DML}" > "${1}.tmp"
    awk '{printf "%s ",$0} END {print ""}' "${1}.tmp" | awk -F';' '{$1=$1}1' OFS=';\n' > "${1}.tmp.tmp"
    while IFS= read -r line; do
      if [[ -z "${line// }" ]]; then
        log "  Skipping empty line..."
      else
        log "Skipping ${line}"
      fi
    done < "${1}.tmp.tmp"
    rm -f "${1}.tmp" "${1}.tmp.tmp"
  else
    awk '{printf "%s ",$0} END {print ""}' "${1}" | awk -F';' '{$1=$1}1' OFS=';\n' > "${1}.tmp"
    while IFS= read -r line; do
      if [[ -z "${line// }" ]]; then
        log "  Skipping empty line..."
      else
        log "  Running: ${line}"
        gcloud spanner databases execute-sql ${SPANNER_DATABASE_ID} --instance=${SPANNER_INSTANCE_ID} --sql="${line}"
      fi
    done < "${1}.tmp"
    rm -f "${1}.tmp"

    if [ ${2} -ne ${LAST_MIGRATION_DML} ]; then
      log "Setting revision ${2} in DataMigrations for completed DML migration ${1}"
      gcloud spanner databases execute-sql ${SPANNER_DATABASE_ID} --instance=${SPANNER_INSTANCE_ID} --sql="INSERT INTO DataMigrations (Version) VALUES (${2})"
    else
      # There can be multiple DML changesets in a revision
      log "Skipping setting revision ${2} in DataMigrations for completed DML migration ${1} since it is part of a changeset"
    fi

    if [ ${LAST_MIGRATION_DML} -gt 0 ]; then
      if [ ${LAST_MIGRATION_DML} -ne ${2} ]; then
        log "Removing revision ${LAST_MIGRATION_DML} in DataMigrations for superseded DML migration"
        gcloud spanner databases execute-sql ${SPANNER_DATABASE_ID} --instance=${SPANNER_INSTANCE_ID} --sql="DELETE FROM DataMigrations WHERE Version=${LAST_MIGRATION_DML}"
      else
        # There can be multiple DML changesets in a revision
        log "Skipping removing revision ${2} in DataMigrations for completed DML migration ${1} since it is part of a changeset"
      fi
    fi

    # The last DML revision must be recorded because there can be multiple DML changesets in a revision
    LAST_MIGRATION_DML=${2}
  fi

  log "LEAVE fn_apply_dml..."
}

fn_apply_migrations ()
{
  echo
  log "ENTER fn_apply_migrations..."

  log "OUTSTANDING_MIGRATIONS=${OUTSTANDING_MIGRATIONS}"

  for i in ${OUTSTANDING_MIGRATIONS}
  do
    log "  Processing ${i}"
    n=$(echo ${i} | cut -c1-3 | awk 'END{print $NF}')
    log "    with prefix ${n}"

    if [ ${i: -8} == ".dml.sql" ]; then
      fn_process_tmpl ${i}
      DML_FILE=$(basename ${i} .dml.sql).tmp.dml.sql
      fn_apply_dml ${DML_FILE} ${n}
    else
      fn_apply_ddl ${i} ${n}
    fi
  done

  log "LEAVE fn_apply_migrations..."
}
# <- FUNCTIONS ----------------------------------------

fn_count_migrations

if [ ${MIGRATION_COUNT} -eq 0 ]; then
  echo
  log "No migrations available"
  exit_with_code 0
fi

if [ ${MIGRATION_COUNT_DML} -eq 0 ]; then
  echo
  log "No DML migrations available"
  fn_apply_all_ddl
  exit_with_code 0
fi

fn_last_migration

fn_outstanding_migrations

if [ ${OUTSTANDING_MIGRATIONS_COUNT} -eq 0 ]; then
  echo
  log "No migrations needed"
  exit_with_code 0
fi

fn_apply_migrations

exit_with_code 0
