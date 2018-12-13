#!/bin/bash

# This script:
# -> Applies DDL and DML migrations

# Exit when a command fails
set -o errexit
# Error when unset variables are found
set -o nounset

log ()
{
  echo "${SCRIPT_NAME} -> ${1}"
}

cleanup_and_exit_with_code ()
{
  find . -name "*.tmp.*" | xargs rm -f

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
  cleanup_and_exit_with_code 2

  else
    export ENV=${1}
    export GCP_PROJECT_ID=${2}
    export SPANNER_INSTANCE_ID=${3}
    export SPANNER_DATABASE_ID=${4}
fi

TEST_MODE=false
TEST_MIGRATIONS="./005_foo_bar_create_indexes.up.sql
./001_foo_create.up.sql
./006_foo_bar_load.dml.sql
./004_foo_bar_create.up.sql
./002_foo_create_indexes.up.sql
./003_foo_load.dml.sql"
TEST_LAST_MIGRATION="Version
3
"
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
fn_count_migrations ()
{
  log "ENTER fn_count_migrations..."

	if [ "${TEST_MODE}" == true ]; then
    MIGRATIONS=${TEST_MIGRATIONS}
  else
    MIGRATIONS=$(find . -name "*.up.sql" -o -name "*.dml.sql")
  fi

  log "Processing ${MIGRATIONS}"

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
		if [ ${i: -7} == ".up.sql" ]; then
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
  log "ENTER fn_last_migration..."

  if [ "${TEST_MODE}" == true ]; then
    LAST_MIGRATION=${TEST_LAST_MIGRATION}
    LAST_MIGRATION=$(echo "${LAST_MIGRATION}" | awk 'END{print $NF}')
  else
	  LAST_MIGRATION=$(gcloud spanner databases execute-sql ${SPANNER_DATABASE_ID} --instance=${SPANNER_INSTANCE_ID} --sql="SELECT Version from SchemaMigrations" | awk 'END{print $NF}')
  fi

	set +o nounset
	if [ -z "${LAST_MIGRATION}" ]; then
    log "No migrations applied, will apply all"
		LAST_MIGRATION=0
	fi
	set -o nounset

  log "LAST_MIGRATION=${LAST_MIGRATION}"

  log "LEAVE fn_last_migration..."
}

fn_determine_outstanding_migrations ()
{
  log "ENTER fn_determine_outstanding_migrations..."

	OUTSTANDING_MIGRATIONS=""
	OUTSTANDING_MIGRATIONS_COUNT=0

	for i in ${MIGRATIONS}
	do
    log "  Checking ${i}"
		n=$(echo ${i} | cut -c1-3 | awk 'END{print $NF}')
    log "    with prefix ${n}"
    if [ ${n} -gt ${LAST_MIGRATION} ]; then
    	OUTSTANDING_MIGRATIONS+="${i} "
    	OUTSTANDING_MIGRATIONS_COUNT=$((OUTSTANDING_MIGRATIONS_COUNT+1))
    fi
	done

  log "OUTSTANDING_MIGRATIONS=${OUTSTANDING_MIGRATIONS}"
  log "OUTSTANDING_MIGRATIONS_COUNT=${OUTSTANDING_MIGRATIONS_COUNT}"

  OUTSTANDING_MIGRATIONS=$(echo ${OUTSTANDING_MIGRATIONS} | sort -n)

  log "LEAVE fn_determine_outstanding_migrations..."
}

fn_apply_all_ddl ()
{
  log "ENTER fn_apply_all_ddl..."

  if [ "${TEST_MODE}" == true ]; then
    log "Applying all migrations in test mode..."
  else
    migrate -path . -database spanner://projects/${GCP_PROJECT_ID}/instances/${SPANNER_INSTANCE_ID}/databases/${SPANNER_DATABASE_ID} up
  fi

  log "LEAVE fn_apply_all_ddl..."
}

fn_apply_ddl ()
{
  log "ENTER fn_apply_ddl..."

  if [ "${TEST_MODE}" == true ]; then
    log "Applying DDL migration '${i}' in test mode..."
  else
    migrate -path . -database spanner://projects/${GCP_PROJECT_ID}/instances/${SPANNER_INSTANCE_ID}/databases/${SPANNER_DATABASE_ID} up 1
  fi

  log "LEAVE fn_apply_ddl..."
}

fn_apply_dml ()
{
  log "ENTER fn_apply_dml..."

  if [ "${TEST_MODE}" == true ]; then
    log "Applying DML migration '${1}' in test mode..."
    echo "${TEST_DML}" > "${1}.tmp"
    awk '{printf "%s ",$0} END {print ""}' "${1}.tmp" | awk -F';' '{$1=$1}1' OFS=';\n' > "${1}.tmp.tmp"
    while IFS= read -r line; do
      if [[ -z "${line// }" ]]; then
        log "  Skipping empty line..."
      else
        log "  Running: ${line}"
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
  fi

  log "LEAVE fn_apply_dml..."
}

fn_apply_migrations ()
{
  log "ENTER fn_apply_migrations..."

  log "OUTSTANDING_MIGRATIONS=${OUTSTANDING_MIGRATIONS}"

	for i in ${OUTSTANDING_MIGRATIONS}
	do
    log "  Processing ${i}"
		n=$(echo ${i} | cut -c1-3 | awk 'END{print $NF}')
    log "    with prefix ${n}"

		if [ ${i: -8} == ".dml.sql" ]; then
      fn_apply_dml ${i}
		else
      fn_apply_ddl ${i}
		fi
	done

  log "LEAVE fn_apply_migrations..."
}
# <- FUNCTIONS ----------------------------------------

if [ -f transform.sh ]; then
  chmod +x transform.sh
  ./transform.sh ${ENV}
fi

echo
fn_count_migrations

if [ ${MIGRATION_COUNT} -eq 0 ]; then
  log "No migrations available"
  cleanup_and_exit_with_code 0
fi

if [ ${MIGRATION_COUNT_DML} -eq 0 ]; then
  log "No DML migrations available"
	fn_apply_all_ddl
  cleanup_and_exit_with_code 0
fi

echo
fn_last_migration

echo
fn_determine_outstanding_migrations

if [ ${OUTSTANDING_MIGRATIONS_COUNT} -eq 0 ]; then
  log "No migrations needed"
  cleanup_and_exit_with_code 0
fi

echo
fn_apply_migrations

cleanup_and_exit_with_code 0
