# Google AppEngine Flexible Tricks

## Advanced Deployment Techniques

When using the simply AppEngine deployment command there is an issue in the Flexible environment with random HTTP 503 errors for the first few minutes after the deployment completes, see [Known Issues in the App Engine Flexible Environment](https://cloud.google.com/appengine/docs/flexible/known-issues).
However AppEngine supports two stage deployments which solves the issue, first deploy using the '--no-promote --no-stop-previous-version' flags and then wait for a few minutes before directing traffic to the new deployment.
We use the following bash script to effect this.
Note that this script is used as part of our [circleci](https://circleci.com) deployment configuration and so it contains references to circlci template parameters e.g. '<< parameters.gcp_project_id >>' but it should be clear that these can be replaced with bash command-line arguments:

```shell
# Exit script if you try to use an uninitialized variable.
set -o nounset
# Exit script if a statement returns a non-true return value.
set -o errexit
# Use the error status of the first failure, rather than that of the last item in a pipeline.
set -o pipefail

# >---------- DEPLOYING
echo "Deploying container to GAE..."
# DO NOT ADD flags '--verbosity=debug --log-http' to this command, it will break 'jq' processing of the resulting deployment metadata captured in 'gcloud-app-deploy.log'
gcloud app deploy --bucket gs://<< parameters.gcp_project_id >>-lc-api-stage-appengine --no-promote --no-stop-previous-version --format=json --quiet > gcloud-app-deploy.log
echo "Deployed container to GAE"

ls -al
cat gcloud-app-deploy.log

export DEPLOYMENT_WAIT_TIME=180
echo "Waiting for '${DEPLOYMENT_WAIT_TIME}' seconds for GAE deployment to become available see https://cloud.google.com/appengine/docs/flexible/known-issues"
sleep ${DEPLOYMENT_WAIT_TIME}
echo "Finished waiting for GAE deployment to become available"
# <----------

# >---------- PROMOTING
export GAE_DEPLOYED_VERSION=$(jq -r '.versions | .[0] | .id' gcloud-app-deploy.log)
echo "Promoting GAE version '${GAE_DEPLOYED_VERSION}'..."
gcloud app services set-traffic ${CIRCLE_PROJECT_REPONAME} --splits ${GAE_DEPLOYED_VERSION}=1 --quiet
echo "Promoted GAE version '${GAE_DEPLOYED_VERSION}''"
# <----------

# >---------- CLEANING UP - Stopping 'SERVING' versions with no traffic
echo "Listing GAE redundant versions that can be stopped i.e. those 'SERVING' with no traffic..."
gcloud app services list --filter="${CIRCLE_PROJECT_REPONAME}" --format=json > gcloud-app-services-list.log
echo "Listed GAE redundant versions that can be stopped"

ls -al
cat gcloud-app-services-list.log

export GAE_REDUNDANT_SERVING_VERSIONS=$(jq '.[0] | .versions | .[] | {id: .id, date: .last_deployed_time.datetime, servingStatus: .version.servingStatus, traffic_split: .traffic_split} | select(.traffic_split | contains(0)) | select(.servingStatus | contains("SERVING"))' gcloud-app-services-list.log)
echo "GAE_REDUNDANT_SERVING_VERSIONS=${GAE_REDUNDANT_SERVING_VERSIONS}"

export GAE_REDUNDANT_SERVING_VERSION_IDS=$(echo ${GAE_REDUNDANT_SERVING_VERSIONS} | jq -r '.id')
echo "GAE_REDUNDANT_SERVING_VERSION_IDS=${GAE_REDUNDANT_SERVING_VERSION_IDS}"

echo "Stopping GAE redundant running versions with no traffic..."
gcloud app versions stop --service ${CIRCLE_PROJECT_REPONAME} ${GAE_REDUNDANT_SERVING_VERSION_IDS} --quiet
echo "Stopped GAE redundant running versions with no traffic"
# <----------

# >---------- CLEANING UP - Deleting 'STOPPED' versions with no traffic
if [ << parameters.env >> == "prd" ]; then
  echo "Running in environment '<< parameters.env >>' and will SKIP the delete of GAE redundant versions that can be deleted i.e. those 'STOPPED' with no traffic..."

else
  echo "Listing GAE redundant versions that can be deleted i.e. those 'STOPPED' with no traffic..."
  gcloud app services list --filter="${CIRCLE_PROJECT_REPONAME}" --format=json > gcloud-app-services-list.log
  echo "Listed GAE redundant versions that can be deleted"

  ls -al
  cat gcloud-app-services-list.log

  export GAE_REDUNDANT_STOPPED_VERSIONS=$(jq '.[0] | .versions | .[] | {id: .id, date: .last_deployed_time.datetime, servingStatus: .version.servingStatus, traffic_split: .traffic_split} | select(.traffic_split | contains(0)) | select(.servingStatus | contains("STOPPED"))' gcloud-app-services-list.log)
  echo "GAE_REDUNDANT_STOPPED_VERSIONS=${GAE_REDUNDANT_STOPPED_VERSIONS}"

  export GAE_REDUNDANT_STOPPED_VERSION_IDS=$(echo ${GAE_REDUNDANT_STOPPED_VERSIONS} | jq -r '.id')
  echo "GAE_REDUNDANT_STOPPED_VERSION_IDS=${GAE_REDUNDANT_STOPPED_VERSION_IDS}"

  echo "Deleting GAE redundant stopped versions with no traffic..."
  gcloud app versions delete --service ${CIRCLE_PROJECT_REPONAME} ${GAE_REDUNDANT_STOPPED_VERSION_IDS} --quiet
  echo "Deleted GAE redundant stopped versions with no traffic"
fi
# <----------
```
