FROM node:20-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js charge-reminders.js ./
ENV PORT=8090
EXPOSE 8090
CMD ["node", "server.js"]
