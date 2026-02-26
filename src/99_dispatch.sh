# ── Dispatch ─────────────────────────────────────────────────

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    gen-env)
        cmd_gen_env "$@"
        ;;
    create)
        if ! try_load_env; then
            echo "No config found — auto-generating with random networks..."
            cmd_gen_env
            load_env
        fi
        derive_vars
        cmd_create "$@"
        ;;
    enable)
        load_env
        derive_vars
        cmd_enable
        ;;
    disable)
        load_env
        derive_vars
        cmd_disable
        ;;
    start)
        load_env
        derive_vars
        cmd_start
        ;;
    stop)
        load_env
        derive_vars
        cmd_stop
        ;;
    status)
        load_env
        derive_vars
        cmd_status
        ;;
    verify)
        load_env
        derive_vars
        cmd_verify
        ;;
    destroy)
        load_env
        derive_vars
        cmd_destroy "$@"
        ;;
    -h|--help|"")
        usage
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        usage
        ;;
esac
