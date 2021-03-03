#!/bin/bash

# Do deploy
echo "Manual deploy"

cd $GITHUB_WORKSPACE

for env in $INPUT_ENVIRONMENTS
do
    for service in $INPUT_SERVICES
    do
        echo "::group::Deploy ${env} - ${service}"
        ./copilot-linux deploy --env $env --name $service --tag $GITHUB_SHA
        echo "::endgroup::"
    done
done