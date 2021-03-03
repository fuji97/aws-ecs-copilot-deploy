#!/bin/bash

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

# Docker login
if [[ ! -z "$INPUT_DOCKERHUBUSERNAME" && ! -z "$INPUT_DOCKERHUBPASSWORD" ]] ; then
    echo "Docker credentials found, login to Docker";
    docker login -u $INPUT_DOCKERHUBUSERNAME -p $INPUT_DOCKERHUBPASSWORD;
else
    echo "No Docker credentials found, skip login to Docker";
fi
# First, upgrade the cloudformation stack of every environment in the pipeline.
pipeline=$(cat ./copilot/pipeline.yml | ruby -ryaml -rjson -e 'puts JSON.pretty_generate(YAML.load(ARGF))')

#pl_envs=$(echo $pipeline | jq '.stages[].name' | sed 's/"//g')

for env in $INPUT_ENVIRONMENTS; do
./copilot-linux env upgrade -n $env;
done;

# Find application name
app=$(cat ./copilot/.workspace | sed -e 's/^application: //')
echo "App: $app"
# Find all the local services in the workspace.
svcs=$(./copilot-linux svc ls --local --json | jq '.services[].name' | sed 's/"//g')
echo "Services: $svcs"
# Find all the local jobs in the workspace.
jobs=$(./copilot-linux job ls --local --json | jq '.jobs[].name' | sed 's/"//g')
echo "Jobs: $jobs"
# Find all the environments
envs=$(./copilot-linux env ls --json | jq '.environments[].name' | sed 's/"//g')
echo "Envs: $envs"
# Find account ID
id=$(aws sts get-caller-identity | jq '.Account' | sed 's/"//g')
# Generate the cloudformation templates.
# The tag is the build ID but we replaced the colon ':' with a dash '-'.
tag=$(sed 's/:/-/g' <<<"$GITHUB_SHA")
echo "Tag: $tag"

for env in $envs; do
    for svc in $svcs; do
    ./copilot-linux svc package -n $svc -e $env --output-dir './infrastructure' --tag $tag;
    done;
    for job in $jobs; do
    ./copilot-linux job package -n $job -e $env --output-dir './infrastructure' --tag $tag;
    done;
done;
ls -lah ./infrastructure

# Get S3 Bucket, if not exist, create it
# TODO Generate better name
s3_bucket=${INPUT_BUCKET:="ecs-$app"}
echo "S3 Bucket: $s3_bucket"
if ! (aws s3api head-bucket --bucket "$s3_bucket" 2>/dev/null) ; then
    echo "Bucket not found, creating bucket..."
    if ! (aws s3 mb "s3://$s3_bucket" --region ${AWS_DEFAULT_REGION:="$AWS_REGION"}) ; then
        >&2 echo "Cannot create bucket!"
        exit 1
    fi
fi

# Concatenate jobs and services into one var for addons
# If addons exists, upload addons templates to each S3 bucket and write template URL to template config files.
WORKLOADS=$(echo $jobs $svcs)

for workload in $WORKLOADS; do
    ADDONSFILE="./infrastructure/$workload.addons.stack.yml"
    if [ -f "$ADDONSFILE" ]; then
    tmp=$(mktemp)
    timestamp=$(date +%s)
    aws s3 cp "$ADDONSFILE" "s3://$s3_bucket/ghactions/$timestamp/$workload.addons.stack.yml";
    jq --arg a "https://$s3_bucket/ghactions/$timestamp/$workload.addons.stack.yml" '.Parameters.AddonsTemplateURL = $a' ./infrastructure/$workload-test.params.json > "$tmp" && mv "$tmp" ./infrastructure/$workload-test.params.json
    fi
done;
# Build images
# - For each manifest file:
#   - Read the path to the Dockerfile by translating the YAML file into JSON.
#   - Run docker build.
#   - For each environment:
#     - Retrieve the ECR repository.
#     - Login and push the image.

