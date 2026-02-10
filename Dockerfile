# syntax=docker/dockerfile:1

FROM node:24-alpine AS base
WORKDIR /app
ENV PORT=3000

# Install dependencies in separate stages so production image can omit dev deps.
FROM base AS deps-dev
COPY package*.json ./
RUN npm ci

FROM base AS deps-prod
COPY package*.json ./
RUN npm ci --omit=dev

FROM deps-dev AS dev
COPY . .
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --retries=10 CMD node -e "const http=require('http');const req=http.get({host:'127.0.0.1',port:process.env.PORT||3000,path:'/healthz',timeout:2000},res=>process.exit(res.statusCode===200?0:1));req.on('error',()=>process.exit(1));"
CMD ["npm", "run", "dev"]

FROM deps-prod AS prod
ENV NODE_ENV=production
COPY . .
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --retries=10 CMD node -e "const http=require('http');const req=http.get({host:'127.0.0.1',port:process.env.PORT||3000,path:'/healthz',timeout:2000},res=>process.exit(res.statusCode===200?0:1));req.on('error',()=>process.exit(1));"
CMD ["node", "server.js"]

