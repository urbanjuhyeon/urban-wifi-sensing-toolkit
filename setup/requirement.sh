#!/bin/bash

# Update system packages
echo "Updating system packages..."
sudo apt-get update -y
sudo apt-get upgrade -y

# Install Python3 and Pip3
echo "Installing Python3 and Pip3..."
sudo apt-get install python3 python3-pip -y

# Install libpcap
echo "Installing libpcap..."
sudo apt-get install libpcap0.8 -y
sudo apt-get install libpcap-dev -y

# Install necessary Python packages
echo "Installing necessary Python packages..."
pip3 install pcapy dpkt

# Install git
echo "Installing Git..."
sudo apt-get install git -y
sudo apt-get install ntpdate -y

# Install Bluetooth library
echo "Installing Bluetooth library..."
sudo apt-get install libbluetooth-dev -y

# Check if Bluelog directory already exists
if [ ! -d "/home/pi/Bluelog" ]; then
  # Clone Bluelog from GitHub
  echo "Cloning Bluelog from GitHub..."
  git clone https://github.com/MS3FGX/Bluelog.git

  # Change into the Bluelog directory
  cd Bluelog

  # Build Bluelog from source
  echo "Building Bluelog from source..."
  make
  sudo make install

  # Return to the original directory
  cd ..
else
  echo "Bluelog already exists. Skipping Bluelog installation..."
fi