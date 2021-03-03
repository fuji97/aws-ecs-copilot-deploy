# Container image
FROM ubuntu:latest

# Install dependencies
RUN echo "::group::Install base dependencies"
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common \
    wget \
    unzip \
    ruby \
    jq
RUN echo "::endgroup::"
# Install AWS CLI v2
RUN echo "::group::Install AWS CLI v2"
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
    && unzip awscliv2.zip \
    && ./aws/install
RUN echo "::endgroup::"
# Install Docker
RUN echo "::group::Install Docker"
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
RUN add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) \
    stable"
RUN apt-get update \
    && apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io
RUN echo "::endgroup::"
RUN rm -rf /var/lib/apt/lists/*

# Copy code file from your action repository to the filesystem path `/` of the container
COPY entrypoint.sh /entrypoint.sh
COPY methods/ /methods/

# Set correct permissions to execute the scripts
RUN chmod +x entrypoint.sh && chmod +x methods/*

# Set entrypoint (`entrypoint.sh`)
ENTRYPOINT ["/entrypoint.sh"]