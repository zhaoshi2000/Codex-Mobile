exe=$1; container=$2; target=$3; shift 3
if [ -n "$container" ]; then
  NO_COLOR=1 docker exec "$container" "$exe" "$@"
  exit $?
fi
find_cli() {
  for p in "$1/.local/openclaw/bin/openclaw" "$1/.local/bin/openclaw" "$1/.npm-global/bin/openclaw" "$1"/.local/node-*/bin/openclaw "$1"/.nvm/versions/node/*/bin/openclaw; do
    if [ -x "$p" ]; then printf '%s\n' "$p"; return; fi
  done
}
if [ -z "$target" ] && [ "$exe" = openclaw ] && ! command -v openclaw >/dev/null 2>&1; then
  found=$(find_cli "$HOME")
  if [ -n "$found" ]; then exe=$found
  elif [ "$(id -u)" = 0 ]; then
    count=0
    for home in /home/*; do
      if [ -d "$home/.openclaw" ] && [ -n "$(find_cli "$home")" ]; then
        candidate=$(stat -c %U "$home" 2>/dev/null)
        if [ -n "$candidate" ]; then target=$candidate; count=$((count+1)); fi
      fi
    done
    if [ "$count" -gt 1 ]; then echo '发现多个 OpenClaw 安装用户，请在编辑服务中指定运行用户。' >&2; exit 2; fi
  fi
fi
invoke='export PATH="$HOME/.local/openclaw/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
for d in "$HOME"/.local/node-*/bin "$HOME"/.nvm/versions/node/*/bin; do [ ! -d "$d" ] || PATH="$d:$PATH"; done
export PATH NO_COLOR=1
cd "$HOME" || exit 1
if ! command -v "$1" >/dev/null 2>&1; then echo "找不到 OpenClaw 命令，请检查运行用户、命令路径或容器名称。" >&2; exit 127; fi
exec "$@"'
if [ -n "$target" ] && [ "$target" != "$(id -un)" ]; then
  home=$(getent passwd "$target" | cut -d: -f6)
  if [ -z "$home" ]; then echo 'OpenClaw 运行用户不存在。' >&2; exit 2; fi
  if [ "$(id -u)" = 0 ]; then
    exec runuser -u "$target" -- env HOME="$home" sh -c "$invoke" sh "$exe" "$@"
  else
    exec sudo -n -u "$target" -H sh -c "$invoke" sh "$exe" "$@"
  fi
fi
exec sh -c "$invoke" sh "$exe" "$@"