for workload in $WORKLOADS; do
    manifest=$(cat ./copilot/$workload/manifest.yml | ruby -ryaml -rjson -e 'puts JSON.pretty_generate(YAML.load(ARGF))')
    image_location=$(echo $manifest | jq '.image.location')
    if [ ! "$image_location" = null ]; then
        echo "skipping image building because location is provided as $image_location";
        continue
    fi
    base_dockerfile=$(echo $manifest | jq '.image.build')
    build_dockerfile=$(echo $manifest| jq 'if .image.build?.dockerfile? then .image.build.dockerfile else "" end' | sed 's/"//g')
    build_context=$(echo $manifest| jq 'if .image.build?.context? then .image.build.context else "" end' | sed 's/"//g')
    build_target=$(echo $manifest| jq 'if .image.build?.target? then .image.build.target else "" end' | sed 's/"//g')
    dockerfile_args=$(echo $manifest | jq 'if .image.build?.args? then .image.build.args else "" end | to_entries?')
    build_cache_from=$(echo $manifest | jq 'if .image.build?.cache_from? then .image.build.cache_from else "" end')
    df_rel_path=$( echo $base_dockerfile | sed 's/"//g')
    if [ -n "$build_dockerfile" ]; then 
        df_rel_path=$build_dockerfile
    fi
    df_path=$df_rel_path
    df_dir_path=$(dirname "$df_path")
    if [ -n "$build_context" ]; then
        df_dir_path=$build_context
    fi
    build_args=
    if [ -n "$dockerfile_args" ]; then
        for arg in $(echo $dockerfile_args | jq -r '.[] | "\(.key)=\(.value)"'); do 
            build_args="$build_args--build-arg $arg "
        done
    fi
    if [ -n "$build_target" ]; then
        build_args="$build_args--target $build_target "
    fi
    if [ -n "$build_cache_from" ]; then
        for arg in $(echo $build_cache_from | jq -r '.[]'); do
            build_args="$build_args--cache-from $arg "
        done
    fi
    echo "Name: $workload"
    echo "Relative Dockerfile path: $df_rel_path"
    echo "Docker build context: $df_dir_path"
    echo "Docker build args: $build_args"
    echo "Running command: docker build -t $workload:$tag $build_args-f $df_path $df_dir_path";
    docker build -t $workload:$tag $build_args-f $df_path $df_dir_path;
    image_id=$(docker images -q $workload:$tag);
    for env in $envs; do
        repo=$(cat ./infrastructure/$workload-$env.params.json | jq '.Parameters.ContainerImage' | sed 's/"//g');
        region=$(echo $repo | cut -d'.' -f4);
        #$(aws ecr get-login --no-include-email --region $region);
        aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $id.dkr.ecr.$region.amazonaws.com;
        # TODO Check if this conflicts with docker hub login
        docker tag $image_id $repo;
        docker push $repo;
    done;
done;

# Deploy CloudFormationTemplate
for env in $INPUT_ENVIRONMENTS; do
    
    role="arn:aws:iam::$id:role/$app-$env-CFNExecutionRole"
    for workload in $INPUT_SERVICES $INPUT_JOBS; do
        echo "Deploying $env - $workload"
        # CloudFormation stack name
        stack="$app-$env-$workload"
        stacks+=stack
        aws cloudformation deploy  \
        --template-file "./infrastructure/$workload-$env.stack.yml" \
        --stack-name "$stack" \
        --parameter-overrides "file://infrastructure/$workload-$env.params.json" \
        --capabilities CAPABILITY_NAMED_IAM \
        --s3-bucket "$s3_bucket" \
        --role-arn "$role"
    done;
done;

echo "Stacks ${stacks[@]}"

# Wait deploys to finish
# in_progress_status=(CREATE_IN_PROGRESS UPDATE_COMPLETE_CLEANUP_IN_PROGRESS UPDATE_IN_PROGRESS IMPORT_IN_PROGRESS)
# positive_status=(CREATE_COMPLETE UPDATE_COMPLETE IMPORT_COMPLETE)
# fails=0

# while [[ ${#stacks_done[@]} < ${#stacks[@]} ]]; do
#     for stack in $stacks; do
#         if [[ ! " ${stacks_done[@]} " =~ " ${stack} " ]]; then
#             status=$(aws cloudformation describe-stacks --stack-name aws-ecs-node-demo-prod-backend | jq ".Stacks[0].StackStatus" | sed 's/"//g')
#             if [[ ! " ${in_progress_status[@]} " =~ " ${status} " ]]; then
#                 stacks_done+=$stack
#                 if [[ " ${positive_status[@]} " =~ " ${status} " ]]; then
#                     echo "$stack deployed successfully"
#                 else
#                     echo "$stack failed"
#                     fails=$fails+1
#                 fi
#             fi
#         fi
#     done
#     sleep 1
# done

# if [[ fails > 0 ]]; then
#     echo "One or more stacks failed to deploy"
#     exit 1
# fi