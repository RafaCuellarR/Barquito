#!/bin/bash
# justina_build.sh
#
# Defines a `build` function that:
#   1. Finds every package under src/ that has its own `venv` directory.
#   2. For each one: activates its venv, verifies the venv's python3 is
#      actually on PATH, builds ONLY that package with colcon, deactivates.
#   3. Once all venv-packages are built, runs a single `colcon build` for
#      every remaining package (ament_cmake, or ament_python without a venv).
#
# Usage:
#   source justina_build.sh
#   build                # from your ROS 2 workspace root (where src/ lives)
#
# Assumes:
#   - Run from the workspace root (the directory that contains src/, build/, install/).
#   - Each package's venv lives directly inside that package's folder, e.g.
#       src/pkg_a/venv
#       src/listener/listener_venv   <- also detected, see VENV_DIRNAME_PATTERN below
#   - colcon is installed inside each venv (pip install colcon-common-extensions
#     colcon-ros --ignore-installed), so builds triggered from inside that venv
#     produce executables with the correct shebang.
#   - ROS 2 is already sourced (source /opt/ros/<distro>/setup.bash) before
#     calling `build`.

build() {
    local WS_ROOT
    WS_ROOT="$(pwd)"

    if [ ! -d "${WS_ROOT}/src" ]; then
        echo "ERROR: no 'src' directory found in $(pwd). Run this from your workspace root." >&2
        return 1
    fi

    # Pattern for matching venv directories inside a package folder.
    # Matches a directory literally named "venv", OR one ending in "_venv"
    # (e.g. "listener_venv"). Adjust if your naming convention differs.
    local VENV_DIRNAME_PATTERN='(venv|.*_venv)$'

    echo "=================================================="
    echo " Step 1: Building packages with their own venv"
    echo "=================================================="

    local venv_packages=()
    local pkg_dir pkg_name venv_dir

    # Find candidate venv dirs one level inside each package folder in src/
    while IFS= read -r -d '' venv_dir; do
        pkg_dir="$(dirname "${venv_dir}")"
        pkg_name="$(basename "${pkg_dir}")"

        # Sanity check: does this directory actually look like a ROS package?
        if [ ! -f "${pkg_dir}/package.xml" ]; then
            echo "  Skipping '${pkg_name}': has a venv-like dir but no package.xml, not a ROS package."
            continue
        fi

        venv_packages+=("${pkg_name}")

        echo ""
        echo "--- Building '${pkg_name}' (venv: ${venv_dir}) ---"

        # Activate in a subshell so PATH/VIRTUAL_ENV changes never leak
        # between package builds or into the caller's shell.
        (
            # shellcheck disable=SC1090
            source "${venv_dir}/bin/activate"

            local active_python
            active_python="$(command -v python3)"
            if [[ "${active_python}" != "${venv_dir}"/bin/python3 ]]; then
                echo "  ERROR: venv activation failed for '${pkg_name}'." >&2
                echo "         Expected python3 at ${venv_dir}/bin/python3, got: ${active_python}" >&2
                exit 1
            fi

            local active_colcon
            active_colcon="$(command -v colcon)"
            if [[ "${active_colcon}" != "${venv_dir}"/bin/colcon ]]; then
                echo "  WARNING: colcon is not installed inside this venv (found: ${active_colcon})." >&2
                echo "           Executables built now may get the wrong shebang." >&2
                echo "           Fix with: pip install --ignore-installed colcon-common-extensions colcon-ros" >&2
            fi

            cd "${WS_ROOT}" || exit 1
            colcon build --symlink-install --base-paths src --packages-select "${pkg_name}"
        )

        local build_status=$?
        if [ ${build_status} -ne 0 ]; then
            echo "  ERROR: build failed for '${pkg_name}' (exit ${build_status})." >&2
            return ${build_status}
        fi

        # Verify the resulting executable's shebang, if we can find one,
        # as a sanity check that the correct interpreter got baked in.
        local exe_dir="${WS_ROOT}/install/${pkg_name}/lib/${pkg_name}"
        if [ -d "${exe_dir}" ]; then
            local exe
            for exe in "${exe_dir}"/*; do
                [ -f "${exe}" ] || continue
                local shebang
                shebang="$(head -1 "${exe}" 2>/dev/null)"
                if [[ "${shebang}" == "#!"* ]] && [[ "${shebang}" != *"${venv_dir}"* ]]; then
                    echo "  WARNING: '${exe}' shebang is '${shebang}', not pointing into ${venv_dir}." >&2
                fi
            done
        fi
    done < <(find "${WS_ROOT}/src" -mindepth 2 -maxdepth 3 -type d -regextype posix-extended -iregex ".*/${VENV_DIRNAME_PATTERN}" -print0)

    echo ""
    echo "Packages built with their own venv: ${venv_packages[*]:-(none found)}"

    echo ""
    echo "=================================================="
    echo " Step 2: Building remaining packages (ament_cmake"
    echo " and any ament_python packages without a venv)"
    echo "=================================================="

    if [ ${#venv_packages[@]} -eq 0 ]; then
        colcon build --symlink-install --base-paths src
    else
        colcon build --symlink-install --base-paths src --packages-skip "${venv_packages[@]}"
    fi

    local final_status=$?
    if [ ${final_status} -ne 0 ]; then
        echo "ERROR: colcon build for remaining packages failed (exit ${final_status})." >&2
        return ${final_status}
    fi

    echo ""
    echo "Build complete."
}

# create_venv <package_path>
#
# Sets up a brand-new venv named "venv" INSIDE <package_path>, fully
# configured to work with the `build` function above:
#   1. Creates <package_path>/venv with --system-site-packages (so it can
#      see rclpy and other ROS Python packages).
#   2. Activates it and verifies python3 actually resolves inside the venv.
#   3. Drops a COLCON_IGNORE file inside it so colcon never scans into it.
#   4. Installs colcon fresh INSIDE the venv (--ignore-installed, since
#      --system-site-packages would otherwise report the system colcon as
#      "already satisfied" and skip it) -- this is what makes executables
#      built from this venv get the correct #! shebang.
#   5. Verifies colcon itself resolves inside the venv.
#   6. Deactivates, leaving the venv ready to use.
#
# Usage:
#   source justina_build.sh
#   create src/vision          # creates src/vision/venv
#   create src/listener        # creates src/listener/venv
create_venv() {
    local pkg_dir="$1"
 
    if [ -z "${pkg_dir}" ]; then
        echo "Usage: create <path-to-package>" >&2
        echo "Example: create src/vision   (creates src/vision/venv)" >&2
        return 1
    fi
 
    # Strip a trailing slash, if any, so path joining below is clean.
    pkg_dir="${pkg_dir%/}"
 
    local venv_path="${pkg_dir}/venv"
 
    if [ -e "${venv_path}" ]; then
        echo "ERROR: '${venv_path}' already exists. Refusing to overwrite." >&2
        echo "       Remove it first if you really want to recreate it: rm -rf '${venv_path}'" >&2
        return 1
    fi
 
    if [ ! -d "${pkg_dir}" ]; then
        echo "ERROR: '${pkg_dir}' does not exist." >&2
        return 1
    fi
 
    if [ ! -f "${pkg_dir}/package.xml" ]; then
        echo "WARNING: no package.xml found in '${pkg_dir}'." >&2
        echo "         This venv won't be auto-detected by 'build' unless it sits" >&2
        echo "         directly inside a real ROS package folder." >&2
    fi
 
    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: python3 not found on PATH." >&2
        return 1
    fi
 
    if [ -z "${ROS_DISTRO}" ]; then
        echo "WARNING: \$ROS_DISTRO is not set -- did you source /opt/ros/<distro>/setup.bash?" >&2
        echo "         Continuing anyway, but rclpy may not be visible with --system-site-packages." >&2
    fi
 
    echo "=================================================="
    echo " Creating venv at: ${venv_path}"
    echo "=================================================="
 
    echo ""
    echo "--- Step 1: python3 -m venv --system-site-packages ---"
    python3 -m venv "${venv_path}" --system-site-packages
    if [ $? -ne 0 ]; then
        echo "ERROR: venv creation failed." >&2
        return 1
    fi
 
    # Resolve to an absolute path now, since the activate script hardcodes
    # whatever path we pass -- relative paths work fine as long as you
    # never move the venv afterward, but absolute is safer/clearer.
    local abs_venv_path
    abs_venv_path="$(cd "${venv_path}" && pwd)"
 
    local create_status=0
 
    (
        echo ""
        echo "--- Step 2: activating and verifying interpreter ---"
        # shellcheck disable=SC1090
        source "${abs_venv_path}/bin/activate"
 
        local active_python
        active_python="$(command -v python3)"
        if [[ "${active_python}" != "${abs_venv_path}"/bin/python3 ]]; then
            echo "ERROR: activation failed -- python3 resolves to '${active_python}'," >&2
            echo "       expected '${abs_venv_path}/bin/python3'." >&2
            exit 1
        fi
        echo "  OK: python3 -> ${active_python}"
 
        if ! python3 -c "import rclpy" 2>/dev/null; then
            echo "WARNING: 'import rclpy' failed inside the new venv." >&2
            echo "         Make sure ROS 2 was sourced before running 'create'." >&2
        else
            echo "  OK: rclpy importable"
        fi
 
        echo ""
        echo "--- Step 3: COLCON_IGNORE ---"
        touch "${abs_venv_path}/COLCON_IGNORE"
        echo "  OK: ${abs_venv_path}/COLCON_IGNORE created"
 
        echo ""
        echo "--- Step 4: installing colcon inside the venv ---"
        pip install --ignore-installed colcon-common-extensions colcon-ros
        if [ $? -ne 0 ]; then
            echo "ERROR: failed to install colcon inside the venv." >&2
            exit 1
        fi
 
        echo ""
        echo "--- Step 5: verifying colcon resolves inside the venv ---"
        local active_colcon
        active_colcon="$(command -v colcon)"
        if [[ "${active_colcon}" != "${abs_venv_path}"/bin/colcon ]]; then
            echo "ERROR: colcon resolves to '${active_colcon}', expected" >&2
            echo "       '${abs_venv_path}/bin/colcon'. Builds from this venv" >&2
            echo "       will get the wrong shebang." >&2
            exit 1
        fi
        echo "  OK: colcon -> ${active_colcon}"
        local colcon_shebang
        colcon_shebang="$(head -1 "${active_colcon}")"
        echo "  OK: colcon shebang -> ${colcon_shebang}"
    )
    create_status=$?
 
    if [ ${create_status} -ne 0 ]; then
        echo "" 
        echo "FAILED to fully set up venv at '${venv_path}'. See errors above." >&2
        return ${create_status}
    fi
 
    echo ""
    echo "=================================================="
    echo " Venv ready: ${abs_venv_path}"
    echo "=================================================="
    echo "Next steps:"
    echo "  1. (optional) install package-specific deps, e.g.:"
    echo "       source '${abs_venv_path}/bin/activate'"
    echo "       pip install --ignore-installed <your-package>==<version>"
    echo "       deactivate"
    echo "  2. Run 'build' from the workspace root to build everything,"
    echo "     including this new venv-backed package."
}