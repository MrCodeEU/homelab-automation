FROM rockylinux/rockylinux:9

# Packages needed by Ansible + Caddy role
RUN dnf install -y \
        openssh-server \
        python3 \
        python3-pip \
        sudo \
        curl \
        procps-ng \
        iproute \
        iputils \
        tar \
        gzip \
    && dnf clean all

# Configure sshd
RUN ssh-keygen -A && \
    sed -i 's|^#\?PermitRootLogin.*|PermitRootLogin yes|' /etc/ssh/sshd_config && \
    sed -i 's|^#\?PasswordAuthentication.*|PasswordAuthentication no|' /etc/ssh/sshd_config && \
    sed -i 's|^#\?PubkeyAuthentication.*|PubkeyAuthentication yes|' /etc/ssh/sshd_config && \
    mkdir -p /var/run/sshd /root/.ssh && \
    chmod 700 /root/.ssh

# Accept authorized_keys via build arg or volume-mount at runtime
ARG SSH_PUBKEY=""
RUN if [ -n "$SSH_PUBKEY" ]; then \
        echo "$SSH_PUBKEY" > /root/.ssh/authorized_keys && \
        chmod 600 /root/.ssh/authorized_keys; \
    fi

# Stub out firewalld and SELinux so Caddy role doesn't fail in container
RUN echo -e '#!/bin/sh\nexit 0' > /usr/local/bin/firewall-cmd && chmod +x /usr/local/bin/firewall-cmd

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
