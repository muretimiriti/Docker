# Use official Node image
FROM node:24

# Set working directory
WORKDIR /app

# Copy and install dependencies
COPY package*.json ./
RUN npm install

# Copy the rest of the app
COPY . .

# Expose port
EXPOSE 3000

# Start the server
CMD ["nodemon", "server.js"]
