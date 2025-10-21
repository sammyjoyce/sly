#!/bin/bash
set -e

# Only run in remote (web) environments
if [ "$CLAUDE_CODE_REMOTE" != "true" ]; then
  exit 0
fi

echo "Setting up Zig environment for sly..."

# Check if Zig is already available on the system
if command -v zig >/dev/null 2>&1; then
  EXISTING_VERSION=$(zig version)
  echo "Zig already available: $EXISTING_VERSION"
  echo "Skipping installation"
else
  # Install Zig 0.15.2
  ZIG_VERSION="0.15.2"
  ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
  ZIG_DIR="$HOME/zig"

  if [ ! -d "$ZIG_DIR" ]; then
    echo "Installing Zig ${ZIG_VERSION}..."
    mkdir -p "$HOME/zig-tmp"
    cd "$HOME/zig-tmp"
    curl -L -o zig.tar.xz "$ZIG_URL"
    tar -xf zig.tar.xz
    mv "zig-x86_64-linux-${ZIG_VERSION}" "$ZIG_DIR"
    cd "$CLAUDE_PROJECT_DIR"
    rm -rf "$HOME/zig-tmp"
    echo "Zig installed to $ZIG_DIR"
    
    # Add Zig to PATH for this session
    export PATH="$ZIG_DIR:$PATH"
    
    # Persist the PATH for subsequent commands
    echo "export PATH=\"$ZIG_DIR:\$PATH\"" >> "$CLAUDE_ENV_FILE"
  else
    echo "Zig already installed at $ZIG_DIR"
    export PATH="$ZIG_DIR:$PATH"
    echo "export PATH=\"$ZIG_DIR:\$PATH\"" >> "$CLAUDE_ENV_FILE"
  fi
fi

# Install libcurl (required dependency)
if ! dpkg -l | grep -q libcurl4-openssl-dev; then
  echo "Installing libcurl development headers..."
  sudo apt-get update -qq
  sudo apt-get install -y libcurl4-openssl-dev
fi

# Verify Zig installation
echo "Verifying Zig installation..."
zig version

echo "✓ Environment setup complete"
exit 0
