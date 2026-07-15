#!/bin/bash
#
# Locado Installer
# https://locado.hxd.app
#
# Usage: curl -fsSL https://locado.hxd.app/install.sh | bash
#
# This script will:
# 1. Download and install the latest locado binary
# 2. Install dnsmasq for wildcard DNS resolution
# 3. Configure dnsmasq for *.local domains
# 4. Install and start locado as a system service
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Print colored output
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Banner
echo ""
echo "  _                        _       "
echo " | |    ___   ___ __ _  __| | ___  "
echo " | |   / _ \ / __/ _\` |/ _\` |/ _ \ "
echo " | |__| (_) | (_| (_| | (_| | (_) |"
echo " |_____\___/ \___\__,_|\__,_|\___/ "
echo ""
echo "  Local Domain Manager"
echo "  https://locado.hxd.app"
echo ""

# ============================================
# UPGRADE DETECTION
# ============================================
UPGRADE_MODE=false
OLD_VERSION=""

if command -v locado &> /dev/null; then
    UPGRADE_MODE=true
    OLD_VERSION=$(locado --version 2>/dev/null | awk '{print $NF}' || echo "unknown")
    info "Existing installation detected: $OLD_VERSION"
fi

# Detect OS
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$OS" in
  darwin)
    OS="darwin"
    info "Detected macOS"
    ;;
  linux)
    OS="linux"
    info "Detected Linux"
    ;;
  mingw*|msys*|cygwin*)
    error "Windows is not supported via this script. Please download manually from GitHub releases."
    ;;
  *)
    error "Unsupported operating system: $OS"
    ;;
esac

# Detect Architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)
    ARCH="amd64"
    info "Detected architecture: x86_64 (amd64)"
    ;;
  arm64|aarch64)
    ARCH="arm64"
    info "Detected architecture: ARM64"
    ;;
  *)
    error "Unsupported architecture: $ARCH"
    ;;
esac

# GitHub repo
REPO="xuandung38/locado"

# ============================================
# STEP 1: Download and Install Binary
# ============================================
step "Downloading Locado binary..."

