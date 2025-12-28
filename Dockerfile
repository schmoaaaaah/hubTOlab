FROM alpine:3.20

LABEL maintainer="Schmoaaaaah"
LABEL description="GitHub to GitLab repository sync tool"

# Install dependencies
RUN apk add --no-cache \
    git \
    git-lfs \
    openssh-client \
    bash \
    jq \
    curl \
    ca-certificates \
    && git lfs install

# Install GitHub CLI
ARG GH_VERSION=2.62.0
RUN curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /tmp \
    && mv /tmp/gh_${GH_VERSION}_linux_amd64/bin/gh /usr/local/bin/gh \
    && rm -rf /tmp/gh_*

# Install GitLab CLI (glab)
ARG GLAB_VERSION=1.80.4
RUN curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /tmp \
    && mv /tmp/bin/glab /usr/local/bin/glab \
    && rm -rf /tmp/bin

# Create non-root user
RUN adduser -D -h /home/syncer syncer \
    && mkdir -p /home/syncer/.ssh /data \
    && chown -R syncer:syncer /home/syncer /data

# Copy sync script
COPY --chmod=755 sync.sh /usr/local/bin/github-gitlab-sync

# Configure SSH to not verify host keys (for automation)
# You can mount your own ssh config/known_hosts for stricter security
RUN echo "Host *" >> /etc/ssh/ssh_config \
    && echo "  StrictHostKeyChecking accept-new" >> /etc/ssh/ssh_config \
    && echo "  UserKnownHostsFile /home/syncer/.ssh/known_hosts" >> /etc/ssh/ssh_config

USER syncer
WORKDIR /data

# Default environment variables
ENV WORK_DIR=/data/repos
ENV GITLAB_GROUP=github
ENV INCLUDE_FORKS=false
ENV INCLUDE_ARCHIVED=false

# Volumes for persistent data and SSH keys
VOLUME ["/data", "/home/syncer/.ssh"]

ENTRYPOINT ["github-gitlab-sync"]
CMD ["--help"]