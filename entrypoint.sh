#!/bin/sh -l

#echo "Installing Docker"
#amazon-linux-extras install docker=18

# TODO Improve: dont'do everything in $GITHUB_WORKSPACE, install CLI and tools in $HOME

echo "cd into $GITHUB_WORKSPACE"
cd $GITHUB_WORKSPACE

# Download the copilot linux binary.
echo "Download the copilot linux binary"
wget https://ecs-cli-v2-release.s3.amazonaws.com/copilot-linux-v1.2.0
mv ./copilot-linux-v1.2.0 ./copilot-linux
chmod +x ./copilot-linux

# TODO Do login

# TODO For now, load manual only
./manual.sh