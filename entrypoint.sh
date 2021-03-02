#!/bin/sh -l

echo "Installing Docker"
#amazon-linux-extras install docker=18

echo "cd into $GITHUB_WORKSPACE"
cd $GITHUB_WORKSPACE

# Download the copilot linux binary.
echo "Download the copilot linux binary"
wget https://ecs-cli-v2-release.s3.amazonaws.com/copilot-linux-v1.2.0
mv ./copilot-linux-v1.2.0 ./copilot-linux
chmod +x ./copilot-linux

# TODO Do login

# Do deploy
echo "Starting deploy"
for env in $(INPUT_ENVIRONMENTS)
do
    for service in $(INPUT_SERVICES)
    do
        # TODO Add optional app name
        echo "Deploying ${env} - ${service}"
        ./copilot-linux deploy --env $env --name $service
    done
done
