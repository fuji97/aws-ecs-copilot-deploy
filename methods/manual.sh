#!/bin/bash

echo "👉 Manual deploy"

# Docker login
if [[ ! -z "$INPUT_DOCKERHUBUSERNAME" && ! -z "$INPUT_DOCKERHUBPASSWORD" ]] ; then
    echo "Docker credentials found, login to Docker";
    docker login -u $INPUT_DOCKERHUBUSERNAME -p $INPUT_DOCKERHUBPASSWORD;
else
    echo "No Docker credentials found, skip login to Docker";
fi
# First, upgrade the cloudformation stack of every environment in the pipeline.
echo "::group::⬆️ Upgrade environments"
for env in $INPUT_ENVIRONMENTS; do
    echo "Upgrading $env"
    ./copilot-linux env upgrade -n $env;
done;
echo "::endgroup::"

echo "::group::📦 Generate packages"
# Find application name
app=$(cat $GITHUB_WORKSPACE/copilot/.workspace | sed -e 's/^application: //')
echo "App: $app"
# Find all the local services in the workspace.
svcs=$(./copilot-linux svc ls --local --json | jq '.services[].name' | sed 's/"//g')
echo "Services: ${svcs[@]}"
# Find all the local jobs in the workspace.
jobs=$(./copilot-linux job ls --local --json | jq '.jobs[].name' | sed 's/"//g')
echo "Jobs: ${jobs[@]}"
# Find all the environments
envs=$(./copilot-linux env ls --json | jq '.environments[].name' | sed 's/"//g')
echo "Envs: ${envs[@]}"
# Find account ID
id=$(aws sts get-caller-identity | jq '.Account' | sed 's/"//g')
# Generate the cloudformation templates.
tag=$(sed 's/:/-/g' <<<"$GITHUB_SHA")
echo "Tag: ${tag[@]}"

for env in $envs; do
    for svc in $svcs; do
    ./copilot-linux svc package -n $svc -e $env --output-dir "$GITHUB_WORKSPACE/infrastructure" --tag $tag;
    done;
    for job in $jobs; do
    ./copilot-linux job package -n $job -e $env --output-dir "$GITHUB_WORKSPACE/infrastructure" --tag $tag;
    done;
done;
echo "::endgroup::"

# Get S3 Bucket, if not exist, create it
echo "::group::🗑 Setup S3 Bucket"
s3_bucket=${INPUT_BUCKET:="ecs-$app"}
echo "S3 Bucket: $s3_bucket"
if ! (aws s3api head-bucket --bucket "$s3_bucket" 2>/dev/null) ; then
    echo "Bucket not found, creating bucket..."
    if ! (aws s3 mb "s3://$s3_bucket" --region ${AWS_DEFAULT_REGION:="$AWS_REGION"}) ; then
        echo "::error:: ❌ Cannot create bucket"
        exit 1
    fi
fi
echo "::endgroup::"

# Concatenate jobs and services into one var for addons
# If addons exists, upload addons templates to each S3 bucket and write template URL to template config files.
echo "::group::☁️ Upload addons"
WORKLOADS=$(echo $jobs $svcs)

for workload in $WORKLOADS; do
    ADDONSFILE="$GITHUB_WORKSPACE/infrastructure/$workload.addons.stack.yml"
    if [ -f "$ADDONSFILE" ]; then
    tmp=$(mktemp)
    timestamp=$(date +%s)
    aws s3 cp "$ADDONSFILE" "s3://$s3_bucket/ghactions/$timestamp/$workload.addons.stack.yml";
    for env in $INPUT_ENVIRONMENTS; do
        jq --arg a "https://$s3_bucket/ghactions/$timestamp/$workload.addons.stack.yml" '.Parameters.AddonsTemplateURL = $a' $GITHUB_WORKSPACE/infrastructure/$workload-$env.params.json > "$tmp" && mv "$tmp" $GITHUB_WORKSPACE/infrastructure/$workload-$env.params.json
    done;
    fi
done;
echo "::endgroup::"

# Build images
# - For each manifest file:
#   - Read the path to the Dockerfile by translating the YAML file into JSON.
#   - Run docker build.
#   - For each environment:
#     - Retrieve the ECR repository.
#     - Login and push the image.

for workload in $WORKLOADS; do
    echo "::group::🔨 Building and uploading $workload"
    echo "cd into $GITHUB_WORKSPACE"
    cd $GITHUB_WORKSPACE
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
        aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $id.dkr.ecr.$region.amazonaws.com;
        docker tag $image_id $repo;
        docker push $repo;
    done;
    echo "cd back to /"
    cd /
    echo "::endgroup::"
done;

# Deploy CloudFormationTemplate
for env in $INPUT_ENVIRONMENTS; do
    role="arn:aws:iam::$id:role/$app-$env-CFNExecutionRole"
    for workload in $INPUT_WORKLOADS; do
        # CloudFormation stack name
        stack="$app-$env-$workload"
        echo "::group::⚡ Deploying stack: $stack"
        res=(aws cloudformation deploy  \
            --template-file "$GITHUB_WORKSPACE/infrastructure/$workload-$env.stack.yml" \
            --stack-name "$stack" \
            --parameter-overrides "file://$GITHUB_WORKSPACE/infrastructure/$workload-$env.params.json" \
            --capabilities CAPABILITY_NAMED_IAM \
            --s3-bucket "$s3_bucket" \
            --role-arn "$role")
        if ! $res ; then
            echo "::error::❌ Stack '$stack' deploy failed"
            exit 1
        fi
        echo "::endgroup::"
    done;
done;