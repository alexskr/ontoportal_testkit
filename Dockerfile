ARG TESTKIT_BASE_IMAGE=ontoportal/testkit-base:ruby3.2-bullseye
FROM ${TESTKIT_BASE_IMAGE}

WORKDIR /app

COPY Gemfile* *.gemspec ./

# Respect the project's Bundler lock when present.
RUN if [ -f Gemfile.lock ]; then \
      BUNDLER_VERSION=$(grep -A 1 "BUNDLED WITH" Gemfile.lock | tail -n 1 | tr -d ' '); \
      gem install bundler -v "$BUNDLER_VERSION"; \
    fi

RUN bundle install --jobs 4 --retry 3

COPY . ./

CMD ["bundle", "exec", "rake"]
