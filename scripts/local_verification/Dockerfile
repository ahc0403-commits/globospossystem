FROM --platform=linux/amd64 ubuntu:24.04@sha256:a2d43bffc46670d7108bb3c0468c67c5557c4c92e83e1e34cbff1322ad1b94dc

# The single tools layer avoids duplicating the SDK on Docker's vfs driver.
ENV DEBIAN_FRONTEND=noninteractive TZ=UTC LANG=C.UTF-8 \
    PATH=/opt/flutter/bin:/usr/local/bin:/usr/lib/postgresql/16/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/home/ubuntu PUB_CACHE=/home/ubuntu/.pub-cache \
    CHROME_EXECUTABLE=/usr/local/bin/pos-test-chrome
RUN --mount=type=secret,id=host_ca_bundle,mode=0444 \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils python3 python3-psycopg2 \
    ripgrep postgresql postgresql-contrib docker.io fontconfig fonts-noto-core \
    fonts-noto-cjk libgtk-3-0 libnss3 libasound2t64 libgbm1 libdrm2 libxss1 \
    libx11-xcb1 libxtst6 libxrandr2 libxcomposite1 libxcursor1 libxdamage1 \
    libxi6 libatk-bridge2.0-0 libxkbcommon0 libglib2.0-0 libglu1-mesa \
    && rm -rf /var/lib/apt/lists/* \
    && if [ -f /run/secrets/host_ca_bundle ]; then export CURL_CA_BUNDLE=/run/secrets/host_ca_bundle SSL_CERT_FILE=/run/secrets/host_ca_bundle GIT_SSL_CAINFO=/run/secrets/host_ca_bundle; fi \
    && curl -fsSL https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.41.6-stable.tar.xz -o /tmp/flutter.tar.xz \
    && echo '503b3e6b7d352fca5d21b6474eca95ad544d8fc3b053782eab63a360c7fc7569  /tmp/flutter.tar.xz' | sha256sum -c - \
    && tar -xJf /tmp/flutter.tar.xz -C /opt && rm /tmp/flutter.tar.xz \
    && curl -fsSL https://nodejs.org/dist/v22.22.0/node-v22.22.0-linux-x64.tar.xz -o /tmp/node.tar.xz \
    && echo '9aa8e9d2298ab68c600bd6fb86a6c13bce11a4eca1ba9b39d79fa021755d7c37  /tmp/node.tar.xz' | sha256sum -c - \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 && rm /tmp/node.tar.xz \
    && curl -fsSL https://github.com/denoland/deno/releases/download/v2.7.13/deno-x86_64-unknown-linux-gnu.zip -o /tmp/deno.zip \
    && echo 'd7b452de2578742889b70a7e3cf90eb14b8e6b1bca4758380da3630d694f04ff  /tmp/deno.zip' | sha256sum -c - \
    && unzip /tmp/deno.zip -d /usr/local/bin && rm /tmp/deno.zip \
    && curl -fsSL https://storage.googleapis.com/chrome-for-testing-public/156.0.8078.47/linux64/chrome-linux64.zip -o /tmp/chrome.zip \
    && echo 'e6c94490f0b6b337225aeb2d2a5034858516b7017356980ba94f5176d8774a50  /tmp/chrome.zip' | sha256sum -c - \
    && unzip -q /tmp/chrome.zip -d /opt && rm /tmp/chrome.zip \
    && printf '#!/bin/sh\nexec /opt/chrome-linux64/chrome --no-sandbox --disable-dev-shm-usage "$@"\n' > /usr/local/bin/pos-test-chrome \
    && chmod 755 /usr/local/bin/pos-test-chrome \
    && chown -R ubuntu:ubuntu /opt/flutter /home/ubuntu \
    && chmod -R g+rwX /opt/flutter /home/ubuntu \
    && su -p -s /bin/sh ubuntu -c 'export PATH=/opt/flutter/bin:/usr/local/bin:/usr/lib/postgresql/16/bin:/usr/sbin:/usr/bin:/sbin:/bin; git config --global --add safe.directory /opt/flutter && flutter --version && chmod -R g+rwX /opt/flutter /home/ubuntu'
USER ubuntu
WORKDIR /work
