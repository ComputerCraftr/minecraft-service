#!/bin/sh

# Configuration variables
MINECRAFT_USER="minecraft"
MINECRAFT_GROUP="minecraft"
MINECRAFT_DIR="/var/minecraft_server"
MINECRAFT_JAR="server.jar"
MEMORY_ALLOCATION="2G"
INITIAL_MEMORY="256M"
TMUX_SOCKET="minecraft_socket"
TMUX_SESSION="minecraft_session"
TMUX_PATH=$(which tmux)
JAVA_PATH=$(which java)
PID_FILE="$MINECRAFT_DIR/minecraft_server.pid"
MINECRAFT_COMMAND="$JAVA_PATH -Xmx$MEMORY_ALLOCATION -Xms$INITIAL_MEMORY -jar $MINECRAFT_JAR nogui"

# Function to run a command as MINECRAFT_USER if the current user is not MINECRAFT_USER
run_as_minecraft_user() {
    if [ "$(id -u -n)" = "$MINECRAFT_USER" ]; then
        $@
    else
        su -m $MINECRAFT_USER -c "$@"
    fi
}

minecraft_start() {
    if [ ! -d "$MINECRAFT_DIR" ]; then
        echo "Minecraft server directory $MINECRAFT_DIR does not exist."
        return 1
    fi

    if ! session_running; then
        echo "Starting Minecraft server..."
        run_as_minecraft_user "$TMUX_PATH -L $TMUX_SOCKET new-session -d -s $TMUX_SESSION -c $MINECRAFT_DIR $MINECRAFT_COMMAND"
        echo "Minecraft server started in detached tmux session '$TMUX_SESSION'."
        pid=$(run_as_minecraft_user "$TMUX_PATH -L $TMUX_SOCKET list-panes -t $TMUX_SESSION -F '#{pane_pid}'")
        if [ "$(echo $pid | wc -l)" -ne 1 ]; then
            echo "Could not determine PID, multiple active sessions"
            return 1
        fi
        echo -n $pid > "$PID_FILE"
    else
        echo "A tmux session named '$TMUX_SESSION' is already running."
    fi
}

session_running() {
    run_as_minecraft_user "$TMUX_PATH -L $TMUX_SOCKET has-session -t $TMUX_SESSION" 2>/dev/null
}

issue_cmd() {
    command="$*"
    run_as_minecraft_user "$TMUX_PATH -L $TMUX_SOCKET send-keys -t $TMUX_SESSION.0 \"$command\" C-m"
}

minecraft_stop() {
    if ! session_running; then
        echo "Server is not running!"
        return 1
    fi

    # Warn players with a 20-second countdown
    echo "Warning players..."
    for i in $(seq 20 -1 1); do
        issue_cmd "say Shutting down in $i second(s)"
        if [ $((i % 5)) -eq 0 ]; then
            echo "$i seconds remaining..."
        fi
        sleep 1
    done

    # Issue the stop command
    echo "Stopping server..."
    issue_cmd "stop"
    if [ $? -ne 0 ]; then
        echo "Failed to send stop command to server"
        return 1
    fi

    # Wait for the server to stop
    echo "Waiting for server to stop..."
    wait=0
    while session_running; do
        sleep 1
        wait=$((wait + 1))
        if [ $wait -gt 60 ]; then
            echo "Could not stop server, timeout"
            return 1
        fi
    done

    echo "Server stopped successfully."
    [ -f "$PID_FILE" ] && rm "$PID_FILE"
    return 0
}

minecraft_log() {
    if [ -f "$MINECRAFT_DIR/logs/latest.log" ]; then
        tail -f "$MINECRAFT_DIR/logs/latest.log"
    else
        echo "Log file does not exist."
    fi
}

minecraft_attach() {
    if session_running; then
        run_as_minecraft_user "TERM=screen-256color $TMUX_PATH -L $TMUX_SOCKET attach -t $TMUX_SESSION.0" || \
        run_as_minecraft_user "TERM=screen $TMUX_PATH -L $TMUX_SOCKET attach -t $TMUX_SESSION.0"
    else
        echo "No tmux session named '$TMUX_SESSION' is running."
    fi
}

minecraft_cmd() {
    if [ $# -eq 0 ]; then
        echo "No command provided. Usage: $0 cmd '<command>'"
        return 1
    fi

    command="$*"
    if session_running; then
        issue_cmd "$command"
        echo "Command '$command' sent to Minecraft server."
    else
        echo "No tmux session named '$TMUX_SESSION' is running."
    fi
}

minecraft_reload() {
    if session_running; then
        issue_cmd "reload"
        echo "Reload command sent to Minecraft server."
    else
        echo "No tmux session named '$TMUX_SESSION' is running."
    fi
}

minecraft_status() {
    if session_running; then
        echo "Minecraft server is running in tmux session '$TMUX_SESSION'."
    else
        echo "Minecraft server is not running."
    fi
}

case "$1" in
    start)
        minecraft_start
        ;;
    stop)
        minecraft_stop
        ;;
    log)
        minecraft_log
        ;;
    attach)
        minecraft_attach
        ;;
    cmd)
        shift
        minecraft_cmd "$@"
        ;;
    reload)
        minecraft_reload
        ;;
    status)
        minecraft_status
        ;;
    *)
        echo "Usage: $0 {start|stop|log|attach|cmd|reload|status}"
        exit 2
        ;;
esac
