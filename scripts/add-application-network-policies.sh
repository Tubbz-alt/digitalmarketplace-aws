#!/bin/bash -e

if [ "$#" -lt 3 -o "$#" -gt 4 ]; then
    echo "Usage: ./scripts/add-application-network-policies.sh <vars_yaml> <base_yaml> <application_name> [<application_suffix>]"
    exit 1
fi

export VARS_YAML=$1
export BASE_YAML=$2
export APPLICATION_NAME=$3
export APPLICATION_SUFFIX=$4

# TODO re add to Makefile deploy-app when we activate internal routes.
# apps that communicate with each other over the "internal" private network (*.apps.internal) need
# to have their explicitly "allowed" communication paths added as "network policies". these must be
# added before the app is started otherwise it will not be able to access those other apps, or those
# other apps won't be able to access *it*. the policies end up being associated with the app's guid
# rather than app name, so these need to be re-created for new apps we create, but the policies
# should follow the app's renaming at the end of the release process.
#
# the order of operations performed here (including inside add-application-network-policies.sh)
# is carefully designed to make it hopefully-impossible for an app to get to the point of being started
# with any required network policies not being in place, even if the "other" app (the other "party"
# in the policy) is simultaneously going through the release process and having its names & routes
# similarly juggled around. consider this carefully if making any changes to this.
# ./scripts/add-application-network-policies.sh ./vars/${STAGE}.yml ./vars/common.yml ${APPLICATION_NAME} "-release"

# In each of the cases for ingress and egress applications, we first apply the policy to any instances of the (in|e)gress
# application that might (also?) be in the process of being released. The order that the two commands are run in *is* relevant
# and designed to not to allow any policy combinations to be missed even in the face of concurrent release processes. As such,
# we must be tolerant to any of these commands failing because any of these application names may or may not exist at the exact
# point in time the command is executed. This is ok, because the *other* release process is also expected to be attempting
# to create these policies at the same time and this routine is designed so that at least one of them should be able to succeed
# before an application is started.
#
# And of course, because of this the commands also need to be robust against the network policy already existing

for EGRESS_APPLICATION_NAME in $(yq -rs '.[0] * .[1] | .[env.APPLICATION_NAME]?.egress_to_applications?[]?' "$BASE_YAML" "$VARS_YAML") ; do
    echo "Adding policy for access from ${APPLICATION_NAME}${APPLICATION_SUFFIX} to $EGRESS_APPLICATION_NAME-release..."
    cf add-network-policy ${APPLICATION_NAME}${APPLICATION_SUFFIX} --destination-app $EGRESS_APPLICATION_NAME-release --protocol tcp --port 8080 \
        || echo "...but that's probably fine because $EGRESS_APPLICATION_NAME may not be in a release process."
    echo "Adding policy for access from ${APPLICATION_NAME}${APPLICATION_SUFFIX} to $EGRESS_APPLICATION_NAME..."
    cf add-network-policy ${APPLICATION_NAME}${APPLICATION_SUFFIX} --destination-app $EGRESS_APPLICATION_NAME --protocol tcp --port 8080 \
        || echo "...but that's possibly fine because $EGRESS_APPLICATION_NAME could be in the midst of renaming apps as part of its release process."
done

for INGRESS_APPLICATION_NAME in $(yq -rs '.[0] * .[1] | to_entries | .[] | select(.value.egress_to_applications? | any(. == env.APPLICATION_NAME))? | .key' "$BASE_YAML" "$VARS_YAML") ; do
    echo "Adding policy for access from $INGRESS_APPLICATION_NAME-release to ${APPLICATION_NAME}${APPLICATION_SUFFIX}..."
    cf add-network-policy $INGRESS_APPLICATION_NAME-release --destination-app ${APPLICATION_NAME}${APPLICATION_SUFFIX} --protocol tcp --port 8080 \
        || echo "...but that's probably fine because $INGRESS_APPLICATION_NAME may not be in a release process."
    echo "Adding policy for access from $INGRESS_APPLICATION_NAME to ${APPLICATION_NAME}${APPLICATION_SUFFIX}..."
    cf add-network-policy $INGRESS_APPLICATION_NAME --destination-app ${APPLICATION_NAME}${APPLICATION_SUFFIX} --protocol tcp --port 8080 \
        || echo "...but that's possibly fine because $INGRESS_APPLICATION_NAME could be in the midst of renaming apps as part of its release process."
done
