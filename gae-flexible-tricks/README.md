# Google AppEngine Flexible Tricks

## Advanced Deployment Techniques

When using the simply AppEngine deployment command there is an issue in the Flexible environment with random HTTP 503 errors for the first few minutes after the deployment completes, see [Known Issues in the App Engine Flexible Environment](https://cloud.google.com/appengine/docs/flexible/known-issues).

However AppEngine supports two stage deployments which solves the issue, first deploy using the '--no-promote --no-stop-previous-version' flags and then wait for a few minutes before directing traffic to the new deployment.

We use the Bash script [gae-promote.sh](https://github.com/goboxer/public/blob/master/gae-flexible-tricks/gae-promote.sh) to implement this. If you want to run this script on a mac then install `gdate` with 'brew install coreutils' and swap 'date' with 'gdate' in the script.
