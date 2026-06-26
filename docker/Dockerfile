# Two runtimes in one image on purpose: Ruby is the app (see lib/autochef/),
# Python is isolated to cart_builder/ (Playwright cart automation only —
# see cart_builder/cart.py's module docstring for why that one piece stays
# Python while everything else is Ruby).

FROM ruby:3.2-slim

# --- Python, scoped to cart_builder/ only ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    libsqlite3-dev \
    wget \
    gnupg \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# --- Ruby deps ---
COPY Gemfile Gemfile.lock* ./
RUN bundle install

# --- Python deps, in their own venv so they never touch system/Ruby tooling ---
COPY cart_builder/requirements.txt cart_builder/requirements.txt
RUN python3 -m venv /opt/cart_builder_venv && \
    /opt/cart_builder_venv/bin/pip install --no-cache-dir -r cart_builder/requirements.txt && \
    /opt/cart_builder_venv/bin/playwright install --with-deps chromium
ENV CART_BUILDER_PYTHON=/opt/cart_builder_venv/bin/python3

COPY lib/ ./lib/
COPY db/ ./db/
COPY scripts/ ./scripts/
COPY cart_builder/ ./cart_builder/
COPY main.rb config.yaml ./

# data/ is a volume mount in docker-compose.yml, not baked into the image
RUN mkdir -p /app/data

CMD ["bundle", "exec", "ruby", "main.rb", "serve"]
