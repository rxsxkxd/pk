FROM ruby:3.3-slim

RUN apt-get update -qq \
  && apt-get install -y --no-install-recommends build-essential nodejs npm \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile ./
RUN bundle install

COPY package.json ./
RUN npm install

COPY . .
RUN npm run build
