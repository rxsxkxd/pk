# E2E runner (E2E.md 2): Playwright + Chromium. The version matches @playwright/test in e2e/package.json.
FROM mcr.microsoft.com/playwright:v1.63.0-noble
WORKDIR /e2e
COPY e2e/package.json e2e/package-lock.json ./
RUN npm ci
COPY e2e/ ./
CMD ["npx", "playwright", "test"]
