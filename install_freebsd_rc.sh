#!/bin/sh

# Configuration variables
MINECRAFT_USER="minecraft"
MINECRAFT_DIR="/var/minecraft_server"
MINECRAFT_JAR="server.jar"
MEMORY_ALLOCATION="2G"
INITIAL_MEMORY="256M"
SERVICE_SCRIPT="/usr/local/etc/rc.d/minecraft"
MONITOR_SCRIPT="/usr/local/bin/minecraft_monitor.sh"
RESTART_SCRIPT="/usr/local/bin/minecraft_restart.sh"
TMUX_SOCKET="minecraft_socket"
TMUX_SESSION="minecraft_session"

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
sudo pkg update
sudo pkg install -y tmux openjdk22 wget

# Define JAVA_PATH and TMUX_PATH after installing the packages
JAVA_PATH=$(which java)
TMUX_PATH=$(which tmux)
MINECRAFT_COMMAND="$JAVA_PATH -Xmx$MEMORY_ALLOCATION -Xms$INITIAL_MEMORY -jar $MINECRAFT_JAR nogui"

# Step 2: Create the Minecraft user and directory
if ! id -u "$MINECRAFT_USER" >/dev/null 2>&1; then
    echo "Creating Minecraft user..."
    sudo pw user add "$MINECRAFT_USER" -m -s /bin/sh -c "Minecraft Server User"
else
    echo "User $MINECRAFT_USER already exists."
fi

if [ ! -d "$MINECRAFT_DIR" ]; then
    echo "Creating Minecraft server directory..."
    sudo mkdir -p "$MINECRAFT_DIR"
    sudo chown -R "$MINECRAFT_USER":"$MINECRAFT_USER" "$MINECRAFT_DIR"
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

# Step 5: Create the rc.d service script
echo "Creating the rc.d service script..."
sudo tee "$SERVICE_SCRIPT" >/dev/null <<EOF
#!/bin/sh

# PROVIDE: minecraft
# REQUIRE: LOGIN
# KEYWORD: shutdown

. /etc/rc.subr

name="minecraft"
rcvar=minecraft_enable

load_rc_config \$name

: \${minecraft_enable:="NO"}
: \${minecraft_user:="$MINECRAFT_USER"}
: \${minecraft_dir:="$MINECRAFT_DIR"}
: \${minecraft_command:="$MINECRAFT_COMMAND"}
: \${tmux_path:="$TMUX_PATH"}
: \${tmux_socket:="$TMUX_SOCKET"}
: \${tmux_session:="$TMUX_SESSION"}

start_cmd="\${name}_start"
stop_cmd="\${name}_stop"
status_cmd="\${name}_status"
log_cmd="\${name}_log"
attach_cmd="\${name}_attach"
cmd_cmd="\${name}_cmd"
reload_cmd="\${name}_reload"
extra_commands="log attach cmd reload"

minecraft_start() {
    if [ ! -d "\$minecraft_dir" ]; then
        echo "Minecraft server directory \$minecraft_dir does not exist."
        return 1
    fi

    if ! session_running; then
        echo "Starting Minecraft server..."
        su -m \$minecraft_user -c "\$tmux_path -L \$tmux_socket new-session -d -s \$tmux_session -c \$minecraft_dir \$minecraft_command"
        echo "Minecraft server started in detached tmux session '\$tmux_session'."
    else
        echo "A tmux session named '\$tmux_session' is already running."
    fi
}

minecraft_stop() {
    if session_running; then
        echo "Stopping Minecraft server..."
        if stop_server; then
            echo "Minecraft server stopped."
        else
            echo "Failed to stop Minecraft server."
        fi
    else
        echo "No tmux session named '\$tmux_session' is running."
    fi
}

minecraft_status() {
    if session_running; then
        echo "Minecraft server is running in tmux session '\$tmux_session'."
    else
        echo "Minecraft server is not running."
    fi
}

