#!/bin/bash

# Define variables
PLUGIN_ARCHIVE="inode_usage.tar.gz"
DATA_ARCHIVE="data.zip"
PLUGIN_DIR="/usr/local/cpanel/base/frontend/jupiter/inode_usage"
JUPITER_THEME_DIR="/usr/local/cpanel/base/frontend/jupiter"
CURRENT_DIR=$(pwd)
PLUGIN_URL="https://dragosboroianu.com/inode_usage.tar.gz"
DATA_URL="https://dragosboroianu.com/data.zip"

# Step 1: Download the inode_usage.tar.gz (cPanel plugin archive) using wget
echo "Downloading the inode_usage.tar.gz plugin archive..."
if wget -O "$PLUGIN_ARCHIVE" "$PLUGIN_URL"; then
    echo "Plugin archive download complete."
else
    echo "Failed to download $PLUGIN_ARCHIVE."
    exit 1
fi

# Step 2: Install the cPanel plugin
echo "Installing the cPanel plugin..."
if /usr/local/cpanel/scripts/install_plugin "$CURRENT_DIR/$PLUGIN_ARCHIVE"; then
    echo "Plugin installation complete."
else
    echo "Plugin installation failed."
    exit 1
fi

# Step 3: Remove the cPanel plugin archive
echo "Removing the plugin archive..."
if rm -f "$CURRENT_DIR/$PLUGIN_ARCHIVE"; then
    echo "Plugin archive removed."
else
    echo "Failed to remove the plugin archive."
    exit 1
fi

# Step 4: Download the data.zip (necessary files for the Jupiter theme)
echo "Downloading the data.zip archive..."
if wget -O "$DATA_ARCHIVE" "$DATA_URL"; then
    echo "Data archive download complete."
else
    echo "Failed to download $DATA_ARCHIVE."
    exit 1
fi

# Step 5: Move the data.zip to the Jupiter theme directory
echo "Moving data archive to $JUPITER_THEME_DIR..."
if mv "$CURRENT_DIR/$DATA_ARCHIVE" "$JUPITER_THEME_DIR"; then
    echo "Data archive moved."
else
    echo "Failed to move data archive."
    exit 1
fi

# Step 6: Extract the data.zip inside the Jupiter theme directory
echo "Extracting data archive in $JUPITER_THEME_DIR..."
cd "$JUPITER_THEME_DIR" || exit
if unzip "$DATA_ARCHIVE"; then
    echo "Data archive extracted."
else
    echo "Failed to extract data archive."
    exit 1
fi

# Step 7: Remove the data archive
echo "Removing the data archive..."
if rm -f "$DATA_ARCHIVE"; then
    echo "Data archive removed."
else
    echo "Failed to remove data archive."
    exit 1
fi

# Step 8: Clean up the installer
cd "$CURRENT_DIR" || exit
echo "Cleaning up the installer..."
if rm -f "$0"; then
    echo "Installation complete. Installer removed."
    echo "The cPanel Inode Usage Plugin has been successfully installed!"
else
    echo "Failed to clean up the installer."
    exit 1
fi
