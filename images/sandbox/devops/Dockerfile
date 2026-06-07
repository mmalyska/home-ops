ARG REGISTRY
FROM ${REGISTRY}/sandbox/base:latest

USER root

# Kubernetes tools
ARG KUBECTL_VERSION=v1.32.0
ARG HELM_VERSION=v3.17.0
ARG TALOSCTL_VERSION=v1.9.0

RUN curl -fsSL https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl \
      -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl \
    && curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | \
      DESIRED_VERSION=${HELM_VERSION} bash \
    && curl -fsSL https://github.com/siderolabs/talos/releases/download/${TALOSCTL_VERSION}/talosctl-linux-amd64 \
      -o /usr/local/bin/talosctl && chmod +x /usr/local/bin/talosctl

# Terraform
ARG TERRAFORM_VERSION=1.10.0
RUN curl -fsSL https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip \
      -o /tmp/tf.zip && unzip /tmp/tf.zip -d /usr/local/bin && rm /tmp/tf.zip

# k9s
ARG K9S_VERSION=v0.32.0
RUN curl -fsSL https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz \
      | tar xz -C /usr/local/bin k9s

# age (encryption)
RUN curl -fsSL https://github.com/FiloSottile/age/releases/latest/download/age-v1.2.0-linux-amd64.tar.gz \
      | tar xz -C /tmp && mv /tmp/age/age /usr/local/bin/ && mv /tmp/age/age-keygen /usr/local/bin/

USER coder
