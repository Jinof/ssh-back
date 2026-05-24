import Foundation

public enum BrowserShimCommand {
  public static func remoteShimPath(remoteBridgePort: Int) throws -> String {
    guard CallbackParser.isSupportedCallbackPort(remoteBridgePort) else {
      throw SSHBackError.invalidPort(remoteBridgePort)
    }

    return "~/.ssh-back/browser"
  }

  public static func exportCommand(remoteBridgePort: Int) throws -> String {
    guard CallbackParser.isSupportedCallbackPort(remoteBridgePort) else {
      throw SSHBackError.invalidPort(remoteBridgePort)
    }

    return #"export BROWSER="$HOME/.ssh-back/browser"; echo "BROWSER=$BROWSER""#
  }

  public static func scriptContents(remoteBridgePort: Int) throws -> String {
    guard CallbackParser.isSupportedCallbackPort(remoteBridgePort) else {
      throw SSHBackError.invalidPort(remoteBridgePort)
    }

    return #"""
    #!/bin/sh
    exec python3 - "$1" <<'PY'
    import sys
    import urllib.parse
    import urllib.request

    if len(sys.argv) < 2:
        raise SystemExit("missing url")

    urllib.request.urlopen(
        "http://127.0.0.1:\#(remoteBridgePort)/open?url=" + urllib.parse.quote(sys.argv[1], safe=""),
        timeout=10,
    ).read()
    PY
    """#
  }

  public static func installScript(remoteBridgePort: Int) throws -> String {
    guard CallbackParser.isSupportedCallbackPort(remoteBridgePort) else {
      throw SSHBackError.invalidPort(remoteBridgePort)
    }

    let script = try scriptContents(remoteBridgePort: remoteBridgePort)
    return """
    set -eu
    mkdir -p "$HOME/.ssh-back"
    chmod 700 "$HOME/.ssh-back"
    cat > "$HOME/.ssh-back/browser" <<'SSH_BACK_BROWSER'
    \(script)
    SSH_BACK_BROWSER
    chmod 700 "$HOME/.ssh-back/browser"
    test -x "$HOME/.ssh-back/browser"

    default_shell="${SHELL:-}"
    if [ -z "$default_shell" ] && command -v getent >/dev/null 2>&1; then
      default_shell="$(getent passwd "$(id -un)" 2>/dev/null | awk -F: '{print $7; exit}')"
    fi
    if [ -z "$default_shell" ] && [ -r /etc/passwd ]; then
      default_shell="$(awk -F: -v user="$(id -un)" '$1 == user { print $7; exit }' /etc/passwd)"
    fi
    if [ -z "$default_shell" ] && command -v dscl >/dev/null 2>&1; then
      default_shell="$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null | awk '{print $2; exit}')"
    fi

    shell_name="${default_shell##*/}"
    case "$shell_name" in
      zsh)
        rc_file="$HOME/.zshrc"
        rc_display="~/.zshrc"
        ;;
      bash)
        rc_file="$HOME/.bashrc"
        rc_display="~/.bashrc"
        ;;
      *)
        echo "Unsupported default shell for ssh-back Browser export: ${default_shell:-unknown}" >&2
        exit 64
        ;;
    esac

    begin_marker="# >>> ssh-back browser shim >>>"
    end_marker="# <<< ssh-back browser shim <<<"
    [ -e "$rc_file" ] || : > "$rc_file"
    tmp_file="${rc_file}.ssh-back.$$"
    awk -v begin="$begin_marker" -v end="$end_marker" '
      $0 == begin { skip = 1; next }
      $0 == end { skip = 0; next }
      skip != 1 { print }
    ' "$rc_file" > "$tmp_file"

    existing_browser_export="$(awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*(export[[:space:]]+)?BROWSER[[:space:]]*=/ { found = 1; exit }
      END { if (found == 1) print "1" }
    ' "$tmp_file")"
    if [ "$existing_browser_export" != "1" ]; then
      {
        printf '%s\\n' "$begin_marker"
        printf 'export BROWSER="$HOME/.ssh-back/browser"\\n'
        printf '%s\\n' "$end_marker"
      } >> "$tmp_file"
    fi
    cat "$tmp_file" > "$rc_file"
    rm -f "$tmp_file"

    printf 'SSH_BACK_BROWSER_PATH=~/.ssh-back/browser\\n'
    printf 'SSH_BACK_ENV_SHELL=%s\\n' "$shell_name"
    printf 'SSH_BACK_ENV_RC=%s\\n' "$rc_display"
    """
  }
}