minecraft_log() {
    if [ -f "\$minecraft_dir/logs/latest.log" ]; then
        tail "\$minecraft_dir/logs/latest.log"
    else
        echo "Log file does not exist."
    fi
}

minecraft_attach() {
    if session_running; then
        su -m \$minecraft_user -c "TERM=screen-256color \$tmux_path -L \$tmux_socket attach -t \$tmux_session.0" || \
        su -m \$minecraft_user -c "TERM=screen \$tmux_path -L \$tmux_socket attach -t \$tmux_session.0"
    else
        echo "No tmux session named '\$tmux_session' is running."
    fi
}

minecraft_cmd() {
    shift 1
    if [ \$# -eq 0 ]; then
        echo "No command provided. Usage: service minecraft cmd '<command>'"
        return 1
    fi

    command="\$*"
    if session_running; then
        issue_cmd "\$command"
        echo "Command '\$command' sent to Minecraft server."
    else
        echo "No tmux session named '\$tmux_session' is running."
    fi
}

minecraft_reload() {
    if session_running; then
        issue_cmd "reload"
        echo "Reload command sent to Minecraft server."
    else
        echo "No tmux session named '\$tmux_session' is running."
    fi
}

stop_server() {
    if ! session_running; then
        echo "Server is not running!"
        return 1
    fi

    # Warn players with a 20-second countdown
    echo "Warning players..."
    for i in \$(seq 20 -1 1); do
        issue_cmd "say Shutting down in \$i second(s)"
        if [ \$((i % 5)) -eq 0 ]; then
            echo "\$i seconds remaining..."
        fi
        sleep 1
    done

    # Issue the stop command
    echo "Stopping server..."
    issue_cmd "stop"
    if [ \$? -ne 0 ]; then
        echo "Failed to send stop command to server"
        return 1
    fi

    # Wait for the server to stop
    echo "Waiting for server to stop..."
    wait=0
    while session_running; do
        sleep 1
        wait=\$((wait + 1))
        if [ \$wait -gt 60 ]; then
            echo "Could not stop server, timeout"
            return 1
        fi
    done

    echo "Server stopped successfully."
    return 0
}

session_running() {
    su -m \$minecraft_user -c "\$tmux_path -L \$tmux_socket has-session -t \$tmux_session" 2>/dev/null
}

issue_cmd() {
    command="\$*"
    su -m \$minecraft_user -c "\$tmux_path -L \$tmux_socket send-keys -t \$tmux_session.0 \"\$command\" C-m"
}

run_rc_command "\$1" "\$@"
EOF

# Make the service script executable
sudo chmod +x "$SERVICE_SCRIPT"

# Enable the service
sudo sysrc minecraft_enable="YES"

# Step 6: Create the monitoring script
echo "Creating the monitoring script..."
sudo tee "$MONITOR_SCRIPT" >/dev/null <<EOF
#!/bin/sh

# Check the status of the Minecraft server
if ! service minecraft status | grep -q "Minecraft server is running"; then
    echo "\$(date): Minecraft server is down. Restarting..."
    service minecraft start
    echo "\$(date): Minecraft server started."
else
    echo "\$(date): Minecraft server is running."
fi
EOF

# Make the monitoring script executable
sudo chmod +x "$MONITOR_SCRIPT"

# Step 7: Create the restart script
echo "Creating the restart script..."
sudo tee "$RESTART_SCRIPT" >/dev/null <<EOF
#!/bin/sh

echo "\$(date): Restarting Minecraft server..."
service minecraft stop
sleep 20  # Wait for 20 seconds to ensure the server has stopped completely
service minecraft start
echo "\$(date): Minecraft server restarted."
EOF

# Make the restart script executable
sudo chmod +x "$RESTART_SCRIPT"

# Step 8: Set up cron jobs without creating duplicates
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

echo "Setup complete. The Minecraft server will be managed as a service and monitored via cron jobs."
