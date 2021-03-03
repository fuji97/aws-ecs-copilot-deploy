#!/bin/bash

# Download the copilot linux binary.
echo "::group::Download the copilot linux binary"
wget https://ecs-cli-v2-release.s3.amazonaws.com/copilot-linux-v1.2.0
mv ./copilot-linux-v1.2.0 ./copilot-linux
chmod +x ./copilot-linux
echo "::endgroup::"

case $INPUT_DEPLOYMETHOD in
    "manual") ./methods/manual.sh
    ;;
    "automatic") ./methods/automatic.sh
    ;;
    *) echo "::error::Invalid deployment method"
    ;;
esac
