# Do deploy
echo "Starting deploy"
for env in $INPUT_ENVIRONMENTS
do
    for service in $INPUT_SERVICES
    do
        # TODO Add optional app name
        echo "Deploying ${env} - ${service}"
        ./copilot-linux deploy --env $env --name $service --tag $GITHUB_SHA
    done
done