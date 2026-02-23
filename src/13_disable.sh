cmd_disable() {
    require_root

    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    local SYSBOX_SERVICE_FILE="/etc/systemd/system/${SYSBOX_SERVICE_NAME}.service"

    # Stop and disable docker service
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

    # Stop and disable shared sysbox service only if no other dockyard docker services remain
    # (SERVICE_NAME file was already removed above, so count remaining *_docker.service files)
    # Use 'find' instead of 'ls glob | wc' to avoid pipefail exit when no files match.
    local remaining_docker
    remaining_docker=$(find /etc/systemd/system -maxdepth 1 -name '*_docker.service' 2>/dev/null | wc -l)
    if [ "$remaining_docker" -eq 0 ] && [ -f "$SYSBOX_SERVICE_FILE" ]; then
        echo "Last dockyard instance — stopping shared ${SYSBOX_SERVICE_NAME}..."
        if systemctl is-active --quiet "${SYSBOX_SERVICE_NAME}.service"; then
            systemctl stop "${SYSBOX_SERVICE_NAME}.service"
            echo "  stopped"
        fi
        if systemctl is-enabled --quiet "${SYSBOX_SERVICE_NAME}.service" 2>/dev/null; then
            systemctl disable "${SYSBOX_SERVICE_NAME}.service"
            echo "  disabled"
        fi
        rm -f "$SYSBOX_SERVICE_FILE"
        echo "Removed ${SYSBOX_SERVICE_FILE}"
    elif [ "$remaining_docker" -gt 0 ]; then
        echo "  ${remaining_docker} other dockyard instance(s) still active — keeping ${SYSBOX_SERVICE_NAME}.service"
    fi

    systemctl daemon-reload
}