# Get latest version
info "Fetching latest version..."
VERSION=$(curl -s "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)

if [ -z "$VERSION" ]; then
  error "Failed to get latest version. Check your internet connection."
fi

info "Latest version: $VERSION"

# Download URL
FILENAME="locado-${OS}-${ARCH}.tar.gz"
URL="https://github.com/${REPO}/releases/download/${VERSION}/${FILENAME}"

info "Downloading $FILENAME..."

# Create temp directory
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Download and extract
if ! curl -sL "$URL" -o "$TMPDIR/$FILENAME"; then
  error "Failed to download $URL"
fi

if ! tar -xzf "$TMPDIR/$FILENAME" -C "$TMPDIR"; then
  error "Failed to extract $FILENAME"
fi

# Check if binary exists
if [ ! -f "$TMPDIR/locado" ]; then
  error "Binary not found in archive"
fi

# Install location
INSTALL_DIR="/usr/local/bin"
BINARY_PATH="$TMPDIR/locado"

# Make sure binary is executable
chmod +x "$BINARY_PATH"

# Install binary
info "Installing to $INSTALL_DIR..."

# Handle upgrade: stop service and create backup
if [ "$UPGRADE_MODE" = true ]; then
    step "Upgrading from $OLD_VERSION to $VERSION..."

    # Stop service before replacing binary (use launchctl/systemctl directly to avoid binary issues)
    if [ "$OS" = "darwin" ]; then
        if sudo launchctl list 2>/dev/null | grep -q "com.locado.app"; then
            info "Stopping existing service..."
            sudo launchctl bootout system/com.locado.app 2>/dev/null || true
            sleep 1
        fi
    else
        if systemctl is-active --quiet locado 2>/dev/null; then
            info "Stopping existing service..."
            sudo systemctl stop locado 2>/dev/null || true
            sleep 1
        fi
    fi

    # Create backup
    if [ -f "$INSTALL_DIR/locado" ]; then
        info "Creating backup..."
        sudo cp "$INSTALL_DIR/locado" "$INSTALL_DIR/locado.bak" 2>/dev/null || true
    fi
fi

if [ -w "$INSTALL_DIR" ]; then
  cp "$BINARY_PATH" "$INSTALL_DIR/locado"
  # Remove extended attributes that trigger macOS Gatekeeper
  xattr -cr "$INSTALL_DIR/locado" 2>/dev/null || true
  # Ad-hoc sign binary to bypass Gatekeeper on macOS
  if [ "$OS" = "darwin" ]; then
    codesign --sign - --force "$INSTALL_DIR/locado" 2>/dev/null || true
  fi
else
  # Use cp instead of mv to avoid issues with cross-filesystem moves
  sudo cp "$BINARY_PATH" "$INSTALL_DIR/locado"
  sudo chmod +x "$INSTALL_DIR/locado"
  # Remove extended attributes that trigger macOS Gatekeeper
  sudo xattr -cr "$INSTALL_DIR/locado" 2>/dev/null || true
  # Ad-hoc sign binary to bypass Gatekeeper on macOS
  if [ "$OS" = "darwin" ]; then
    sudo codesign --sign - --force "$INSTALL_DIR/locado" 2>/dev/null || true
  fi
fi

# Verify installation
if ! command -v locado &> /dev/null; then
  error "Installation failed. 'locado' command not found."
fi

info "Locado $VERSION installed to $INSTALL_DIR/locado"
echo ""

# ============================================
# STEP 2: Install dnsmasq (skip on upgrade)
# ============================================
if [ "$UPGRADE_MODE" = true ]; then
    step "Skipping DNS setup (upgrade mode - config preserved)"
else
    step "Setting up DNS (dnsmasq)..."
fi

install_dnsmasq_darwin() {
  # Check if Homebrew is installed
  if ! command -v brew &> /dev/null; then
    warn "Homebrew not found. Installing Homebrew first..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  # Check if dnsmasq is installed
  if brew list dnsmasq &> /dev/null; then
    info "dnsmasq already installed"
  else
    info "Installing dnsmasq via Homebrew..."
    brew install dnsmasq
  fi

  # Configure dnsmasq for *.local
  DNSMASQ_CONF="/opt/homebrew/etc/dnsmasq.conf"
  if [ ! -f "$DNSMASQ_CONF" ]; then
    DNSMASQ_CONF="/usr/local/etc/dnsmasq.conf"
  fi

  # Create dnsmasq.d directory
  DNSMASQ_D_DIR="$(dirname $DNSMASQ_CONF)/dnsmasq.d"
  sudo mkdir -p "$DNSMASQ_D_DIR"

  # Add locado config
  if [ ! -f "$DNSMASQ_D_DIR/locado.conf" ]; then
    info "Configuring dnsmasq for *.local domains..."
    echo "address=/local/127.0.0.1" | sudo tee "$DNSMASQ_D_DIR/locado.conf" > /dev/null

    # Ensure main config includes dnsmasq.d
    if ! grep -q "conf-dir=$DNSMASQ_D_DIR" "$DNSMASQ_CONF" 2>/dev/null; then
      echo "conf-dir=$DNSMASQ_D_DIR" | sudo tee -a "$DNSMASQ_CONF" > /dev/null
    fi
  else
    info "dnsmasq locado config already exists"
  fi

  # Create resolver directory for macOS
  sudo mkdir -p /etc/resolver

  # Add resolver for .local domain
  if [ ! -f "/etc/resolver/local" ]; then
    info "Creating DNS resolver for .local..."
    echo "nameserver 127.0.0.1" | sudo tee /etc/resolver/local > /dev/null
  else
    info "DNS resolver for .local already exists"
  fi

  # Start/restart dnsmasq
  info "Starting dnsmasq service..."
  sudo brew services restart dnsmasq 2>/dev/null || sudo brew services start dnsmasq
}

install_dnsmasq_linux() {
  # Detect package manager
  if command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt"
  elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
  elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
  elif command -v pacman &> /dev/null; then
    PKG_MANAGER="pacman"
  else
    warn "Unknown package manager. Please install dnsmasq manually."
    return 1
  fi

  # Check if dnsmasq is installed
  if command -v dnsmasq &> /dev/null; then
    info "dnsmasq already installed"
  else
    info "Installing dnsmasq..."
    case "$PKG_MANAGER" in
      apt)
        sudo apt-get update -qq
        sudo apt-get install -y dnsmasq
        ;;
      dnf|yum)
        sudo $PKG_MANAGER install -y dnsmasq
        ;;
      pacman)
        sudo pacman -S --noconfirm dnsmasq
        ;;
    esac
  fi

  # Configure dnsmasq
  DNSMASQ_D_DIR="/etc/dnsmasq.d"
  sudo mkdir -p "$DNSMASQ_D_DIR"

  if [ ! -f "$DNSMASQ_D_DIR/locado.conf" ]; then
    info "Configuring dnsmasq for *.local domains..."
    echo "address=/local/127.0.0.1" | sudo tee "$DNSMASQ_D_DIR/locado.conf" > /dev/null
  else
    info "dnsmasq locado config already exists"
  fi

  # Handle systemd-resolved conflict (Ubuntu/Fedora)
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    warn "systemd-resolved detected. Configuring to use dnsmasq..."

    # Option 1: Point resolved to dnsmasq
    RESOLVED_CONF="/etc/systemd/resolved.conf.d/locado.conf"
    sudo mkdir -p /etc/systemd/resolved.conf.d

    if [ ! -f "$RESOLVED_CONF" ]; then
      cat << EOF | sudo tee "$RESOLVED_CONF" > /dev/null
