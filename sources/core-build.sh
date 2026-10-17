#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
source_dir="$root/.cache/himmelblau-build"
commit=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$root/packages/himmelblau/source.json")
mkdir -p "$root/.cache"
if [[ ! -d "$source_dir/.git" ]]; then
  git init "$source_dir"
  git -C "$source_dir" remote add origin https://github.com/himmelblau-idm/himmelblau.git
fi
git -C "$source_dir" fetch --depth=1 origin "$commit"
git -C "$source_dir" checkout --detach "$commit"
test "$(git -C "$source_dir" rev-parse HEAD)" = "$commit"
# All Docker runs receive a bounded Rust job count. The upstream ARM target is noninteractive.
cat > "$root/.cache/docker-himmelblau" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == run ]]; then
  shift
  exec docker run --env CARGO_BUILD_JOBS=2 "$@"
fi
exec docker "$@"
WRAPPER
chmod 700 "$root/.cache/docker-himmelblau"
make -C "$source_dir" arm64-ubuntu26.04 DOCKER="$root/.cache/docker-himmelblau" DEB_REVISION_APPEND=+core1
mkdir -p "$root/.cache/himmelblau-packages"
for package in himmelblau pam-himmelblau nss-himmelblau himmelblau-sshd-config himmelblau-apparmor; do
  cp "$source_dir"/packaging/"$package"_*_arm64.deb "$root/.cache/himmelblau-packages/"
done
python3 "$root/packages/himmelblau/verify-packages.py" "$root/.cache/himmelblau-packages"
git -C "$source_dir" archive --format=tar.gz --prefix=himmelblau-4.0.6/ HEAD > "$root/.cache/himmelblau-packages/himmelblau-4.0.6-source.tar.gz"
cp "$root/packages/himmelblau/build.sh" "$root/.cache/himmelblau-packages/core-build.sh"
cp "$source_dir/LICENSE" "$root/.cache/himmelblau-packages/LICENSE" 
