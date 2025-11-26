# Use a slim Debian image as a base
FROM debian:stable-slim

# Install curl to download the binary
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

# Create a directory for the application
WORKDIR /app

# Download the binary, make it executable
RUN curl -L "https://antigravity.google/download/linux" -o antigravity && \
    chmod +x antigravity

# Set the entrypoint to run the binary
ENTRYPOINT ["/app/antigravity"]