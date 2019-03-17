# Spanner Migrations

We use the excellent [migrate](https://github.com/golang-migrate/migrate) tool for Google GCP Spanner database migrations however it does not support DML.
DML is useful when a new feauture requires some non-transactional data.
We work around this with a wrapper tool `migratex` which interleaves DML migrations with `migrate's` DDL migrations.

There are two versions of this tool, one is a Bash script and one is a Go program.
The Bash script [migratex.sh](https://github.com/localcover/public/blob/master/spanner-migrations/migratex.sh) was written first and relies on the [Google Cloud SDK](https://cloud.google.com/sdk/install) being installed and up-to-date.
The Go program [migratex.go](https://github.com/localcover/public/blob/master/spanner-migrations/migratex.go) replaces the Bash script and is much faster because it uses the [Go Cloud Spanner client library](https://cloud.google.com/spanner/docs/reference/libraries#client-libraries-install-go) and so can cache the Spanner session and leverage things like batch DML processing.

`migratex` requires the following naming convention for migrations where `_[SOME_BUINSESS_DOMAIN]_[SOME_FEATURE]` can be anything.
DML migration revision history is maintained in the table 'DataMigrations'.

    [REVISION]_[SOME_BUINSESS_DOMAIN]_[SOME_FEATURE].ddl.up.sql
    [REVISION]_[SOME_BUINSESS_DOMAIN]_[SOME_FEATURE].[ENV_ID].dml.sql
    [REVISION]_[SOME_BUINSESS_DOMAIN]_[SOME_FEATURE].[ENV_ID].[ENV_ID].dml.sql
    [REVISION]_[SOME_BUINSESS_DOMAIN]_[SOME_FEATURE].all.dml.sql

DML can contain tokens and if so the tokens will be resolved if a JSON token definition files exists.
These JSON token definition files are optional but there can only be one per DML file:

    [REVISION]_[SOME_BUINSESS_DOMAIN]_[SOME_FEATURE].[ENV_ID].json
    [REVISION]_[SOME_BUINSESS_DOMAIN]_[SOME_FEATURE].[ENV_ID].[ENV_ID].json
    [REVISION]_[SOME_BUINSESS_DOMAIN]_[SOME_FEATURE].all.json

Note that there can only be one DML file for a revision for each environment.

## Usage

```shell
gcloud config configurations activate [CONFIGURATION_NAME]

gcloud spanner databases create [SPANNER_DATABASE_ID] --instance=[SPANNER_INSTANCE_ID]

# DDL only using 'migrate'
migrate -path . -database spanner://projects/[GCP_PROJECT_ID]/instances/[SPANNER_INSTANCE_ID]/databases/[SPANNER_DATABASE_ID] up

# DDL and DML using 'migratex' with no dependencies installed
go mod init migratex
go build migratex
chmod +x migratex
./migratex -env_id=$[ENV_ID] -gcp_project_id=[GCP_PROJECT_ID] -spanner_instance_id=[SPANNER_INSTANCE_ID] -spanner_database_id=[SPANNER_DATABASE_ID]

# DDL and DML using 'migratex' with the Go Cloud Spanner client library already installed
go run migratex.go -env_id=$[ENV_ID] -gcp_project_id=[GCP_PROJECT_ID] -spanner_instance_id=[SPANNER_INSTANCE_ID] -spanner_database_id=[SPANNER_DATABASE_ID]

# DDL and DML using the deprecated 'migratex' Bash script
./migratex.sh [ENV_ID] [GCP_PROJECT_ID] [SPANNER_INSTANCE_ID] [SPANNER_DATABASE_ID]
```
