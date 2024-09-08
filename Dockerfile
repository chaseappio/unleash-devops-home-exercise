# Use an official Node.js runtime as a parent image
FROM node:18-alpine

# Set the working directory in the container
WORKDIR /usr/src/app

# Copy the package.json and package-lock.json to the working directory
COPY package*.json ./

# Install the project dependencies
RUN npm install

# Copy the rest of the application files
COPY . .

# Build the TypeScript code using the tsconfig.json configuration
RUN npm run build

# Expose the port the app runs on (customize if necessary)
EXPOSE 3000

# Start the application using the transpiled JavaScript file
CMD ["node", "dist/index.js"]