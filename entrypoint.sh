#!/bin/bash

# Download the copilot linux binary.
echo "::group::📥 Download the copilot linux binary"
wget https://ecs-cli-v2-release.s3.amazonaws.com/copilot-linux-v1.2.0
mv ./copilot-linux-v1.2.0 ./copilot-linux
chmod +x ./copilot-linux
echo "::endgroup::"

case $INPUT_DEPLOY_METHOD in
    "manual") /methods/manual.sh
    ;;
    "automatic") /methods/automatic.sh
    ;;
    *) echo "::error::❌ '$INPUT_DEPLOY_METHOD' is not a valid deploy method"
    exit 1
    ;;
esac
