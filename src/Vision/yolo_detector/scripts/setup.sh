#!/usr/bin/env bash
# setup.sh -- one-shot setup for the yolo_detector package.
#
#   1. Sources <workspace>/scripts/venv_build.sh (provides create_venv)
#   2. Creates <workspace>/src/Vision/yolo_detector/venv with create_venv
#   3. Activates it and installs requirements.txt
#   4. Downloads yolo11n.pt into <package>/model/
#   5. Deactivates the venv
#
# Usage (run it, don't source it):
#   bash setup.sh              # create the venv if missing, reuse it otherwise
#   bash setup.sh --recreate   # delete the package venv first, then rebuild it
#
# The script can live anywhere inside the workspace: it walks up from its own
# folder until it finds scripts/venv_build.sh. Override with WS_ROOT=/path/to/Barquito.

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    echo "ERROR: run this script with 'bash setup.sh'; do not source it." >&2
    return 1
fi

PKG_REL="src/Vision/yolo_detector"
MODEL_NAME="yolo11n.pt"

fail() {
    echo "" >&2
    echo "ERROR: $*" >&2
    if declare -F deactivate >/dev/null 2>&1; then
        deactivate
    fi
    exit 1
}

# ---------------------------------------------------------------------------
# Locate the workspace root (the folder that contains scripts/venv_build.sh)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${WS_ROOT:-}" ]; then
    search_dir="${SCRIPT_DIR}"
    while [ "${search_dir}" != "/" ]; do
        if [ -f "${search_dir}/scripts/venv_build.sh" ]; then
            WS_ROOT="${search_dir}"
            break
        fi
        search_dir="$(dirname "${search_dir}")"
    done
fi

if [ -z "${WS_ROOT:-}" ] || [ ! -f "${WS_ROOT}/scripts/venv_build.sh" ]; then
    fail "could not find scripts/venv_build.sh above ${SCRIPT_DIR}. Set WS_ROOT=/path/to/Barquito and retry."
fi

PKG_DIR="${WS_ROOT}/${PKG_REL}"
VENV_DIR="${PKG_DIR}/venv"
REQ_FILE="${PKG_DIR}/requirements.txt"
MODEL_DIR="${PKG_DIR}/model"

[ -d "${PKG_DIR}" ]  || fail "package folder not found: ${PKG_DIR}"
[ -f "${REQ_FILE}" ] || fail "requirements file not found: ${REQ_FILE}"

echo "=================================================="
echo " Workspace : ${WS_ROOT}"
echo " Package   : ${PKG_DIR}"
echo "=================================================="

# ---------------------------------------------------------------------------
# ROS must be sourced so the venv (created with --system-site-packages) sees rclpy
# ---------------------------------------------------------------------------
if [ -z "${ROS_DISTRO:-}" ]; then
    if [ -f /opt/ros/jazzy/setup.bash ]; then
        echo "ROS_DISTRO not set; sourcing /opt/ros/jazzy/setup.bash"
        # shellcheck disable=SC1091
        source /opt/ros/jazzy/setup.bash
    else
        echo "WARNING: ROS 2 is not sourced and /opt/ros/jazzy was not found." >&2
        echo "         rclpy will not be visible inside the venv." >&2
    fi
fi

# ---------------------------------------------------------------------------
# Step 1: load create_venv
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
source "${WS_ROOT}/scripts/venv_build.sh" || fail "failed to source scripts/venv_build.sh"
declare -F create_venv >/dev/null 2>&1 || fail "create_venv is not defined by scripts/venv_build.sh"

# ---------------------------------------------------------------------------
# Step 2: create the venv (or reuse it)
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--recreate" ] && [ -d "${VENV_DIR}" ]; then
    echo "--recreate: removing ${VENV_DIR}"
    rm -rf "${VENV_DIR}"
fi

if [ -e "${VENV_DIR}" ]; then
    echo "venv already exists at ${VENV_DIR}; reusing it (use --recreate to rebuild)."
else
    create_venv "${PKG_DIR}" || fail "create_venv failed."
fi

# ---------------------------------------------------------------------------
# Step 3: activate and install requirements
# ---------------------------------------------------------------------------
echo ""
echo "--- Activating venv and installing ${REQ_FILE} ---"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate" || fail "could not activate ${VENV_DIR}"

active_python="$(command -v python3)"
if [[ "${active_python}" != "${VENV_DIR}/bin/python3" ]]; then
    fail "python3 resolves to '${active_python}', expected '${VENV_DIR}/bin/python3'. The venv may have been moved or copied from another machine; rerun with --recreate."
fi

python3 -m pip install --ignore-installed -r "${REQ_FILE}" || fail "pip install -r requirements.txt failed."

# cv_bridge (ROS 2 Jazzy) is built against NumPy 1.x
np_ver="$(python3 -c 'import numpy; print(numpy.__version__)' 2>/dev/null)"
if [[ "${np_ver}" != 1.* ]]; then
    fail "NumPy is '${np_ver:-missing}' inside the venv; cv_bridge needs 1.x. Check requirements.txt pins and rerun with --recreate."
fi
echo "  OK: numpy ${np_ver}"

# ---------------------------------------------------------------------------
# Step 4: download the model into <package>/model/
# ---------------------------------------------------------------------------
echo ""
echo "--- Downloading ${MODEL_NAME} into ${MODEL_DIR} ---"
mkdir -p "${MODEL_DIR}" || fail "could not create ${MODEL_DIR}"

if [ -f "${MODEL_DIR}/${MODEL_NAME}" ]; then
    echo "  ${MODEL_NAME} already present; skipping download."
else
    # Ultralytics downloads missing weights; run from model/ so they land there.
    (cd "${MODEL_DIR}" && python3 -c "from ultralytics import YOLO; YOLO('${MODEL_NAME}')") \
        || fail "model download failed (is there internet access?)."

    if [ ! -f "${MODEL_DIR}/${MODEL_NAME}" ]; then
        # Some Ultralytics versions save into their own weights folder instead.
        weights_dir="$(python3 -c "from ultralytics.utils import SETTINGS; print(SETTINGS['weights_dir'])" 2>/dev/null)"
        if [ -n "${weights_dir}" ] && [ -f "${weights_dir}/${MODEL_NAME}" ]; then
            cp "${weights_dir}/${MODEL_NAME}" "${MODEL_DIR}/${MODEL_NAME}" \
                || fail "could not copy ${MODEL_NAME} from ${weights_dir}"
        else
            fail "download finished but ${MODEL_DIR}/${MODEL_NAME} was not found."
        fi
    fi
fi
echo "  OK: ${MODEL_DIR}/${MODEL_NAME}"

# Informational only
python3 -c "import torch; print('  torch', torch.__version__, '| CUDA available:', torch.cuda.is_available())" 2>/dev/null \
    || echo "  (could not import torch for the CUDA check)"

# ---------------------------------------------------------------------------
# Step 5: deactivate
# ---------------------------------------------------------------------------
deactivate

echo ""
echo "=================================================="
echo " Setup complete."
echo "   venv  : ${VENV_DIR}"
echo "   model : ${MODEL_DIR}/${MODEL_NAME}"
echo " Next: run 'build' from ${WS_ROOT}."
echo "=================================================="