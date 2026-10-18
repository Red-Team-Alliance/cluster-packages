#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
source_dir="$root/.cache/himmelblau-build"
source_config="$root/${HIMMELBLAU_SOURCE:-packages/himmelblau/source.json}"
artifacts="$root/.cache/himmelblau-packages"
commit=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$source_config")
test "$(uname -m)" = aarch64
mkdir -p "$root/.cache"
if [[ ! -d "$source_dir/.git" ]]; then
  git init "$source_dir"
  git -C "$source_dir" remote add origin https://github.com/himmelblau-idm/himmelblau.git
fi
git -C "$source_dir" fetch --depth=1 origin "$commit"
git -C "$source_dir" checkout --detach "$commit"
test "$(git -C "$source_dir" rev-parse HEAD)" = "$commit"
python3 "$root/packages/himmelblau/prepare-source.py" "$source_dir" "$source_config" "$artifacts"
revision=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$source_config")
# All Docker runs receive a bounded Rust job count. The native ARM runner does not need an interactive terminal.
cat > "$root/.cache/docker-himmelblau" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == run ]]; then
  shift
  args=()
  for arg in "$@"; do
    if [[ "$arg" != -it ]]; then args+=("$arg"); fi
  done
  exec docker run --env CARGO_BUILD_JOBS=2 "${args[@]}"
fi
exec docker "$@"
WRAPPER
chmod 700 "$root/.cache/docker-himmelblau"
make -C "$source_dir" ubuntu26.04 DOCKER="$root/.cache/docker-himmelblau" DEB_REVISION_APPEND="$revision"
mkdir -p "$root/.cache/himmelblau-packages"
for package in himmelblau pam-himmelblau nss-himmelblau himmelblau-sshd-config himmelblau-apparmor; do
  cp "$source_dir"/packaging/"$package"_*_arm64.deb "$root/.cache/himmelblau-packages/"
done
python3 "$root/packages/himmelblau/verify-packages.py" "$root/.cache/himmelblau-packages"
# Use the same native build image and compiled dependencies for regression tests.
docker run --rm --env CARGO_BUILD_JOBS=2 \
  -v "$source_dir:/himmelblau" -v "$source_dir/target/ubuntu26.04:/himmelblau/target" \
  -v "$artifacts:/core-artifacts" -v "$root/packages/himmelblau:/core-build:ro" -w /himmelblau himmelblau-ubuntu26.04-build \
  bash -euo pipefail -c '
    if test -d src/overrides/libhimmelblau; then python3 /core-build/test-library.py; fi
    cargo test --release --locked -p himmelblau_unix_common db::tests -- --test-threads=1 2>&1 | tee /core-artifacts/regression-tests.txt
    cargo test --release --locked -p himmelblau_unix_common map_name_to_upn -- --test-threads=1 2>&1 | tee -a /core-artifacts/regression-tests.txt
    cargo test --release --locked -p nss_himmelblau dynamic_ids_return_not_found_without_daemon_access -- --test-threads=1 2>&1 | tee -a /core-artifacts/regression-tests.txt
  '
git -C "$source_dir" diff --exit-code -- Cargo.lock
tar -czf "$artifacts/core-build-inputs.tar.gz" -C "$root" \
  packages/himmelblau/build.sh packages/himmelblau/prepare-source.py \
  packages/himmelblau/verify-packages.py packages/himmelblau/test-library.py \
  "${source_config#"$root/"}" packages/himmelblau/patches
cp "$root/packages/himmelblau/build.sh" "$root/.cache/himmelblau-packages/core-build.sh"
cp "$source_dir/LICENSE" "$root/.cache/himmelblau-packages/LICENSE" 
