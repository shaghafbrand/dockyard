cmd_disable() {
    require_root

    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    if [ -f "$SERVICE_FILE" ]; then
        if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
            echo "Stopping ${SERVICE_NAME}..."
            systemctl stop "${SERVICE_NAME}.service"
            echo "  stopped"
        fi
        if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
            systemctl disable "${SERVICE_NAME}.service"
            echo "  disabled"
        fi
        rm -f "$SERVICE_FILE"
        echo "Removed ${SERVICE_FILE}"
    else
        echo "Warning: ${SERVICE_FILE} does not exist." >&2
    fi

    systemctl daemon-reload
}