[Resolve]
DNS=127.0.0.1
Domains=~local
EOF
      sudo systemctl restart systemd-resolved
    fi
  fi

  # Enable and start dnsmasq
  info "Starting dnsmasq service..."
  sudo systemctl enable dnsmasq 2>/dev/null || true
  sudo systemctl restart dnsmasq
}

# Only run dnsmasq setup on fresh install
if [ "$UPGRADE_MODE" = false ]; then
    case "$OS" in
      darwin) install_dnsmasq_darwin ;;
      linux)  install_dnsmasq_linux ;;
    esac
fi

echo ""

# ============================================
# STEP 3: Install/Restart Locado Service
# ============================================
if [ "$UPGRADE_MODE" = true ]; then
    step "Restarting Locado service..."
    # Use launchctl/systemctl directly to avoid issues with unsigned binary
    if [ "$OS" = "darwin" ]; then
        info "Running: launchctl bootstrap system /Library/LaunchDaemons/com.locado.app.plist"
        if sudo launchctl bootstrap system /Library/LaunchDaemons/com.locado.app.plist 2>/dev/null; then
            info "Locado service restarted"
        else
            # Service might already be bootstrapped, try kickstart
            sudo launchctl kickstart -k system/com.locado.app 2>/dev/null && info "Locado service restarted" || warn "Service restart failed. Try: sudo locado service start"
        fi
    else
        info "Running: systemctl start locado"
        if sudo systemctl start locado; then
            info "Locado service restarted"
        else
            warn "Service restart failed. Try: sudo locado service start"
        fi
    fi
else
    step "Installing Locado service..."
    info "Running: sudo locado service install"
    if sudo locado service install; then
        info "Locado service installed and started"
    else
        warn "Service installation failed. You can install manually with: sudo locado service install"
    fi
fi

echo ""

# ============================================
# STEP 4: Verify Setup
# ============================================
step "Verifying installation..."

# Check if service is running
sleep 2  # Wait for service to start

if curl -s http://localhost:2280/api/health > /dev/null 2>&1; then
  info "Locado service is running!"
else
  warn "Service may not be running yet. Check with: locado service status"
fi

# Test DNS resolution
if [ "$OS" == "darwin" ]; then
  if ping -c 1 -W 1 test.local > /dev/null 2>&1; then
    info "DNS resolution working! (test.local -> 127.0.0.1)"
  else
    warn "DNS may need a moment to propagate. Try: ping test.local"
  fi
fi

echo ""

# ============================================
# Success Message
# ============================================
if [ "$UPGRADE_MODE" = true ]; then
    printf "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║                                                           ║${NC}\n"
    printf "${GREEN}║         Locado upgraded to %-7s successfully!          ║${NC}\n" "$VERSION"
    printf "${GREEN}║                                                           ║${NC}\n"
    printf "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}\n"
    echo ""
    printf "  Previous version: ${YELLOW}$OLD_VERSION${NC}\n"
    printf "  Backup available: ${YELLOW}$INSTALL_DIR/locado.bak${NC}\n"
    echo ""
    echo "  To rollback if needed:"
    printf "    ${YELLOW}sudo locado update rollback${NC}\n"
    echo ""
    printf "  Dashboard: ${CYAN}http://localhost:2280${NC}\n"
else
    printf "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║                                                           ║${NC}\n"
    printf "${GREEN}║          Locado %-7s installed successfully!           ║${NC}\n" "$VERSION"
    printf "${GREEN}║                                                           ║${NC}\n"
    printf "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}\n"
    echo ""
    printf "  Dashboard: ${CYAN}http://localhost:2280${NC}\n"
    echo ""
    echo "  Quick Start:"
    echo "    1. Open dashboard at http://localhost:2280"
    echo "    2. Add a domain (e.g., myapp.local -> localhost:3000)"
    echo "    3. Access https://myapp.local in your browser"
fi
echo ""
echo "  Service Commands:"
printf "    ${YELLOW}locado service status${NC}        - Check service status\n"
printf "    ${YELLOW}sudo locado service stop${NC}     - Stop service\n"
printf "    ${YELLOW}sudo locado service start${NC}    - Start service\n"
printf "    ${YELLOW}sudo locado service restart${NC}  - Restart service\n"
echo ""
echo "  Update Locado:"
printf "    ${YELLOW}locado update check${NC}   - Check for updates\n"
printf "    ${YELLOW}locado update apply${NC}   - Apply available update\n"
echo ""
info "For more info, visit https://locado.hxd.app"
echo ""
