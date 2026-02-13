ARG RUBY_VERSION=3.2
ARG DISTRO=bullseye

FROM ruby:${RUBY_VERSION}-${DISTRO}

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libxml2 \
    libxslt-dev \
    libxslt1-dev \
    openjdk-11-jre-headless \
    raptor2-utils \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN gem update --system
RUN bundle config set --global no-document 'true'
