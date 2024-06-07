#!/bin/sh

# Configuration variables for Minecraft server setup
MINECRAFT_USER="minecraft"
MINECRAFT_GROUP="minecraft"
MINECRAFT_DIR="/var/minecraft_server"
MINECRAFT_JAR="server.jar"
SERVICE_SH="/usr/local/bin/minecraft_service.sh"
MONITOR_SCRIPT="/usr/local/bin/minecraft_monitor.sh"
RESTART_SCRIPT="/usr/local/bin/minecraft_restart.sh"
PID_FILE="$MINECRAFT_DIR/minecraft_server.pid"
MEMORY_ALLOCATION="4G"
INITIAL_MEMORY="256M"
TMUX_SOCKET="minecraft_socket"
TMUX_SESSION="minecraft_session"
