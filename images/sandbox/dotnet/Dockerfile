ARG REGISTRY
FROM ${REGISTRY}/sandbox/base:latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    dotnet-sdk-9.0 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# dotnet tools
USER coder
ENV PATH="$PATH:/home/coder/.dotnet/tools"
RUN dotnet tool install -g dotnet-ef \
    && dotnet tool install -g csharpier
