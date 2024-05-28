#!/bin/sh

# Exit on errors and undefined variables
set -eu

# Configuration variables
MINECRAFT_USER="minecraft"
MINECRAFT_GROUP="minecraft"
MINECRAFT_DIR="/var/minecraft_server"
MINECRAFT_JAR="server.jar"
SERVICE_SCRIPT="/etc/systemd/system/minecraft.service"
SERVICE_SH="/usr/local/bin/minecraft_service.sh"
MONITOR_SCRIPT="/usr/local/bin/minecraft_monitor.sh"
RESTART_SCRIPT="/usr/local/bin/minecraft_restart.sh"
PID_FILE="$MINECRAFT_DIR/minecraft_server.pid"

# Check for -nodownload option
NODOWNLOAD=0
for arg in "$@"; do
    case $arg in
    -nodownload)
        NODOWNLOAD=1
        shift
        ;;
    esac
done

# Step 1: Install necessary packages
echo "Installing necessary packages..."
sudo apt-get update
sudo apt-get install -y tmux openjdk-21-jdk-headless wget

# Check if necessary commands are available
command -v tmux >/dev/null 2>&1 || { echo "tmux is required but it's not installed. Aborting." >&2; exit 1; }
command -v java >/dev/null 2>&1 || { echo "java is required but it's not installed. Aborting." >&2; exit 1; }
command -v wget >/dev/null 2>&1 || { echo "wget is required but it's not installed. Aborting." >&2; exit 1; }

# Step 2: Create the Minecraft user and directory
if ! id -u "$MINECRAFT_USER" >/dev/null 2>&1; then
    echo "Creating Minecraft user..."
    sudo useradd --system --home "$MINECRAFT_DIR" --shell /bin/sh "$MINECRAFT_USER"
else
    echo "User $MINECRAFT_USER already exists."
fi

if ! getent group "$MINECRAFT_GROUP" >/dev/null 2>&1; then
    sudo groupadd "$MINECRAFT_GROUP"
fi

if [ ! -d "$MINECRAFT_DIR" ]; then
    echo "Creating Minecraft server directory..."
    sudo mkdir -p "$MINECRAFT_DIR"
    sudo chown -R "$MINECRAFT_USER":"$MINECRAFT_GROUP" "$MINECRAFT_DIR"
else
    echo "Minecraft server directory already exists."
fi

# Step 3: Download Minecraft server jar if not in -nodownload mode
if [ $NODOWNLOAD -eq 0 ]; then
    echo "Please enter the download URL for the Minecraft server jar:"
    read -r DOWNLOAD_URL

    echo "Downloading Minecraft server jar..."
    if ! su -m "$MINECRAFT_USER" -c "wget -O $MINECRAFT_DIR/$MINECRAFT_JAR $DOWNLOAD_URL"; then
        echo "Failed to download the Minecraft server jar. Exiting..."
        exit 1
    fi
else
    echo "Skipping download of Minecraft server jar due to -nodownload option."
fi

# Step 4: Accept the Minecraft EULA
echo "Accepting the Minecraft EULA..."
su -m "$MINECRAFT_USER" -c "echo 'eula=true' > $MINECRAFT_DIR/eula.txt"

# Step 5: Copy the minecraft_service.sh script
echo "Copying the minecraft_service.sh script..."
sudo cp minecraft_service.sh "$SERVICE_SH"

# Make the minecraft_service.sh script executable
sudo chmod +x "$SERVICE_SH"

# Step 6: Create the systemd service unit
echo "Creating the systemd service unit..."
sudo tee "$SERVICE_SCRIPT" >/dev/null <<EOF
[Unit]
Description=Minecraft Server
After=network.target

[Service]
User=$MINECRAFT_USER
Group=$MINECRAFT_GROUP
WorkingDirectory=$MINECRAFT_DIR
ExecStart=$SERVICE_SH start
ExecStop=$SERVICE_SH stop
ExecReload=$SERVICE_SH reload
PIDFile=$PID_FILE
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

# Step 7: Reload systemd and enable the service
echo "Reloading systemd and enabling the Minecraft service..."
sudo systemctl daemon-reload
sudo systemctl enable minecraft.service

# Step 8: Create the monitoring script
echo "Creating the monitoring script..."
sudo tee "$MONITOR_SCRIPT" >/dev/null <<EOF
#!/bin/sh

# Check the status of the Minecraft server
if ! systemctl is-active --quiet minecraft.service; then
    echo "\$(date): Minecraft server is down. Restarting..."
    systemctl start minecraft.service
    echo "\$(date): Minecraft server started."
else
    echo "\$(date): Minecraft server is running."
fi
EOF

# Make the monitoring script executable
sudo chmod +x "$MONITOR_SCRIPT"

# Step 9: Create the restart script
echo "Creating the restart script..."
sudo tee "$RESTART_SCRIPT" >/dev/null <<EOF
#!/bin/sh

echo "\$(date): Restarting Minecraft server..."
systemctl restart minecraft.service
echo "\$(date): Minecraft server restarted."
EOF

# Make the restart script executable
sudo chmod +x "$RESTART_SCRIPT"

# Step 10: Set up cron jobs without creating duplicates
echo "Setting up cron jobs..."
current_crontab=$(sudo crontab -l 2>/dev/null || true)

monitor_cron="*/30 * * * * $MONITOR_SCRIPT >> /var/log/minecraft_monitor.log 2>&1"
restart_cron="0 4 * * * $RESTART_SCRIPT >> /var/log/minecraft_restart.log 2>&1"

temp_crontab=$(mktemp)

# Copy existing crontab to temp file
echo "$current_crontab" >"$temp_crontab"

# Only add the monitor cron job if it doesn't already exist
if ! grep -q "$MONITOR_SCRIPT" "$temp_crontab"; then
    echo "$monitor_cron" >>"$temp_crontab"
else
    echo "Monitor cron job already exists. Skipping..."
fi

# Only add the restart cron job if it doesn't already exist
if ! grep -q "$RESTART_SCRIPT" "$temp_crontab"; then
    echo "$restart_cron" >>"$temp_crontab"
else
    echo "Restart cron job already exists. Skipping..."
fi

# Install the new crontab
sudo crontab "$temp_crontab"

# Clean up
rm "$temp_crontab"

echo "Setup complete. The Minecraft server is installed, but it is not yet started."
echo "You can start the Minecraft server with: sudo systemctl start minecraft.service"
