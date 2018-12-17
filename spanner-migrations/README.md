# Spanner Migrations

We use the excellent [migrate](https://github.com/golang-migrate/migrate) tool for Google GCP Spanner database migrations however it does not support DML.
DML is useful when a new feauture requires some non-transactional data.
We work around this with a wrapper script which interleaves DML migrations using [Google Cloud SDK](https://cloud.google.com/sdk/install) commands.

The wrapper script requires the following naming convention for migrations and maintains DML migration revision history in the table 'DataMigrations':

    [REVISION]_[domain]_[FEATURE].ddl.up.sql
    [REVISION]_[domain]_[FEATURE].[ENV].dml.sql

DML can contain tokens and if so the tokens will be resolved if a JSON token definition files exists.
These JSON token definition files are optional but there can only be one per DML file:

    [REVISION]_[domain]_[FEATURE].[ENV].json

The first DDL migration requires at least the following:

```sql
CREATE TABLE DataMigrations (
  Version INT64 NOT NULL,
) PRIMARY KEY (Version);
```

## Usage

```shell
gcloud config configurations activate [CONFIGURATION_NAME]

gcloud spanner databases create [SPANNER_DATABASE_ID] --instance=[SPANNER INSTANCE ID]

# DDL and DML
./migrate.sh [ENV] [GCP_PROJECT_ID] [SPANNER INSTANCE ID] [SPANNER_DATABASE_ID]

# DDL only
migrate -path . -database spanner://projects/[GCP_PROJECT_ID]/instances/[SPANNER INSTANCE ID]/databases/[SPANNER_DATABASE_ID] up
```
