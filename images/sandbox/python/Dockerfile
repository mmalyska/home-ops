FROM harbor.REPLACE_PRIVATE_DOMAIN/sandbox/base:latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 \
    python3.12-venv \
    python3-pip \
    python3.12-dev \
    build-essential \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# uv package manager
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

USER coder
ENV PATH="$PATH:/home/coder/.cargo/bin"
RUN uv pip install --system jupyter notebook pandas numpy scipy scikit-learn requests httpx
