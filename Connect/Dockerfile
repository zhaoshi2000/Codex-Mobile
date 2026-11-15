FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY src ./src
ENV PORT=8787 BIND_HOST=0.0.0.0
USER node
EXPOSE 8787
CMD ["node", "src/relay.mjs"]
